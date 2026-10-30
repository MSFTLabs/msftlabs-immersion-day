locals {
  tags = merge(var.tags, {
    ManagedBy = "OpenTF"
    // Required to bypass MCAPS security control checks
    SecurityControl = "Ignore"
    Owner           = var.owner
  })

  // Image Gallery Configurations
  gallery_name          = "msftlabs_cus_immersionday_gallery"
  image_definition_name = "win11-immersionday-lab"
  replication_regions   = []
  gallery_sharing       = "Private"
  image_os_type         = "Windows"
  image_description     = "Windows 11 Enterprise multi-session with immersion-day lab tools."
  image_identifier = {
    publisher = "MSFTLABS"
    offer     = "ImmersionDay"
    sku       = "Windows11EnterpriseMultiSession"
  }

  // Bastion Configurations
  bastion_name              = "msftlabs-cus-immersionday-bastion"
  bastion_sku               = "Standard"
  bastion_tunneling_enabled = true

  // Runner Identity (also hosts Packer image builds inside the VNet)
  runner_name              = "msftlabs-runner"
  runner_size              = "Standard_D2s_v5"
  runner_admin_username    = "runneradmin"
  runner_github_repository = "MSFTLabs/msftlabs-immersion-day"

  // Image Settings that shouldn't be changed without review.
  image_architecture           = "x64"
  image_generation             = "V2"
  image_specialized            = false
  image_trusted_launch_enabled = true

  key_vault_name_prefix         = "kv-msftlabs-cus"
  key_vault_staff_principal_ids = toset([])

  monitoring_boot_storage_name_prefix = "stmsftcusboot"
  monitoring_workspace_name           = "law-msftlabs-cus-immersionday"
  monitoring_workspace_retention_days = 30
  monitoring_workspace_daily_quota_gb = -1

  boot_diagnostics_storage_name                  = "${local.monitoring_boot_storage_name_prefix}${substr(sha256("${var.tenant_id}:${var.subscription_id}:${var.resource_group_name}:boot"), 0, 8)}"
  boot_diagnostics_storage_kind                  = "StorageV2"
  boot_diagnostics_storage_tier                  = "Standard"
  boot_diagnostics_storage_replication           = "LRS"
  boot_diagnostics_https_only                    = true
  boot_diagnostics_min_tls_version               = "TLS1_2"
  boot_diagnostics_public_blobs                  = false
  boot_diagnostics_shared_key_enabled            = false
  boot_diagnostics_local_user_enabled            = false
  monitoring_public_network_access               = "Enabled"
  monitoring_workspace_sku                       = "PerGB2018"
  monitoring_workspace_local_authentication      = false
  monitoring_workspace_resource_only_permissions = false
  monitoring_diagnostic_setting_name             = "lab-to-log-analytics"
  monitoring_avd_destination_type                = null
  monitoring_targets = merge({
    bastion = {
      resource_id      = azurerm_bastion_host.lab.id
      destination_type = null
    }
    avd_host_pool = {
      resource_id      = azurerm_virtual_desktop_host_pool.lab.id
      destination_type = local.monitoring_avd_destination_type
    }
    avd_application_group = {
      resource_id      = azurerm_virtual_desktop_application_group.desktop.id
      destination_type = local.monitoring_avd_destination_type
    }
    avd_workspace = {
      resource_id      = azurerm_virtual_desktop_workspace.lab.id
      destination_type = local.monitoring_avd_destination_type
    }
    }, {
    for name in keys(local.subnet_rules) : "nsg_${name}" => {
      resource_id      = azurerm_network_security_group.subnets[name].id
      destination_type = null
    }
  })

  // Networking Configurations
  subnet_default_outbound_access = { bastion = null, avd = false, image_build = false }
  nat_gateway_subnets            = toset(["avd", "image_build"])
  public_ip_allocation_method    = "Static"
  public_ip_sku                  = "Standard"
  nat_gateway_sku                = "Standard"
  bastion_ip_configuration_name  = "bastion"
  nsg_allowed_rule_access        = "Allow"
  nsg_source_port_range          = "*"
  nsg_default_inbound_rule = {
    name                       = "DenyOtherInbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  subnets = {
    avd = {
      name = var.network_config.avd_subnet_name
      cidr = var.network_config.avd_subnet_cidr
    }
    image_build = {
      name = var.network_config.image_build_subnet_name
      cidr = var.network_config.image_build_subnet_cidr
    }
    bastion = {
      name = "AzureBastionSubnet"
      cidr = var.network_config.bastion_subnet_cidr
    }
  }

  private_subnet_rules = {
    AllowBastionRdp = { priority = 100, direction = "Inbound", protocol = "Tcp", sources = toset([var.network_config.bastion_subnet_cidr]), destination = "*", ports = ["3389"] }
  }

  // Runner + Packer build subnet: Bastion admin access, and the runner reaching Windows build VMs over WinRM inside the subnet.
  runner_build_subnet_rules = {
    AllowBastionAdmin    = { priority = 100, direction = "Inbound", protocol = "Tcp", sources = toset([var.network_config.bastion_subnet_cidr]), destination = "*", ports = ["22", "3389"] }
    AllowWinRmFromSubnet = { priority = 110, direction = "Inbound", protocol = "Tcp", sources = toset([var.network_config.image_build_subnet_cidr]), destination = "*", ports = ["5985", "5986"] }
  }

  subnet_rules = {
    avd         = local.private_subnet_rules
    image_build = local.runner_build_subnet_rules
  }

  // Self-hosted GitHub runner
  runner_labels                = ["self-hosted", "linux", "msftlabs-image"]
  runner_image_publisher       = "Canonical"
  runner_image_offer           = "ubuntu-24_04-lts"
  runner_image_sku             = "server"
  runner_image_version         = "latest"
  runner_os_disk_caching       = "ReadWrite"
  runner_os_disk_type          = "StandardSSD_LRS"
  runner_os_disk_size_gb       = 128
  runner_identity_type         = "SystemAssigned"
  runner_private_ip_allocation = "Dynamic"
  runner_nic_ip_configuration  = "private"
  runner_secret_name           = "runner-admin-password"
  runner_contributor_role      = "Contributor"
  runner_secure_boot_enabled   = true
  runner_vtpm_enabled          = true
  runner_cloud_init = templatefile("${path.module}/scripts/runner-cloud-init.yaml", {
    admin_username = local.runner_admin_username
  })

  // AVD Configurations
  avd_host_pool_type             = "Pooled"
  avd_application_group_type     = "Desktop"
  avd_preferred_app_group        = "Desktop"
  avd_custom_rdp_properties      = "enablerdsaadauth:i:1;targetisaadjoined:i:1;redirectclipboard:i:1;"
  avd_license_type               = "Windows_Client"
  avd_start_vm_on_connect        = false
  avd_validate_environment       = false
  avd_secure_boot_enabled        = true
  avd_vtpm_enabled               = true
  avd_identity_type              = "SystemAssigned"
  avd_os_disk_caching            = "ReadWrite"
  avd_nic_ip_configuration       = "private"
  avd_private_ip_allocation      = "Dynamic"
  avd_desktop_user_role          = "Desktop Virtualization User"
  avd_vm_user_role               = "Virtual Machine User Login"
  avd_registration_minimum_age   = "1h"
  avd_registration_maximum_age   = "720h"
  avd_bootstrap_command_limit    = 8191
  avd_aad_extension_version      = "2.2"
  avd_script_extension_version   = "1.10"
  avd_session_host_api_version   = "2024-04-03"
  avd_record_cleanup_interpreter = ["pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command"]
  avd_extensions = {
    entra_join = {
      name                       = "AADLoginForWindows"
      publisher                  = "Microsoft.Azure.ActiveDirectory"
      type                       = "AADLoginForWindows"
      auto_upgrade_minor_version = true
      automatic_upgrade_enabled  = false
      settings                   = { mdmId = "" }
    }
    registration = {
      name                       = "RegisterAvdSessionHost"
      publisher                  = "Microsoft.Compute"
      type                       = "CustomScriptExtension"
      auto_upgrade_minor_version = true
    }
  }
  avd_source_image_id = var.avd_image_version == null ? null : "${azurerm_shared_image.windows11.id}/versions/${var.avd_image_version}"
  // Plain base64, not gzip: the Custom Script extension silently skips the gzip-stream form (verified on a live host).
  avd_registration_command = var.avd_session_host_count == 0 ? null : format(
    "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"$t = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('%s')); Invoke-Expression $t\"",
    base64encode(templatefile("${path.module}/scripts/Register-AvdSessionHost.ps1.tftpl", {
      registration_token = azurerm_virtual_desktop_host_pool_registration_info.lab[0].token
    }))
  )

  // Lab User Configurations
  lab_user_name_format                = "LabUser%03d"
  lab_user_account_enabled            = true
  lab_user_force_password_change      = true
  lab_user_usage_location             = "US"
  lab_user_domain_default             = true
  lab_user_domain_authentication      = "Managed"
  lab_user_group_name                 = "${var.resource_group_name}-avd-labusers"
  lab_user_group_description          = "Immersion-day students with desktop access and session-host VM login."
  lab_user_group_security_enabled     = true
  lab_user_group_mail_enabled         = false
  lab_user_group_prevent_duplicates   = true
  lab_user_group_principal_type       = "Group"
  lab_user_resource_group_name_format = "LAB-%s"
  lab_user_resource_group_owner_role  = "Owner"
  lab_user_principal_type             = "User"
  lab_user_password = {
    length           = 24
    upper            = true
    lower            = true
    numeric          = true
    special          = true
    min_upper        = 1
    min_lower        = 1
    min_numeric      = 1
    min_special      = 1
    override_special = "!@#%*-_=+?"
  }
  lab_users = {
    for index in range(var.num_of_labusers) : format(local.lab_user_name_format, index + 1) => {
      name = format(local.lab_user_name_format, index + 1)
    }
  }
  lab_user_domain = var.num_of_labusers == 0 ? null : one(data.azuread_domains.lab[0].domains)

  // Temporary Access Pass (TAP) Policy Configuration so we don't need to worry about MFA
  lab_tap_graph_api_version     = "v1.0"
  lab_tap_policy_url            = "policies/authenticationMethodsPolicy/authenticationMethodConfigurations/TemporaryAccessPass"
  lab_tap_policy_type           = "#microsoft.graph.temporaryAccessPassAuthenticationMethodConfiguration"
  lab_tap_policy_state          = "enabled"
  lab_tap_target_type           = "group"
  lab_tap_registration_required = false
  lab_tap_minimum_lifetime      = 480
  lab_tap_maximum_lifetime      = 720
  lab_tap_lifetime_minutes      = 480
  lab_tap_length                = 8
  lab_tap_is_usable_once        = false
  lab_tap_policy_method         = "PATCH"
  lab_tap_issue_method          = "POST"
  lab_tap_action_when           = "apply"
  lab_tap_existing_policy       = var.num_of_labusers == 0 ? null : data.msgraph_resource.lab_tap_policy[0].output
  lab_tap_include_targets = var.num_of_labusers == 0 ? [] : concat(
    local.lab_tap_existing_policy.state == local.lab_tap_policy_state ? [
      for target in local.lab_tap_existing_policy.include_targets : target
      if target.id != azuread_group.lab_users[0].object_id
    ] : [],
    [{
      id                     = azuread_group.lab_users[0].object_id
      targetType             = local.lab_tap_target_type
      isRegistrationRequired = local.lab_tap_registration_required
    }]
  )
  lab_credentials_csv_path           = abspath("${path.module}/../artifacts/credentials/LabUsers.csv")
  lab_credentials_export_interpreter = ["pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command"]
  lab_credentials_export_command     = "& $env:LAB_CREDENTIAL_PUBLISH_SCRIPT -Mode Publish"
  lab_graph_base_uri                 = "https://graph.microsoft.com"
  lab_key_vault_secret_api_version   = "2025-07-01"
  lab_credentials_publish_rows = sensitive([
    for name in sort(keys(azuread_user.lab)) : {
      Name     = name
      ObjectId = azuread_user.lab[name].object_id
      LabUser  = azuread_user.lab[name].user_principal_name
      Password = azuread_user.lab[name].password
    }
  ])

  lab_key_vault_name                       = "${lower(local.key_vault_name_prefix)}-${substr(sha256("${var.tenant_id}:${var.subscription_id}:${var.resource_group_name}"), 0, 8)}"
  lab_key_vault_sku                        = "standard"
  lab_key_vault_rbac_enabled               = true
  lab_key_vault_public_network_access      = true
  lab_key_vault_purge_protection           = true
  lab_key_vault_purge_on_destroy           = false
  lab_key_vault_purge_secrets_on_destroy   = false
  lab_key_vault_soft_delete_retention_days = 7
  lab_key_vault_writer_role                = "Key Vault Secrets Officer"
  lab_key_vault_reader_role                = "Key Vault Secrets User"
  lab_key_vault_secret_name_format         = "%s-credentials"
  lab_key_vault_secret_content_type        = "application/json"
  lab_key_vault_credential_stage           = "InitialOnboarding"
  session_hosts = {
    for index in range(var.avd_session_host_count) : format("%s-%03d", var.avd_config.session_host_name_prefix, index + 1) => index
  }
}

