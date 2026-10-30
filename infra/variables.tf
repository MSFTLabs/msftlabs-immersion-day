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
