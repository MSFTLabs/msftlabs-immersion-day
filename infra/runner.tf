// Self-hosted GitHub Actions runner inside the lab VNet. Packer builds run from here and reach Windows build VMs privately over WinRM.

// https://search.opentofu.org/provider/hashicorp/random/latest/docs/resources/password
resource "random_password" "runner" {
  length           = 32
  special          = true
  override_special = "!#%*-_=+"
  min_lower        = 4
  min_upper        = 4
  min_numeric      = 4
  min_special      = 2
}

// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/key_vault_secret
resource "azurerm_key_vault_secret" "runner_admin_password" {
  name         = local.runner_secret_name
  value        = random_password.runner.result
  key_vault_id = azurerm_key_vault.lab_credentials.id
  content_type = "text/plain"
  tags         = local.tags

  depends_on = [azurerm_role_assignment.lab_credentials_writer]
}

// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/network_interface
resource "azurerm_network_interface" "runner" {
  name                = "${local.runner_name}-nic"
  location            = azurerm_resource_group.shared.location
  resource_group_name = azurerm_resource_group.shared.name
  tags                = local.tags

  ip_configuration {
    name                          = local.runner_nic_ip_configuration
    subnet_id                     = azurerm_subnet.lab["image_build"].id
    private_ip_address_allocation = local.runner_private_ip_allocation
  }
}

// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/linux_virtual_machine
resource "azurerm_linux_virtual_machine" "runner" {
  name                            = local.runner_name
  computer_name                   = local.runner_name
  location                        = azurerm_resource_group.shared.location
  resource_group_name             = azurerm_resource_group.shared.name
  size                            = local.runner_size
  network_interface_ids           = [azurerm_network_interface.runner.id]
  admin_username                  = local.runner_admin_username
  admin_password                  = random_password.runner.result
  disable_password_authentication = false
  secure_boot_enabled             = local.runner_secure_boot_enabled
  vtpm_enabled                    = local.runner_vtpm_enabled
  custom_data                     = base64encode(local.runner_cloud_init)
  tags                            = merge(local.tags, { Role = "github-runner" })

  identity {
    type = local.runner_identity_type
  }

  boot_diagnostics {
    storage_account_uri = azurerm_storage_account.boot_diagnostics.primary_blob_endpoint
  }

  os_disk {
    name                 = "${local.runner_name}-osdisk"
    caching              = local.runner_os_disk_caching
    storage_account_type = local.runner_os_disk_type
    disk_size_gb         = local.runner_os_disk_size_gb
  }

  source_image_reference {
    publisher = local.runner_image_publisher
    offer     = local.runner_image_offer
    sku       = local.runner_image_sku
    version   = local.runner_image_version
  }

  depends_on = [
    azurerm_subnet_network_security_group_association.lab,
    azurerm_subnet_nat_gateway_association.lab,
    azurerm_nat_gateway_public_ip_association.lab,
  ]
}

// Packer creates and deletes its temporary resource group, VM and gallery image versions with this identity.
// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/role_assignment
resource "azurerm_role_assignment" "runner_contributor" {
  scope                = "/subscriptions/${var.subscription_id}"
  role_definition_name = local.runner_contributor_role
  principal_id         = azurerm_linux_virtual_machine.runner.identity[0].principal_id
}
