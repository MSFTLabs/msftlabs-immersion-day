// Fetch current User Configurations for keyvault RBAC Access (since we are running this locally)
// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/data-sources/client_config
data "azurerm_client_config" "lab_credentials" {}

moved {
  from = azurerm_resource_group.images
  to   = azurerm_resource_group.shared
}

moved {
  from = terraform_data.lab_credentials_csv
  to   = terraform_data.lab_credentials_csv[0]
}

// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/resource_group
resource "azurerm_resource_group" "shared" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/storage_account
resource "azurerm_storage_account" "boot_diagnostics" {
  name                            = local.boot_diagnostics_storage_name
  resource_group_name             = azurerm_resource_group.shared.name
  location                        = azurerm_resource_group.shared.location
  account_kind                    = local.boot_diagnostics_storage_kind
  account_tier                    = local.boot_diagnostics_storage_tier
  account_replication_type        = local.boot_diagnostics_storage_replication
  https_traffic_only_enabled      = local.boot_diagnostics_https_only
  min_tls_version                 = local.boot_diagnostics_min_tls_version
  allow_nested_items_to_be_public = local.boot_diagnostics_public_blobs
  shared_access_key_enabled       = local.boot_diagnostics_shared_key_enabled
  public_network_access           = local.monitoring_public_network_access
  tags                            = local.tags
}

// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/log_analytics_workspace
resource "azurerm_log_analytics_workspace" "lab" {
  name                            = var.monitoring_config.workspace_name
  resource_group_name             = azurerm_resource_group.shared.name
  location                        = azurerm_resource_group.shared.location
  sku                             = local.monitoring_workspace_sku
  retention_in_days               = var.monitoring_config.workspace_retention_days
  daily_quota_gb                  = var.monitoring_config.workspace_daily_quota_gb
  local_authentication_enabled    = local.monitoring_workspace_local_authentication
  allow_resource_only_permissions = local.monitoring_workspace_resource_only_permissions
  internet_ingestion_access_type  = local.monitoring_public_network_access
  internet_query_access_type      = local.monitoring_public_network_access
  tags                            = local.tags
}

// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/data-sources/monitor_diagnostic_categories
data "azurerm_monitor_diagnostic_categories" "shared" {
  for_each = local.monitoring_targets

  resource_id = each.value.resource_id
}

// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/monitor_diagnostic_setting
resource "azurerm_monitor_diagnostic_setting" "shared" {
  for_each = local.monitoring_targets

  name                           = local.monitoring_diagnostic_setting_name
  target_resource_id             = each.value.resource_id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.lab.id
  log_analytics_destination_type = each.value.destination_type

  dynamic "enabled_log" {
    for_each = toset(data.azurerm_monitor_diagnostic_categories.shared[each.key].log_category_types)
    content {
      category = enabled_log.value
    }
  }

  dynamic "enabled_metric" {
    for_each = toset(data.azurerm_monitor_diagnostic_categories.shared[each.key].metrics)
    content {
      category = enabled_metric.value
    }
  }
}

// Image Gallery Resources
// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/shared_image_gallery
resource "azurerm_shared_image_gallery" "lab" {
  name                = var.gallery_name
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location
  description         = var.image_description
  tags                = local.tags

  dynamic "sharing" {
    for_each = var.gallary_sharing == "Private" ? [] : [var.gallary_sharing]
    content {
      permission = sharing.value
    }
  }
}

// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/shared_image
resource "azurerm_shared_image" "windows11" {
  name                   = var.image_definition_name
  gallery_name           = azurerm_shared_image_gallery.lab.name
  resource_group_name    = azurerm_resource_group.shared.name
  location               = azurerm_resource_group.shared.location
  os_type                = var.image_ostype
  architecture           = local.image_architecture
  hyper_v_generation     = local.image_generation
  specialized            = local.image_specialized
  trusted_launch_enabled = local.image_trusted_launch_enabled
  description            = var.image_description
  tags                   = local.tags

  identifier {
    publisher = var.image_identifier.publisher
    offer     = var.image_identifier.offer
    sku       = var.image_identifier.sku
  }
}

