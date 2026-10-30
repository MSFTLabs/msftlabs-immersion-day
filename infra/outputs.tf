output "shared_resource_group" {
  description = "Core shared lab infrastructure resource group, separate from student exercise groups."
  value = {
    name     = azurerm_resource_group.shared.name
    id       = azurerm_resource_group.shared.id
    location = azurerm_resource_group.shared.location
  }
}

output "monitoring_configuration" {
  description = "Boot-diagnostics storage and central resource-log destinations; no access keys or credentials."
  value = {
    boot_storage_name      = azurerm_storage_account.boot_diagnostics.name
    boot_storage_id        = azurerm_storage_account.boot_diagnostics.id
    boot_blob_endpoint     = azurerm_storage_account.boot_diagnostics.primary_blob_endpoint
    workspace_name         = azurerm_log_analytics_workspace.lab.name
    workspace_id           = azurerm_log_analytics_workspace.lab.id
    workspace_customer_id  = azurerm_log_analytics_workspace.lab.workspace_id
    diagnostic_setting_ids = { for name, setting in azurerm_monitor_diagnostic_setting.shared : name => setting.id }
  }
}

output "gallery_id" {
  description = "Gallery resource ID for RBAC assignments and organizer lookup."
  value       = azurerm_shared_image_gallery.lab.id
}

output "image_definition_id" {
  description = "Image definition ID; Packer publishes versions under this definition."
  value       = azurerm_shared_image.windows11.id
}

output "packer_configuration" {
  description = "Non-secret configuration consumed by the Packer job running on the in-VNet runner."
  value = {
    subscription_id                     = var.subscription_id
    tenant_id                           = var.tenant_id
    location                            = var.location
    gallery_resource_group              = azurerm_resource_group.shared.name
    gallery_name                        = azurerm_shared_image_gallery.lab.name
    image_definition_name               = azurerm_shared_image.windows11.name
    replication_regions                 = distinct(concat([var.location], local.replication_regions))
    tags                                = local.tags
    virtual_network_name                = azurerm_virtual_network.lab.name
    virtual_network_resource_group_name = azurerm_resource_group.shared.name
    virtual_network_subnet_name         = azurerm_subnet.lab["image_build"].name
  }
}

output "runner_configuration" {
  description = "Self-hosted runner VM identifiers and access hints; the admin password is only in the lab Key Vault."
  value = {
    name                 = azurerm_linux_virtual_machine.runner.name
    id                   = azurerm_linux_virtual_machine.runner.id
    resource_group_name  = azurerm_resource_group.shared.name
    private_ip_address   = azurerm_network_interface.runner.private_ip_address
    principal_id         = azurerm_linux_virtual_machine.runner.identity[0].principal_id
    admin_username       = local.runner_admin_username
    admin_password_vault = "${azurerm_key_vault.lab_credentials.vault_uri}secrets/${local.runner_secret_name}"
    github_repository    = local.runner_github_repository
    labels               = local.runner_labels
  }
}

output "portal_url" {
  description = "Tenant-qualified link to the gallery in the Azure Portal."
  value       = "https://portal.azure.com/#@${var.tenant_id}/resource${azurerm_shared_image_gallery.lab.id}/overview"
}

output "network_configuration" {
  description = "Lab VNet, subnet and Bastion IDs. The image_build subnet hosts the runner and Packer build VMs."
  value = {
    virtual_network_id                  = azurerm_virtual_network.lab.id
    virtual_network_name                = azurerm_virtual_network.lab.name
    virtual_network_resource_group_name = azurerm_resource_group.shared.name
    virtual_network_subnet_name         = azurerm_subnet.lab["image_build"].name
    subnet_ids                          = { for name, subnet in azurerm_subnet.lab : name => subnet.id }
    bastion_id                          = azurerm_bastion_host.lab.id
    egress_public_ip                    = azurerm_public_ip.egress.ip_address
  }
}

output "avd_configuration" {
  description = "AVD resource IDs and private session hosts; no registration token or administrator password."
  value = {
    host_pool_id         = azurerm_virtual_desktop_host_pool.lab.id
    workspace_id         = azurerm_virtual_desktop_workspace.lab.id
    application_group_id = azurerm_virtual_desktop_application_group.desktop.id
    session_host_ids     = { for name, host in azurerm_windows_virtual_machine.session_hosts : name => host.id }
    session_host_ips     = { for name, nic in azurerm_network_interface.session_hosts : name => nic.private_ip_address }
    image_version        = var.avd_image_version
    portal_url           = "https://portal.azure.com/#@${var.tenant_id}/resource${azurerm_virtual_desktop_host_pool.lab.id}/overview"
  }
}

output "lab_users" {
  description = "Created lab users and their Entra object IDs, without passwords."
  value = {
    for name, user in azuread_user.lab : name => {
      user_principal_name = user.user_principal_name
      object_id           = user.object_id
    }
  }
}

output "lab_user_group_id" {
  description = "Entra group receiving desktop access and session-host VM User Login."
  value       = var.num_of_labusers == 0 ? null : azuread_group.lab_users[0].object_id
}

output "lab_resource_groups" {
  description = "Per-user exercise resource groups and their corresponding Entra owners; no credentials."
  value = {
    for name, group in azurerm_resource_group.lab_users : name => {
      name                 = group.name
      id                   = group.id
      owner_object_id      = azuread_user.lab[name].object_id
      owner_principal_name = azuread_user.lab[name].user_principal_name
    }
  }
}

output "lab_user_initial_credentials" {
  description = "Sensitive initial credentials for organizer distribution only. Passwords are stale after students change them and are stored in local state."
  sensitive   = true
  value = {
    for name, user in azuread_user.lab : name => {
      user_principal_name = user.user_principal_name
      initial_password    = user.password
    }
  }
}

output "lab_users_csv_path" {
  description = "Staff CSV generated during apply with LabUser, Password, TAP and Assigned Student columns; contains plaintext secrets and must remain access-restricted."
  value       = local.lab_credentials_csv_path
}

output "lab_credentials_key_vault" {
  description = "Credential vault location and versionless secret IDs; no passwords or TAP values."
  value = {
    name      = azurerm_key_vault.lab_credentials.name
    id        = azurerm_key_vault.lab_credentials.id
    vault_uri = azurerm_key_vault.lab_credentials.vault_uri
    secret_ids = {
      for name in keys(local.lab_users) : name => "${azurerm_key_vault.lab_credentials.vault_uri}secrets/${format(local.lab_key_vault_secret_name_format, lower(name))}"
    }
  }
}