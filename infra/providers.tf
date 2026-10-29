provider "azurerm" {
  subscription_id                 = var.subscription_id
  tenant_id                       = var.tenant_id
  resource_provider_registrations = "none"

  features {
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
    key_vault {
      purge_soft_delete_on_destroy          = local.lab_key_vault_purge_on_destroy
      purge_soft_deleted_secrets_on_destroy = local.lab_key_vault_purge_secrets_on_destroy
    }
  }
}

provider "azuread" {
  tenant_id = var.tenant_id
  use_cli   = true
}

provider "random" {}

provider "msgraph" {
  tenant_id = var.tenant_id
  use_cli   = true
}