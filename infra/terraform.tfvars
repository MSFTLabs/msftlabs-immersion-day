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

// Lab User Configs
num_of_labusers = 5

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
avd_image_version           = "1.0.3"
avd_admin_password          = null
avd_registration_expiration = "2026-11-05T02:33:26Z"

