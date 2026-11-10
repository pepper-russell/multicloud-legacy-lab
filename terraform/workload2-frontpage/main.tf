# Workload 2 — FrontPage 98 blog resurrection, Azure leg of the mesh (10.20.0.0/16).
#
# Reality, stated once:
# - FrontPage Server Extensions (FPSE) died with IIS 6 / Windows Server 2003-era
#   support and must never be exposed to the modern internet: the authoring
#   protocol is unauthenticated by today's standards. So FP98 never talks to
#   the public site directly.
# - The working pattern: author locally in FrontPage 98 (it still runs on a
#   period VM), publish to a PRIVATE staging VM over the VPN mesh only,
#   and let the Swift FrontPagePublisher sync the rendered HTML out to
#   public static hosting. Readers see a static site; the FP98 machinery
#   stays behind the wall where it belongs.
# - What survives: pages, themes, shared borders, hit counters do NOT
#   (they were server components — the publisher replaces the counter
#   with a static badge or drops it; see the Swift app).

terraform {
  required_providers { azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" } }
}

variable "location" { default = "eastus" }
variable "vnet_id" { type = string }        # from ../network (vnet-hub)
variable "workload_subnet_id" { type = string }

provider "azurerm" { features {} }

resource "azurerm_resource_group" "blog" {
  name = "rg-frontpage98"
  location = var.location
}

# ---------- Public face: static website on Blob Storage + CDN ----------
resource "azurerm_storage_account" "site" {
  name = "stfrontpage98site"
  resource_group_name = azurerm_resource_group.blog.name
  location = var.location
  account_tier = "Standard"
  account_replication_type = "GRS"
  account_kind = "StorageV2"

  static_website {
    index_document = "default.htm"   # FrontPage-era default document, kept
    error_404_document = "404.htm"
  }
}

resource "azurerm_cdn_profile" "site" {
  name = "cdn-frontpage98"
  resource_group_name = azurerm_resource_group.blog.name
  location = "global"
  sku = "Standard_Microsoft"
}

resource "azurerm_cdn_endpoint" "site" {
  name = "frontpage98"
  profile_name = azurerm_cdn_profile.site.name
  resource_group_name = azurerm_resource_group.blog.name
  location = "global"
  origin_host_header = azurerm_storage_account.site.primary_web_host

  origin {
    name = "blob-static"
    host_name = azurerm_storage_account.site.primary_web_host
  }
}

# ---------- Private authoring endpoint: the FP98 staging VM ----------
# A small Windows VM reachable ONLY over the VPN mesh (no public IP).
# FrontPage 98 publishes to it the way it always did; the Swift publisher
# then promotes content to the storage account above.
resource "azurerm_network_interface" "staging" {
  name = "nic-fp98-staging"
  resource_group_name = azurerm_resource_group.blog.name
  location = var.location
  ip_configuration {
    name = "internal"
    subnet_id = var.workload_subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_windows_virtual_machine" "staging" {
  name = "vm-fp98-staging"
  resource_group_name = azurerm_resource_group.blog.name
  location = var.location
  size = "Standard_B2s"
  admin_username = "fpadmin"
  admin_password = var.staging_admin_password
  network_interface_ids = [azurerm_network_interface.staging.id]

  os_disk {
    caching = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }
  # Any supported Windows Server image works here — FP98 is the CLIENT.
  # The server side only needs WebDAV/FTP-over-the-mesh for FP98's publish.
  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer = "WindowsServer"
    sku = "2022-datacenter-azure-edition"
    version = "latest"
  }
}

variable "staging_admin_password" { type = string, sensitive = true }

resource "azurerm_network_security_group" "staging" {
  name = "nsg-fp98-staging"
  resource_group_name = azurerm_resource_group.blog.name
  location = var.location

  security_rule {
    name = "AllowMeshOnly"
    priority = 100
    direction = "Inbound"
    access = "Allow"
    protocol = "*"
    source_port_range = "*"
    destination_port_range = "*"
    source_address_prefixes = ["10.10.0.0/16", "10.20.0.0/16", "10.30.0.0/16"]
    destination_address_prefix = "*"
  }
  security_rule {
    name = "DenyInternetInbound"
    priority = 4096
    direction = "Inbound"
    access = "Deny"
    protocol = "*"
    source_port_range = "*"
    destination_port_range = "*"
    source_address_prefix = "Internet"
    destination_address_prefix = "*"
  }
}

output "site_url" { value = azurerm_storage_account.site.primary_web_endpoint }
output "cdn_url" { value = "https://${azurerm_cdn_endpoint.site.fqdn}" }
output "staging_private_ip" { value = azurerm_network_interface.staging.private_ip_address }
