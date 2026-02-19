terraform {
  required_version = ">= 1.9, < 2.0"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = ">= 3.116, < 5.0" }
    tls     = { source = "hashicorp/tls", version = "~> 4.0" }
    time    = { source = "hashicorp/time", version = "~> 0.9" } # Added for stability
  }
  backend "azurerm" {
    resource_group_name  = "rg-terrraform-state" # Fixed typo
    storage_account_name = "tfstatek85e" 
    container_name       = "tfstate"
    key                  = "terraform.tfstate"
  }
}

provider "azurerm" {
  features {
    resource_group { prevent_deletion_if_contains_resources = false }
  }
}

locals {
  primary_region   = "canadacentral"
  secondary_region = "canadaeast"
  tags = { scenario = "asr-test" }
}

# -------------------------------------------------------
# Resource Groups
# -------------------------------------------------------
resource "azurerm_resource_group" "primary" {
  name = "rg-asr-primary"
  location = local.primary_region
}
resource "azurerm_resource_group" "secondary" {
  name = "rg-asr-secondary"
  location = local.secondary_region
}
resource "azurerm_resource_group" "asr" {
  name = "rg-asr-vault"
  location = local.secondary_region
}

# -------------------------------------------------------
# Networking
# -------------------------------------------------------
resource "azurerm_virtual_network" "primary" {
  name = "vnet-primary"
  location = azurerm_resource_group.primary.location
  resource_group_name = azurerm_resource_group.primary.name
  address_space = ["10.0.0.0/16"]
}
resource "azurerm_subnet" "primary" {
  name = "subnet-primary"
  resource_group_name = azurerm_resource_group.primary.name
  virtual_network_name = azurerm_virtual_network.primary.name
  address_prefixes = ["10.0.1.0/24"]
}
resource "azurerm_virtual_network" "secondary" {
  name = "vnet-secondary"
  location = azurerm_resource_group.secondary.location
  resource_group_name = azurerm_resource_group.secondary.name
  address_space = ["10.1.0.0/16"]
}
resource "azurerm_subnet" "secondary" {
  name = "subnet-secondary"
  resource_group_name = azurerm_resource_group.secondary.name
  virtual_network_name = azurerm_virtual_network.secondary.name
  address_prefixes = ["10.1.1.0/24"]
}