// Create LabUser ResGroup Environments for each user to work on..
// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/resource_group
resource "azurerm_resource_group" "lab_users" {
  for_each = local.lab_users

  name     = format(local.lab_user_resource_group_name_format, each.key)
  location = var.location
  tags     = merge(local.tags, { LabUser = each.key })
}

// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/role_assignment
resource "azurerm_role_assignment" "lab_resource_group_owner" {
  for_each = azurerm_resource_group.lab_users

  scope                = each.value.id
  role_definition_name = local.lab_user_resource_group_owner_role
  principal_id         = azuread_user.lab[each.key].object_id
  principal_type       = local.lab_user_principal_type
}


// Keyvault is for storing User Passwords and TAPs securely in case we need them.
// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/key_vault
resource "azurerm_key_vault" "lab_credentials" {
  name                          = local.lab_key_vault_name
  location                      = azurerm_resource_group.shared.location
  resource_group_name           = azurerm_resource_group.shared.name
  tenant_id                     = var.tenant_id
  sku_name                      = local.lab_key_vault_sku
  rbac_authorization_enabled    = local.lab_key_vault_rbac_enabled
  public_network_access_enabled = local.lab_key_vault_public_network_access
  purge_protection_enabled      = local.lab_key_vault_purge_protection
  soft_delete_retention_days    = local.lab_key_vault_soft_delete_retention_days
  tags                          = local.tags
}

// Export LabUser credentials to a CSV file for us to have handy..
// https://opentofu.org/docs/language/resources/tf-data/
resource "terraform_data" "lab_credentials_csv" {
  count = var.num_of_labusers > 0 ? 1 : 0

  triggers_replace = {
    users                 = { for name, user in azuread_user.lab : name => user.object_id }
    password_fingerprints = { for name, user in azuread_user.lab : name => sha256(user.password) }
    vault                 = azurerm_key_vault.lab_credentials.id
    tap_lifetime          = local.lab_tap_lifetime_minutes
    tap_single_use        = local.lab_tap_is_usable_once
    publish_script_sha256 = filesha256("${path.module}/scripts/Publish-LabCredentials.ps1")
    export_script_sha256  = filesha256("${path.module}/scripts/Export-LabUserCsv.ps1")
  }

  provisioner "local-exec" {
    command     = local.lab_credentials_export_command
    interpreter = local.lab_credentials_export_interpreter
    environment = {
      LAB_CREDENTIAL_PUBLISH_SCRIPT = abspath("${path.module}/scripts/Publish-LabCredentials.ps1")
      LAB_PUBLISH_USERS             = sensitive(jsonencode(local.lab_credentials_publish_rows))
      LAB_PUBLISH_SETTINGS = jsonencode({
        tenant_id            = var.tenant_id
        graph_base_uri       = local.lab_graph_base_uri
        graph_api_version    = local.lab_tap_graph_api_version
        vault_uri            = azurerm_key_vault.lab_credentials.vault_uri
        vault_api_version    = local.lab_key_vault_secret_api_version
        secret_name_format   = local.lab_key_vault_secret_name_format
        content_type         = local.lab_key_vault_secret_content_type
        tap_lifetime_minutes = local.lab_tap_lifetime_minutes
        tap_is_usable_once   = local.lab_tap_is_usable_once
        csv_path             = local.lab_credentials_csv_path
      })
    }
  }

  depends_on = [
    azurerm_role_assignment.lab_desktop_users,
    azurerm_role_assignment.lab_session_host_users,
    azurerm_role_assignment.lab_resource_group_owner,
    azurerm_role_assignment.lab_credentials_writer,
    msgraph_resource_action.lab_tap_policy,
    terraform_data.lab_tap_policy_cleanup,
  ]
}
