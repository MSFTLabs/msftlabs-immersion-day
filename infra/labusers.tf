// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/role_assignment
resource "azurerm_role_assignment" "lab_credentials_writer" {
  scope                = azurerm_key_vault.lab_credentials.id
  role_definition_name = local.lab_key_vault_writer_role
  principal_id         = data.azurerm_client_config.lab_credentials.object_id
}

// https://search.opentofu.org/provider/hashicorp/azurerm/latest/docs/resources/role_assignment
resource "azurerm_role_assignment" "lab_credentials_staff" {
  for_each = local.key_vault_staff_principal_ids

  scope                = azurerm_key_vault.lab_credentials.id
  role_definition_name = local.lab_key_vault_reader_role
  principal_id         = each.value
}

// Setup LabUsers and Accounts in Entra
// https://search.opentofu.org/provider/hashicorp/azuread/latest/docs/data-sources/client_config
data "azuread_client_config" "lab" {
  count = var.num_of_labusers > 0 ? 1 : 0
}

// https://search.opentofu.org/provider/hashicorp/azuread/latest/docs/data-sources/domains
data "azuread_domains" "lab" {
  count = var.num_of_labusers > 0 ? 1 : 0

  only_default = local.lab_user_domain_default
}

// https://search.opentofu.org/provider/hashicorp/random/latest/docs/resources/password
resource "random_password" "lab_users" {
  for_each = local.lab_users

  length           = local.lab_user_password.length
  upper            = local.lab_user_password.upper
  lower            = local.lab_user_password.lower
  numeric          = local.lab_user_password.numeric
  special          = local.lab_user_password.special
  min_upper        = local.lab_user_password.min_upper
  min_lower        = local.lab_user_password.min_lower
  min_numeric      = local.lab_user_password.min_numeric
  min_special      = local.lab_user_password.min_special
  override_special = local.lab_user_password.override_special

  keepers = {
    tenant_id       = var.tenant_id
    subscription_id = var.subscription_id
    lab_user        = each.key
  }
}

// https://search.opentofu.org/provider/hashicorp/azuread/latest/docs/resources/user
resource "azuread_user" "lab" {
  for_each = local.lab_users

  display_name          = each.value.name
  user_principal_name   = "${each.value.name}@${local.lab_user_domain.domain_name}"
  mail_nickname         = lower(each.value.name)
  account_enabled       = local.lab_user_account_enabled
  usage_location        = local.lab_user_usage_location
  password              = random_password.lab_users[each.key].result
  force_password_change = local.lab_user_force_password_change

  lifecycle {
    ignore_changes = [force_password_change]

    precondition {
      condition     = local.lab_user_domain.authentication_type == local.lab_user_domain_authentication
      error_message = "The tenant default domain must use managed authentication for cloud-only lab users. Review domain settings before deployment."
    }
  }
}

// https://search.opentofu.org/provider/hashicorp/azuread/latest/docs/resources/group
resource "azuread_group" "lab_users" {
  count = var.num_of_labusers > 0 ? 1 : 0

  display_name            = local.lab_user_group_name
  description             = local.lab_user_group_description
  security_enabled        = local.lab_user_group_security_enabled
  mail_enabled            = local.lab_user_group_mail_enabled
  prevent_duplicate_names = local.lab_user_group_prevent_duplicates
  owners                  = [data.azuread_client_config.lab[0].object_id]
}

// https://search.opentofu.org/provider/hashicorp/azuread/latest/docs/resources/group_member
resource "azuread_group_member" "lab_users" {
  for_each = local.lab_users

  group_object_id  = azuread_group.lab_users[0].object_id
  member_object_id = azuread_user.lab[each.key].object_id
}

// https://search.opentofu.org/provider/microsoft/msgraph/latest/docs/data-sources/resource
data "msgraph_resource" "lab_tap_policy" {
  count = var.num_of_labusers > 0 ? 1 : 0

  url         = local.lab_tap_policy_url
  api_version = local.lab_tap_graph_api_version
  response_export_values = {
    state            = "state"
    include_targets  = "includeTargets"
    exclude_targets  = "excludeTargets"
  }
}

// https://search.opentofu.org/provider/microsoft/msgraph/latest/docs/resources/resource_action
resource "msgraph_resource_action" "lab_tap_policy" {
  count = var.num_of_labusers > 0 ? 1 : 0

  resource_url = local.lab_tap_policy_url
  api_version  = local.lab_tap_graph_api_version
  method       = local.lab_tap_policy_method
  when         = local.lab_tap_action_when
  body = {
    "@odata.type"  = local.lab_tap_policy_type
    state          = local.lab_tap_policy_state
    includeTargets = local.lab_tap_include_targets

    minimumLifetimeInMinutes = local.lab_tap_minimum_lifetime
    maximumLifetimeInMinutes = local.lab_tap_maximum_lifetime
    defaultLifetimeInMinutes = local.lab_tap_lifetime_minutes
    defaultLength            = local.lab_tap_length
    isUsableOnce             = local.lab_tap_is_usable_once
  }

  lifecycle {
    precondition {
      condition     = alltrue([for target in local.lab_tap_existing_policy.exclude_targets : !contains(["all_users", "allUsers", azuread_group.lab_users[0].object_id], target.id)])
      error_message = "The lab group or all users are excluded from TAP. Review this with an Authentication Policy Administrator; exclusions will not be bypassed."
    }
  }

  depends_on = [azuread_group_member.lab_users]
}

// https://opentofu.org/docs/language/resources/tf-data/
resource "terraform_data" "lab_tap_policy_cleanup" {
  count = var.num_of_labusers > 0 ? 1 : 0

  input = {
    script_path = abspath("${path.module}/scripts/Publish-LabCredentials.ps1")
    interpreter = local.lab_credentials_export_interpreter
    settings = {
      tenant_id         = var.tenant_id
      graph_base_uri    = local.lab_graph_base_uri
      graph_api_version = local.lab_tap_graph_api_version
      policy_url        = local.lab_tap_policy_url
      policy_type       = local.lab_tap_policy_type
      group_id          = azuread_group.lab_users[0].object_id
    }
  }

  provisioner "local-exec" {
    when        = destroy
    command     = "& $env:LAB_CREDENTIAL_PUBLISH_SCRIPT -Mode Cleanup"
    interpreter = self.input.interpreter
    environment = {
      LAB_CREDENTIAL_PUBLISH_SCRIPT = self.input.script_path
      LAB_PUBLISH_SETTINGS          = jsonencode(self.input.settings)
    }
  }

  depends_on = [msgraph_resource_action.lab_tap_policy]
}