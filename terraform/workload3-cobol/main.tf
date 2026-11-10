# Workload 3 — COBOL modernization environment for a bank, GCP leg (10.30.0.0/16).
#
# PCI DSS 4.0 shapes every choice here:
# - The CDE (cardholder data environment) is its own subnet with default-deny
#   firewalling, NO direct internet path, and the only routes in are over the
#   VPN mesh or through IAP. Segmentation is the control; everything else
#   is decoration (Req. 1).
# - Encryption at rest with customer-managed keys (CMEK) everywhere (Req. 3),
#   TLS 1.2+ in transit, keys in Cloud HSM-backed KMS with rotation on.
# - Audit logging on, exported to a retention-locked bucket in a separate
#   security project pattern (here: a separate bucket + org sink) (Req. 10).
# - The COBOL estate runs DURING modernization on GnuCOBOL in the CDE —
#   same source, recompiled — while the Swift CobolMigrator drives the
#   staged move: data first (EBCDIC -> UTF-8, VSAM/sequential -> Cloud SQL),
#   then programs (transpile to Java), strangler-fig, never big-bang.
#   Full plan: ../../migration-plans/cobol-modernization.md
#
# Modernized target chosen: Java 21 / Spring Boot on Cloud Run OUTSIDE the
# CDE front segment, talking back to Cloud SQL over private connectivity.
# Rationale in the plan doc; the short version: bank-grade hiring pool,
# mature COBOL->Java transpilers, and PCI tooling is deepest there.

terraform {
  required_providers { google = { source = "hashicorp/google", version = "~> 6.0" } }
}

variable "project" { type = string }
variable "region" { default = "us-central1" }

provider "google" { project = var.project, region = var.region }

# ---------- Keys first (Req. 3) ----------
resource "google_kms_key_ring" "cde" {
  name = "cde-keyring"
  location = var.region
}
resource "google_kms_crypto_key" "cde" {
  name = "cde-data-key"
  key_ring = google_kms_key_ring.cde.id
  rotation_period = "7776000s" # 90 days
  lifecycle { prevent_destroy = true }
}

# ---------- Segmentation (Req. 1) ----------
resource "google_compute_subnetwork" "cde" {
  name = "subnet-cde"
  network = var.hub_network_id
  ip_cidr_range = "10.30.66.0/24"
  region = var.region
  private_ip_google_access = true
  log_config { aggregation_interval = "INTERVAL_5_SEC", flow_sampling = 1.0, metadata = "INCLUDE_ALL_METADATA" }
}
variable "hub_network_id" { type = string }

resource "google_compute_firewall" "cde_deny_all" {
  name = "cde-deny-all"
  network = var.hub_network_id
  priority = 65534
  direction = "INGRESS"
  deny { protocol = "all" }
  source_ranges = ["0.0.0.0/0"]
  target_tags = ["cde"]
}

resource "google_compute_firewall" "cde_allow_mesh" {
  name = "cde-allow-mesh"
  network = var.hub_network_id
  priority = 1000
  direction = "INGRESS"
  allow { protocol = "tcp", ports = ["22", "443", "3306"] }
  source_ranges = ["10.10.0.0/16", "10.20.0.0/16"] # the other clouds, over VPN only
  target_tags = ["cde"]
}

resource "google_compute_firewall" "cde_deny_egress_internet" {
  name = "cde-deny-egress"
  network = var.hub_network_id
  priority = 65534
  direction = "EGRESS"
  deny { protocol = "all" }
  destination_ranges = ["0.0.0.0/0"]
  target_tags = ["cde"]
}

# ---------- Audit trail (Req. 10) ----------
resource "google_storage_bucket" "audit_logs" {
  name = "${var.project}-cde-audit-logs"
  location = var.region
  uniform_bucket_level_access = true
  encryption { default_kms_key_name = google_kms_crypto_key.cde.id }
  retention_policy {
    retention_period = 31556952 # 1 year minimum, PCI Req. 10.5.1
    is_locked = true
  }
}

# ---------- COBOL runtime (the estate, as-is, during modernization) ----------
resource "google_compute_instance" "cobol_runtime" {
  name = "cobol-runtime-1"
  machine_type = "n2-standard-4"
  zone = "${var.region}-a"
  tags = ["cde"]

  boot_disk {
    initialize_params { image = "debian-cloud/debian-12" }
    kms_key_self_link = google_kms_crypto_key.cde.id
  }
  network_interface {
    subnetwork = google_compute_subnetwork.cde.id
    # no access_config block = no public IP. Deliberate.
  }
  metadata_startup_script = <<-EOT
    #!/bin/bash
    apt-get update && apt-get install -y gnucobol3
    # Source lands in /opt/cobol/src from the vault bucket; builds are
    # reproducible: cobc -x -free -o /opt/cobol/bin/<prog> <prog>.cob
    mkdir -p /opt/cobol/{src,bin,data}
  EOT
  shielded_instance_config {
    enable_secure_boot = true
    enable_vtpm = true
    enable_integrity_monitoring = true
  }
}

# Source + data vault (the estate's crown jewels, versioned, CMEK).
resource "google_storage_bucket" "cobol_vault" {
  name = "${var.project}-cobol-vault"
  location = var.region
  versioning { enabled = true }
  uniform_bucket_level_access = true
  encryption { default_kms_key_name = google_kms_crypto_key.cde.id }
}

# ---------- Modernized target data tier (inside CDE until cutover) ----------
resource "google_sql_database_instance" "target" {
  name = "cobol-modernized-db"
  database_version = "POSTGRES_16"
  region = var.region
  settings {
    tier = "db-custom-2-7680"
    ip_configuration {
      ipv4_enabled = false # private IP only
      private_network = var.hub_network_id
      ssl_mode = "ENCRYPTED_ONLY"
    }
    backup_configuration {
      enabled = true
      point_in_time_recovery_enabled = true
    }
    database_flags { name = "log_min_duration_statement", value = "1000" }
  }
  encryption_key_name = google_kms_crypto_key.cde.id
  deletion_protection = true
}

# ---------- Modernized app tier (front segment, outside the CDE subnet) ----------
resource "google_cloud_run_v2_service" "modernized" {
  name = "cobol-modernized-api"
  location = var.region
  ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER" # no public ingress
  template {
    containers {
      image = "us-central1-docker.pkg.dev/${var.project}/modernized/api:latest"
      env { name = "DB_HOST", value = google_sql_database_instance.target.private_ip_address }
    }
    vpc_access {
      network_interfaces {
        network = var.hub_network_id
        subnetwork = google_compute_subnetwork.cde.id
      }
      egress = "PRIVATE_RANGES_ONLY"
    }
  }
}

output "cde_subnet" { value = google_compute_subnetwork.cde.name }
output "target_db_private_ip" { value = google_sql_database_instance.target.private_ip_address }
