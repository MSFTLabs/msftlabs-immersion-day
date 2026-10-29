variable "gallery_name" {
  type        = string
  description = "Compute gallery name, unique within the subscription; no hyphens."

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9_.]{0,79}$", var.gallery_name))
    error_message = "Use 1-80 characters, starting with a letter, containing letters, digits, underscores or periods."
  }
}

variable "image_definition_name" {
  type        = string
  description = "Image definition receiving the Packer-managed image versions."
}

variable "location" {
  type        = string
  description = "Azure region code for the gallery and build VM, such as eastus2."
}

variable "owner" {
  type        = string
  description = "Responsible organizer or team recorded on every resource."

  validation {
    condition     = length(trimspace(var.owner)) > 0
    error_message = "An Owner tag value is required."
  }
}

variable "replication_regions" {
  type        = list(string)
  description = "Additional lab regions; the gallery/build region is always included."
}

variable "resource_group_name" {
  type        = string
  description = "Core shared lab resource group containing gallery, networking, AVD, credentials and monitoring infrastructure."
}

variable "subscription_id" {
  type        = string
  description = "Enabled subscription ID in the target tenant; never inferred from the current CLI default."

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "Supply an enabled Azure subscription's GUID."
  }
}

variable "tags" {
  type        = map(string)
  description = "Additional organizer tags. Owner, ManagedBy and Purpose are enforced separately."
}

variable "tenant_id" {
  type        = string
  description = "Tenant containing the lab resources, configured in terraform.tfvars."

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$", var.tenant_id))
    error_message = "Supply the target Microsoft Entra tenant GUID."
  }
}

variable "gallary_sharing" {
  type        = string
  description = "Sharing permission for the gallery, such as 'Private', 'Groups' or 'Community'."

  validation {
    condition     = contains(["Private", "Groups", "Community"], var.gallary_sharing)
    error_message = "gallary_sharing must be either 'Private', 'Groups' or 'Community'."
  }
}

variable "image_ostype" {
  type        = string
  description = "Operating system type for the lab image, such as Windows or Linux."
  validation {
    condition     = contains(["Windows", "Linux"], var.image_ostype)
    error_message = "image_ostype must be either 'Windows' or 'Linux'."
  }
}

variable "image_description" {
  type        = string
  description = "Description for the lab image."

  validation {
    condition     = length(trimspace(var.image_description)) > 0
    error_message = "An image description is required."
  }
}

variable "image_identifier" {
  type = object({
    publisher = string
    offer     = string
    sku       = string
  })
  description = "Identifier for the lab image, including publisher, offer, and SKU."
}

variable "network_config" {
  type = object({
    name                    = string
    address_space           = string
    avd_subnet_name         = string
    avd_subnet_cidr         = string
    image_build_subnet_name = string
    image_build_subnet_cidr = string
    bastion_subnet_cidr     = string
  })
  description = "VNet and non-overlapping IPv4 subnet configuration for AVD, image builds and Bastion."

  validation {
    condition = alltrue([
      for cidr in [var.network_config.address_space, var.network_config.avd_subnet_cidr, var.network_config.image_build_subnet_cidr, var.network_config.bastion_subnet_cidr] : can(cidrnetmask(cidr))
    ])
    error_message = "Supply valid IPv4 CIDRs for the VNet and each subnet."
  }

  validation {
    condition     = try(tonumber(split("/", var.network_config.bastion_subnet_cidr)[1]) <= 26, false)
    error_message = "AzureBastionSubnet must be /26 or larger."
  }

  validation {
    condition = try(alltrue([
      for subnet in [var.network_config.avd_subnet_cidr, var.network_config.image_build_subnet_cidr, var.network_config.bastion_subnet_cidr] : cidrcontains(var.network_config.address_space, cidrhost(subnet, 0)) && cidrcontains(var.network_config.address_space, cidrhost(subnet, -1))
    ]), false)
    error_message = "All subnets must fit within the VNet address space."
  }

  validation {
    condition = try(alltrue([
      for pair in setproduct([var.network_config.avd_subnet_cidr, var.network_config.image_build_subnet_cidr, var.network_config.bastion_subnet_cidr], [var.network_config.avd_subnet_cidr, var.network_config.image_build_subnet_cidr, var.network_config.bastion_subnet_cidr]) : pair[0] == pair[1] || (!cidrcontains(pair[0], cidrhost(pair[1], 0)) && !cidrcontains(pair[1], cidrhost(pair[0], 0)))
    ]) && length(toset([var.network_config.avd_subnet_cidr, var.network_config.image_build_subnet_cidr, var.network_config.bastion_subnet_cidr])) == 3, false)
    error_message = "AVD, image-build and Bastion subnet ranges must be distinct and non-overlapping."
  }
}

variable "runner_config" {
  type = object({
    name              = string
    size              = string
    admin_username    = string
    github_repository = string
  })
  description = "Self-hosted GitHub Actions runner VM placed in the image_build subnet; Packer builds run from it over private networking."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,13}[a-z0-9]$", var.runner_config.name)) && can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.runner_config.github_repository))
    error_message = "Use a 3-15 character lowercase runner name and an owner/repository GitHub repository."
  }
}

variable "bastion_config" {
  type = object({
    name              = string
    sku               = string
    tunneling_enabled = bool
  })
  description = "Public Bastion configuration; AzureBastionSubnet has no NSG."

  validation {
    condition     = contains(["Basic", "Standard"], var.bastion_config.sku) && (!var.bastion_config.tunneling_enabled || var.bastion_config.sku == "Standard")
    error_message = "Use Basic or Standard; native-client tunneling requires Standard."
  }
}

