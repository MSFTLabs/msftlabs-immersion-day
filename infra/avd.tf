
// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/virtual_desktop_host_pool
resource "azurerm_virtual_desktop_host_pool" "lab" {
  name                     = var.avd_config.host_pool_name
  location                 = azurerm_resource_group.shared.location
  resource_group_name      = azurerm_resource_group.shared.name
  friendly_name            = var.avd_config.desktop_display_name
  type                     = local.avd_host_pool_type
  load_balancer_type       = var.avd_config.load_balancer_type
  maximum_sessions_allowed = var.avd_config.maximum_sessions_per_host
  preferred_app_group_type = local.avd_preferred_app_group
  custom_rdp_properties    = local.avd_custom_rdp_properties
  start_vm_on_connect      = local.avd_start_vm_on_connect
  validate_environment     = local.avd_validate_environment
  tags                     = local.tags
}

// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/virtual_desktop_application_group
resource "azurerm_virtual_desktop_application_group" "desktop" {
  name                         = var.avd_config.application_group_name
  location                     = azurerm_resource_group.shared.location
  resource_group_name          = azurerm_resource_group.shared.name
  type                         = local.avd_application_group_type
  host_pool_id                 = azurerm_virtual_desktop_host_pool.lab.id
  friendly_name                = var.avd_config.desktop_display_name
  default_desktop_display_name = var.avd_config.desktop_display_name
  tags                         = local.tags
}

// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/virtual_desktop_workspace
resource "azurerm_virtual_desktop_workspace" "lab" {
  name                = var.avd_config.workspace_name
  location            = azurerm_resource_group.shared.location
  resource_group_name = azurerm_resource_group.shared.name
  friendly_name       = var.avd_config.desktop_display_name
  tags                = local.tags
}

// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/virtual_desktop_workspace_application_group_association
resource "azurerm_virtual_desktop_workspace_application_group_association" "lab" {
  workspace_id         = azurerm_virtual_desktop_workspace.lab.id
  application_group_id = azurerm_virtual_desktop_application_group.desktop.id
}

// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/virtual_desktop_host_pool_registration_info
resource "azurerm_virtual_desktop_host_pool_registration_info" "lab" {
  count = var.avd_session_host_count > 0 ? 1 : 0

  hostpool_id     = azurerm_virtual_desktop_host_pool.lab.id
  expiration_date = var.avd_registration_expiration

  lifecycle {
    precondition {
      condition     = try(timecmp(var.avd_registration_expiration, timeadd(plantimestamp(), local.avd_registration_minimum_age)) >= 0 && timecmp(var.avd_registration_expiration, timeadd(plantimestamp(), local.avd_registration_maximum_age)) <= 0, false)
      error_message = "The registration expiry must be between one hour and 30 days from this plan. Choose a new explicit expiry when adding hosts."
    }
  }
}

// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/network_interface
resource "azurerm_network_interface" "session_hosts" {
  for_each = local.session_hosts

  name                = "${each.key}-nic"
  location            = azurerm_resource_group.shared.location
  resource_group_name = azurerm_resource_group.shared.name
  tags                = local.tags

  ip_configuration {
    name                          = local.avd_nic_ip_configuration
    subnet_id                     = azurerm_subnet.lab["avd"].id
    private_ip_address_allocation = local.avd_private_ip_allocation
  }
}

// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/windows_virtual_machine
resource "azurerm_windows_virtual_machine" "session_hosts" {
  for_each = local.session_hosts

  name                  = each.key
  computer_name         = each.key
  location              = azurerm_resource_group.shared.location
  resource_group_name   = azurerm_resource_group.shared.name
  size                  = var.avd_config.session_host_size
  network_interface_ids = [azurerm_network_interface.session_hosts[each.key].id]
  admin_username        = var.avd_config.admin_username
  admin_password        = var.avd_admin_password
  source_image_id       = local.avd_source_image_id
  license_type          = local.avd_license_type
  secure_boot_enabled   = local.avd_secure_boot_enabled
  vtpm_enabled          = local.avd_vtpm_enabled
  tags                  = local.tags

  identity {
    type = local.avd_identity_type
  }

  boot_diagnostics {
    storage_account_uri = azurerm_storage_account.boot_diagnostics.primary_blob_endpoint
  }

  os_disk {
    name                 = "${each.key}-osdisk"
    caching              = local.avd_os_disk_caching
    storage_account_type = var.avd_config.session_host_os_disk_type
  }

  lifecycle {
    replace_triggered_by = [azurerm_virtual_desktop_host_pool.lab.id]
  }

  depends_on = [
    azurerm_subnet_network_security_group_association.lab,
    azurerm_subnet_nat_gateway_association.lab,
    azurerm_nat_gateway_public_ip_association.lab,
  ]
}

// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/virtual_machine_extension
resource "azurerm_virtual_machine_extension" "entra_join" {
  for_each = local.session_hosts

  name                       = local.avd_extensions.entra_join.name
  virtual_machine_id         = azurerm_windows_virtual_machine.session_hosts[each.key].id
  publisher                  = local.avd_extensions.entra_join.publisher
  type                       = local.avd_extensions.entra_join.type
  type_handler_version       = local.avd_aad_extension_version
  auto_upgrade_minor_version = local.avd_extensions.entra_join.auto_upgrade_minor_version
  automatic_upgrade_enabled  = local.avd_extensions.entra_join.automatic_upgrade_enabled
  settings                   = jsonencode(local.avd_extensions.entra_join.settings)
  tags                       = local.tags
}

// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/virtual_machine_extension
resource "azurerm_virtual_machine_extension" "avd_registration" {
  for_each = local.session_hosts

  name                       = local.avd_extensions.registration.name
  virtual_machine_id         = azurerm_windows_virtual_machine.session_hosts[each.key].id
  publisher                  = local.avd_extensions.registration.publisher
  type                       = local.avd_extensions.registration.type
  type_handler_version       = local.avd_script_extension_version
  auto_upgrade_minor_version = local.avd_extensions.registration.auto_upgrade_minor_version
  protected_settings = jsonencode({
    commandToExecute = local.avd_registration_command
  })
  tags = local.tags

  lifecycle {
    precondition {
      condition     = length(local.avd_registration_command) <= local.avd_bootstrap_command_limit
      error_message = "The protected AVD bootstrap exceeds the Windows command-line limit. Use an approved script-distribution path."
    }
  }

  depends_on = [azurerm_virtual_machine_extension.entra_join]
}


// Assign LabUsers required RBAC rights!
// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/role_assignment
resource "azurerm_role_assignment" "lab_desktop_users" {
  count = var.num_of_labusers > 0 ? 1 : 0

  scope                = azurerm_virtual_desktop_application_group.desktop.id
  role_definition_name = local.avd_desktop_user_role
  principal_id         = azuread_group.lab_users[0].object_id
  principal_type       = local.lab_user_group_principal_type

  depends_on = [azuread_group_member.lab_users]
}

// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/role_assignment
resource "azurerm_role_assignment" "lab_session_host_users" {
  for_each = var.num_of_labusers > 0 ? local.session_hosts : {}

  scope                = azurerm_windows_virtual_machine.session_hosts[each.key].id
  role_definition_name = local.avd_vm_user_role
  principal_id         = azuread_group.lab_users[0].object_id
  principal_type       = local.lab_user_group_principal_type

  depends_on = [azuread_group_member.lab_users]
}
