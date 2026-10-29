// Environment Configs
subscription_id     = "934600ac-0f19-44b8-b439-b4c5f02d8a7d"
tenant_id           = "477bacc4-4ada-4431-940b-b91cf6cb3fd4"
resource_group_name = "msftlabs-cus-immersionday"
location            = "CentralUS"
owner               = "immersionday-admins"
tags = {
  Environment = "Labs"
  Project     = "msftlabs-immersion-day"
}


// Image Gallery Configs
gallery_name          = "msftlabs_cus_immersionday_gallery"
image_definition_name = "win11-immersionday-lab"
replication_regions   = ["CentralUS", "WestUS3", "WestUS2"]
gallary_sharing       = "Private"
image_ostype          = "Windows"
image_description     = "Windows 11 Enterprise multi-session with immersion-day lab tools."
image_identifier = {
  publisher = "MSFTLABS"
  offer     = "ImmersionDay"
  sku       = "Windows11EnterpriseMultiSession"
}

// Network Configs
network_config = {
  name                    = "vnet-msftlabs-cus-immersionday"
  address_space           = "10.42.0.0/22"
  avd_subnet_name         = "snet-avd"
  avd_subnet_cidr         = "10.42.1.0/24"
  image_build_subnet_name = "snet-runner-build"
  image_build_subnet_cidr = "10.42.2.0/26"
  bastion_subnet_cidr     = "10.42.0.0/26"
}

bastion_config = {
  name              = "msftlabs-cus-immersionday-bastion"
  sku               = "Standard"
  tunneling_enabled = true
}

// Self-hosted GitHub runner (also hosts Packer image builds inside the VNet)
runner_config = {
  name              = "msftlabs-runner"
  size              = "Standard_D2s_v5"
  admin_username    = "runneradmin"
  github_repository = "MSFTLabs/msftlabs-immersion-day"
}

// Lab User Configs
num_of_labusers = 5

// Lab Credential Vault Configs
key_vault_config = {
  name_prefix         = "kv-msftlabs-cus"
  staff_principal_ids = []
}

monitoring_config = {
  boot_storage_name_prefix = "stmsftcusboot"
  workspace_name           = "law-msftlabs-cus-immersionday"
  workspace_retention_days = 30
  workspace_daily_quota_gb = -1
}

// AVD Configs
avd_config = {
  host_pool_name            = "hp-msftlabs-cus-immersionday"
  workspace_name            = "ws-msftlabs-cus-immersionday"
  application_group_name    = "dag-msftlabs-cus-immersionday"
  desktop_display_name      = "Immersion Day Lab Desktop"
  session_host_name_prefix  = "lab-avd"
  session_host_size         = "Standard_D8s_v5"
  session_host_os_disk_type = "StandardSSD_LRS"
  maximum_sessions_per_host = 8
  load_balancer_type        = "BreadthFirst"
  admin_username            = "labadmin"
}

avd_session_host_count      = 2
avd_image_version           = "1.0.2"
avd_admin_password          = null
avd_registration_expiration = "2026-11-05T02:33:26Z"