# -------------------------------------------------------
# VM Resources
# -------------------------------------------------------
resource "tls_private_key" "vm" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "azurerm_network_interface" "vm" {
  name = "nic-asr-test-v3"
  location = azurerm_resource_group.primary.location
  resource_group_name = azurerm_resource_group.primary.name
  ip_configuration {
    name = "ipconfig1"
    subnet_id = azurerm_subnet.primary.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "vm" {
  name = "vm-asr-test-v3"
  location = azurerm_resource_group.primary.location
  resource_group_name = azurerm_resource_group.primary.name
  size = "Standard_D2s_v3" # Stable in Canada
  admin_username = "azureuser"
  network_interface_ids = [azurerm_network_interface.vm.id]
  admin_ssh_key {
    username = "azureuser"
    public_key = tls_private_key.vm.public_key_openssh
  }
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }
  source_image_reference {
    publisher = "Canonical"
    offer = "0001-com-ubuntu-server-focal"
    sku = "20_04-lts-gen2"
    version = "latest"
  }
}

resource "azurerm_storage_account" "asr_cache" {
  name = "stasrcache${substr(md5(azurerm_resource_group.primary.id), 0, 10)}v3"
  location = azurerm_resource_group.primary.location
  resource_group_name = azurerm_resource_group.primary.name
  account_tier = "Standard"
  account_replication_type = "LRS"
}

# -------------------------------------------------------
# ASR Logic (The tricky part)
# -------------------------------------------------------
resource "azurerm_recovery_services_vault" "this" {
  name = "rsv-asr-test-v3"
  location = azurerm_resource_group.asr.location
  resource_group_name = azurerm_resource_group.asr.name
  sku = "Standard"
  soft_delete_enabled = false
}

resource "azurerm_site_recovery_fabric" "primary" {
  name = "fabric-primary"
  resource_group_name = azurerm_resource_group.asr.name
  recovery_vault_name = azurerm_recovery_services_vault.this.name
  location = local.primary_region
}

# STABILIZER: Wait 30 seconds for the fabric to exist in Azure's database
resource "time_sleep" "wait_for_fabric" {
  depends_on = [azurerm_site_recovery_fabric.primary]
  create_duration = "30s"
}

resource "azurerm_site_recovery_fabric" "secondary" {
  name = "fabric-secondary"
  resource_group_name = azurerm_resource_group.asr.name
  recovery_vault_name = azurerm_recovery_services_vault.this.name
  location = local.secondary_region
  depends_on = [time_sleep.wait_for_fabric]
}

resource "azurerm_site_recovery_protection_container" "primary" {
  name = "container-primary"
  resource_group_name = azurerm_resource_group.asr.name
  recovery_vault_name = azurerm_recovery_services_vault.this.name
  recovery_fabric_name = azurerm_site_recovery_fabric.primary.name
}

resource "azurerm_site_recovery_protection_container" "secondary" {
  name = "container-secondary"
  resource_group_name = azurerm_resource_group.asr.name
  recovery_vault_name = azurerm_recovery_services_vault.this.name
  recovery_fabric_name = azurerm_site_recovery_fabric.secondary.name
}

resource "azurerm_site_recovery_replication_policy" "this" {
  name = "policy-asr"
  resource_group_name = azurerm_resource_group.asr.name
  recovery_vault_name = azurerm_recovery_services_vault.this.name
  recovery_point_retention_in_minutes = 1440
  application_consistent_snapshot_frequency_in_minutes = 240
}

resource "azurerm_site_recovery_protection_container_mapping" "this" {
  name = "mapping"
  resource_group_name = azurerm_resource_group.asr.name
  recovery_vault_name = azurerm_recovery_services_vault.this.name
  recovery_fabric_name = azurerm_site_recovery_fabric.primary.name
  recovery_source_protection_container_name = azurerm_site_recovery_protection_container.primary.name
  recovery_target_protection_container_id = azurerm_site_recovery_protection_container.secondary.id
  recovery_replication_policy_id = azurerm_site_recovery_replication_policy.this.id
}

resource "azurerm_site_recovery_network_mapping" "this" {
  name = "net-map"
  resource_group_name = azurerm_resource_group.asr.name
  recovery_vault_name = azurerm_recovery_services_vault.this.name
  source_recovery_fabric_name = azurerm_site_recovery_fabric.primary.name
  target_recovery_fabric_name = azurerm_site_recovery_fabric.secondary.name
  source_network_id = azurerm_virtual_network.primary.id
  target_network_id = azurerm_virtual_network.secondary.id
}

resource "azurerm_site_recovery_replicated_vm" "vm" {
  name = "replicated-vm"
  resource_group_name = azurerm_resource_group.asr.name
  recovery_vault_name = azurerm_recovery_services_vault.this.name
  source_recovery_fabric_name = azurerm_site_recovery_fabric.primary.name
  source_vm_id = azurerm_linux_virtual_machine.vm.id
  recovery_replication_policy_id = azurerm_site_recovery_replication_policy.this.id
  source_recovery_protection_container_name = azurerm_site_recovery_protection_container.primary.name
  target_resource_group_id = azurerm_resource_group.secondary.id
  target_recovery_fabric_id = azurerm_site_recovery_fabric.secondary.id
  target_recovery_protection_container_id = azurerm_site_recovery_protection_container.secondary.id

  managed_disk {
    disk_id = azurerm_linux_virtual_machine.vm.os_disk[0].id
    staging_storage_account_id = azurerm_storage_account.asr_cache.id
    target_resource_group_id = azurerm_resource_group.secondary.id
    target_disk_type = "Standard_LRS"
    target_replica_disk_type = "Standard_LRS"
  }

  network_interface {
    source_network_interface_id = azurerm_network_interface.vm.id
    target_subnet_name = azurerm_subnet.secondary.name
  }

  depends_on = [
    azurerm_site_recovery_protection_container_mapping.this,
    azurerm_site_recovery_network_mapping.this
  ]
}
