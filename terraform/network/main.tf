# Multicloud VPN mesh — AWS <-> Azure <-> GCP, full mesh, BGP everywhere.
# One hub network per cloud, one CIDR per cloud (no overlap, ever):
#   AWS   10.10.0.0/16
#   Azure 10.20.0.0/16
#   GCP   10.30.0.0/16
# Shared secrets come in as variables — inject from your vault/CI, never commit.

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
    google = { source = "hashicorp/google", version = "~> 6.0" }
  }
}

variable "aws_region" { default = "us-east-1" }
variable "azure_location" { default = "eastus" }
variable "gcp_region" { default = "us-central1" }
variable "gcp_project" { type = string }

variable "aws_azure_psk" { type = string, sensitive = true }
variable "aws_gcp_psk" { type = string, sensitive = true }
variable "azure_gcp_psk" { type = string, sensitive = true }

provider "aws" { region = var.aws_region }
provider "azurerm" { features {} }
provider "google" { project = var.gcp_project, region = var.gcp_region }

# ---------- AWS hub ----------
resource "aws_vpc" "hub" {
  cidr_block = "10.10.0.0/16"
  tags = { Name = "hub-aws" }
}

resource "aws_subnet" "hub_workload" {
  vpc_id = aws_vpc.hub.id
  cidr_block = "10.10.1.0/24"
  availability_zone = "${var.aws_region}a"
}

resource "aws_vpn_gateway" "hub" {
  vpc_id = aws_vpc.hub.id
  amazon_side_asn = 64512
  tags = { Name = "hub-aws-vgw" }
}

resource "aws_vpn_gateway_route_propagation" "hub" {
  vpn_gateway_id = aws_vpn_gateway.hub.id
  route_table_id = aws_vpc.hub.main_route_table_id
}

# ---------- Azure hub ----------
resource "azurerm_resource_group" "hub" {
  name = "rg-hub-network"
  location = var.azure_location
}

resource "azurerm_virtual_network" "hub" {
  name = "vnet-hub"
  resource_group_name = azurerm_resource_group.hub.name
  location = var.azure_location
  address_space = ["10.20.0.0/16"]
}

resource "azurerm_subnet" "gateway" {
  name = "GatewaySubnet"
  resource_group_name = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes = ["10.20.255.0/27"]
}

resource "azurerm_subnet" "workload" {
  name = "snet-workload"
  resource_group_name = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes = ["10.20.1.0/24"]
}

resource "azurerm_public_ip" "vpn" {
  name = "pip-vpn-gw"
  resource_group_name = azurerm_resource_group.hub.name
  location = var.azure_location
  allocation_method = "Static"
  sku = "Standard"
}

resource "azurerm_virtual_network_gateway" "hub" {
  name = "vng-hub"
  resource_group_name = azurerm_resource_group.hub.name
  location = var.azure_location
  type = "Vpn"
  vpn_type = "RouteBased"
  sku = "VpnGw2AZ"
  active_active = false
  enable_bgp = true

  bgp_settings { asn = 65515 }

  ip_configuration {
    name = "vnetGatewayConfig"
    public_ip_address_id = azurerm_public_ip.vpn.id
    private_ip_address_allocation = "Dynamic"
    subnet_id = azurerm_subnet.gateway.id
  }
}

# ---------- GCP hub ----------
resource "google_compute_network" "hub" {
  name = "vpc-hub"
  auto_create_subnetworks = false
  routing_mode = "GLOBAL"
}

resource "google_compute_subnetwork" "workload" {
  name = "subnet-workload"
  network = google_compute_network.hub.id
  ip_cidr_range = "10.30.1.0/24"
  region = var.gcp_region
}

resource "google_compute_router" "hub" {
  name = "cr-hub"
  network = google_compute_network.hub.id
  region = var.gcp_region
  bgp { asn = 64514 }
}

resource "google_compute_ha_vpn_gateway" "hub" {
  name = "havpn-hub"
  network = google_compute_network.hub.id
  region = var.gcp_region
}

# ---------- Leg 1: AWS <-> Azure ----------
resource "aws_customer_gateway" "azure" {
  bgp_asn = 65515
  ip_address = azurerm_public_ip.vpn.ip_address
  type = "ipsec.1"
  tags = { Name = "cgw-azure" }
}

resource "aws_vpn_connection" "aws_azure" {
  vpn_gateway_id = aws_vpn_gateway.hub.id
  customer_gateway_id = aws_customer_gateway.azure.id
  type = "ipsec.1"
  tunnel1_preshared_key = var.aws_azure_psk
  tunnel2_preshared_key = var.aws_azure_psk
}

resource "azurerm_local_network_gateway" "aws" {
  name = "lng-aws"
  resource_group_name = azurerm_resource_group.hub.name
  location = var.azure_location
  gateway_address = aws_vpn_connection.aws_azure.tunnel1_address
  address_space = ["10.10.0.0/16"]
  bgp_settings {
    asn = 64512
    bgp_peering_address = aws_vpn_connection.aws_azure.tunnel1_bgp_peering_address
  }
}