variable "avd_config" {
  type = object({
    host_pool_name            = string
    workspace_name            = string
    application_group_name    = string
    desktop_display_name      = string
    session_host_name_prefix  = string
    session_host_size         = string
    session_host_os_disk_type = string
    maximum_sessions_per_host = number
    load_balancer_type        = string
    admin_username            = string
  })
  description = "Pooled desktop and session-host configuration; all resources use the existing resource group and location."

  validation {
    condition     = contains(["BreadthFirst", "DepthFirst"], var.avd_config.load_balancer_type) && var.avd_config.maximum_sessions_per_host >= 1 && var.avd_config.maximum_sessions_per_host == floor(var.avd_config.maximum_sessions_per_host)
    error_message = "Use BreadthFirst or DepthFirst and a positive integer session limit."
  }

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9-]{0,10}$", var.avd_config.session_host_name_prefix))
    error_message = "The session-host prefix must start with a letter and contain at most 11 letters, digits or hyphens."
  }
}

variable "avd_session_host_count" {
  type        = number
  description = "Session-host count; use zero for the first gallery/network apply before publishing the image."

  validation {
    condition     = var.avd_session_host_count >= 0 && var.avd_session_host_count <= 999 && var.avd_session_host_count == floor(var.avd_session_host_count)
    error_message = "The session-host count must be an integer from 0 to 999."
  }
}

variable "avd_image_version" {
  type        = string
  description = "Published numeric Major.Minor.Patch version under this root's gallery definition; required for positive host counts."

  validation {
    condition     = var.avd_image_version == null ? var.avd_session_host_count == 0 : can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.avd_image_version))
    error_message = "Supply a pinned gallery image version when deploying session hosts, or keep the count at zero."
  }
}

variable "avd_admin_password" {
  type        = string
  description = "Sensitive local administrator input; keep null in committed tfvars and supply any real secret through an approved runtime override. It is stored in local state."
  sensitive   = true

  validation {
    condition     = var.avd_admin_password == null ? var.avd_session_host_count == 0 : length(var.avd_admin_password) >= 12 && length(var.avd_admin_password) <= 123
    error_message = "A 12-123 character administrator password is required when deploying session hosts."
  }
}

variable "avd_registration_expiration" {
  type        = string
  description = "Explicit RFC3339 registration-token expiry, between one hour and 30 days after deployment; renew deliberately when adding hosts."

  validation {
    condition     = var.avd_registration_expiration == null ? var.avd_session_host_count == 0 : can(formatdate("YYYY-MM-DD", var.avd_registration_expiration))
    error_message = "Supply an explicit RFC3339 registration expiry when deploying session hosts."
  }
}

variable "num_of_labusers" {
  type        = number
  description = "Number of Entra lab users to create and grant AVD access; an integer from 0 to 999."

  validation {
    condition     = var.num_of_labusers >= 0 && var.num_of_labusers <= 999 && var.num_of_labusers == floor(var.num_of_labusers)
    error_message = "num_of_labusers must be an integer from 0 to 999."
  }
}

variable "monitoring_config" {
  type = object({
    boot_storage_name_prefix = string
    workspace_name           = string
    workspace_retention_days = number
    workspace_daily_quota_gb = number
  })
  description = "Boot-diagnostics storage naming and shared Log Analytics workspace configuration; fixed collection/security settings remain in locals."

  validation {
    condition     = can(regex("^[a-z0-9]{1,16}$", var.monitoring_config.boot_storage_name_prefix))
    error_message = "Use 1-16 lowercase letters/digits for the boot storage prefix; an eight-character unique suffix is appended."
  }

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9-]{2,61}[A-Za-z0-9]$", var.monitoring_config.workspace_name))
    error_message = "Use 4-63 letters/digits/hyphens for the workspace name, without a leading or trailing hyphen."
  }

  validation {
    condition     = var.monitoring_config.workspace_retention_days >= 30 && var.monitoring_config.workspace_retention_days <= 730 && var.monitoring_config.workspace_retention_days == floor(var.monitoring_config.workspace_retention_days)
    error_message = "Workspace retention must be an integer from 30 to 730 days."
  }

  validation {
    condition     = var.monitoring_config.workspace_daily_quota_gb == -1 || var.monitoring_config.workspace_daily_quota_gb > 0
    error_message = "Use -1 for uncapped ingestion or a positive daily quota in GB; a reached cap interrupts log collection."
  }
}

variable "key_vault_config" {
  type = object({
    name_prefix         = string
    staff_principal_ids = set(string)
  })
  description = "Credential-vault name prefix and approved staff Entra object IDs with secret-read access; fixed security settings remain in locals."

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9-]{0,14}$", var.key_vault_config.name_prefix)) && !endswith(var.key_vault_config.name_prefix, "-") && !strcontains(var.key_vault_config.name_prefix, "--")
    error_message = "Use a 1-15 character vault prefix starting with a letter, without trailing or consecutive hyphens; a unique suffix is derived in locals."
  }

  validation {
    condition     = alltrue([for principal in var.key_vault_config.staff_principal_ids : can(regex("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$", principal))])
    error_message = "Staff principals must be Entra user/group/service-principal object GUIDs, not names or client IDs."
  }
}