resource "azurerm_virtual_network_gateway_connection" "aws" {
  name = "conn-aws"
  resource_group_name = azurerm_resource_group.hub.name
  location = var.azure_location
  type = "IPsec"
  virtual_network_gateway_id = azurerm_virtual_network_gateway.hub.id
  local_network_gateway_id = azurerm_local_network_gateway.aws.id
  shared_key = var.aws_azure_psk
  enable_bgp = true
}

# ---------- Leg 2: AWS <-> GCP ----------
resource "google_compute_external_vpn_gateway" "aws" {
  name = "extgw-aws"
  redundancy_type = "TWO_IPS_REDUNDANCY"
  interface { id = 0, ip_address = aws_vpn_connection.aws_gcp.tunnel1_address }
  interface { id = 1, ip_address = aws_vpn_connection.aws_gcp.tunnel2_address }
}

resource "aws_customer_gateway" "gcp" {
  bgp_asn = 64514
  ip_address = google_compute_ha_vpn_gateway.hub.vpn_interfaces[0].ip_address
  type = "ipsec.1"
  tags = { Name = "cgw-gcp" }
}

resource "aws_vpn_connection" "aws_gcp" {
  vpn_gateway_id = aws_vpn_gateway.hub.id
  customer_gateway_id = aws_customer_gateway.gcp.id
  type = "ipsec.1"
  tunnel1_preshared_key = var.aws_gcp_psk
  tunnel2_preshared_key = var.aws_gcp_psk
}

resource "google_compute_vpn_tunnel" "aws_t1" {
  name = "tunnel-aws-1"
  region = var.gcp_region
  vpn_gateway = google_compute_ha_vpn_gateway.hub.id
  peer_external_gateway = google_compute_external_vpn_gateway.aws.id
  peer_external_gateway_interface = 0
  shared_secret = var.aws_gcp_psk
  router = google_compute_router.hub.id
  vpn_gateway_interface = 0
}

resource "google_compute_router_interface" "aws_t1" {
  name = "if-aws-1"
  router = google_compute_router.hub.name
  region = var.gcp_region
  vpn_tunnel = google_compute_vpn_tunnel.aws_t1.name
  ip_range = "${aws_vpn_connection.aws_gcp.tunnel1_cgw_inside_address}/30"
}

resource "google_compute_router_peer" "aws_t1" {
  name = "bgp-aws-1"
  router = google_compute_router.hub.name
  region = var.gcp_region
  interface = google_compute_router_interface.aws_t1.name
  peer_ip_address = aws_vpn_connection.aws_gcp.tunnel1_vgw_inside_address
  peer_asn = 64512
}

# ---------- Leg 3: Azure <-> GCP ----------
resource "google_compute_external_vpn_gateway" "azure" {
  name = "extgw-azure"
  redundancy_type = "SINGLE_IP_INTERNALLY_REDUNDANT"
  interface { id = 0, ip_address = azurerm_public_ip.vpn.ip_address }
}

resource "google_compute_vpn_tunnel" "azure_t1" {
  name = "tunnel-azure-1"
  region = var.gcp_region
  vpn_gateway = google_compute_ha_vpn_gateway.hub.id
  peer_external_gateway = google_compute_external_vpn_gateway.azure.id
  peer_external_gateway_interface = 0
  shared_secret = var.azure_gcp_psk
  router = google_compute_router.hub.id
  vpn_gateway_interface = 1
}

resource "azurerm_local_network_gateway" "gcp" {
  name = "lng-gcp"
  resource_group_name = azurerm_resource_group.hub.name
  location = var.azure_location
  gateway_address = google_compute_ha_vpn_gateway.hub.vpn_interfaces[1].ip_address
  address_space = ["10.30.0.0/16"]
  bgp_settings {
    asn = 64514
    bgp_peering_address = "169.254.22.1" # must match the GCP router interface below
  }
}

resource "azurerm_virtual_network_gateway_connection" "gcp" {
  name = "conn-gcp"
  resource_group_name = azurerm_resource_group.hub.name
  location = var.azure_location
  type = "IPsec"
  virtual_network_gateway_id = azurerm_virtual_network_gateway.hub.id
  local_network_gateway_id = azurerm_local_network_gateway.gcp.id
  shared_key = var.azure_gcp_psk
  enable_bgp = true
}

resource "google_compute_router_interface" "azure_t1" {
  name = "if-azure-1"
  router = google_compute_router.hub.name
  region = var.gcp_region
  vpn_tunnel = google_compute_vpn_tunnel.azure_t1.name
  ip_range = "169.254.22.2/30"
}

resource "google_compute_router_peer" "azure_t1" {
  name = "bgp-azure-1"
  router = google_compute_router.hub.name
  region = var.gcp_region
  interface = google_compute_router_interface.azure_t1.name
  peer_ip_address = "169.254.22.1"
  peer_asn = 65515
}

output "mesh_cidrs" {
  value = { aws = "10.10.0.0/16", azure = "10.20.0.0/16", gcp = "10.30.0.0/16" }
}
