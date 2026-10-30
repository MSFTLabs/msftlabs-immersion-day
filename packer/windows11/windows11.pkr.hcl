packer {
  required_version = ">= 1.16.1, < 2.0.0"

  required_plugins {
    azure = {
      source  = "github.com/hashicorp/azure"
      version = ">= 2.6.5, < 3.0.0"
    }
  }
}

variable "subscription_id" {
  type = string
}

variable "tenant_id" {
  type = string
}

variable "location" {
  type = string
}

variable "gallery_resource_group" {
  type = string
}

variable "gallery_name" {
  type = string
}

variable "image_definition_name" {
  type = string
}

variable "image_version" {
  type = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.image_version))
    error_message = "Gallery image versions must be Major.Minor.Patch with numeric components."
  }
}

variable "image_sku" {
  type = string

  validation {
    condition     = can(regex("^win11-[0-9]{2}h[12]-avd$", var.image_sku))
    error_message = "Use a Windows 11 Enterprise multi-session SKU, not a single-session or preview SKU."
  }
}

variable "source_image_version" {
  type    = string
  default = "latest"
}

variable "replication_regions" {
  type    = list(string)
  default = []
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "vm_size" {
  type    = string
  default = "Standard_D4s_v5"
}

variable "virtual_network_name" {
  type = string
}

variable "virtual_network_resource_group_name" {
  type = string
}

variable "virtual_network_subnet_name" {
  type = string
}

variable "allowed_inbound_ip_addresses" {
  type    = list(string)
  default = []
}

locals {
  target_regions = distinct(concat([var.location], var.replication_regions))
}

source "azure-arm" "windows11" {
  # Authentication: the Azure CLI session (the runner's managed identity, or the setup script's service principal).
  use_azure_cli_auth = true
  subscription_id    = var.subscription_id
  tenant_id          = var.tenant_id

  # Build VM
  location                 = var.location
  vm_size                  = var.vm_size
  temp_resource_group_name = "pkr-immersionday-${substr(uuidv4(), 0, 8)}"
  polling_duration_timeout = "60m"
  license_type             = "Windows_Client"
  security_type            = "TrustedLaunch"
  secure_boot_enabled      = true
  vtpm_enabled             = true
  azure_tags               = merge(var.tags, { ManagedBy = "Packer", ImageVersion = var.image_version })

  # Source image: Windows 11 Enterprise multi-session (Marketplace)
  os_type         = "Windows"
  image_publisher = "MicrosoftWindowsDesktop"
  image_offer     = "windows-11"
  image_sku       = var.image_sku
  image_version   = var.source_image_version

  # Private build: the VM gets a private IP in the lab runner/build subnet and the in-VNet runner reaches WinRM directly.
  virtual_network_name                = var.virtual_network_name
  virtual_network_resource_group_name = var.virtual_network_resource_group_name
  virtual_network_subnet_name         = var.virtual_network_subnet_name

  # Only used for public-IP builds (no VNet values); an empty list leaves the temporary NSG rule open to any source.
  allowed_inbound_ip_addresses = var.allowed_inbound_ip_addresses

  # WinRM over HTTP 5985. The plugin's default Key Vault + HTTPS certificate is skipped; WinRM is enabled by a script that
  # runs on the VM at provisioning time (plugin example windows_skip_key_vault).
  communicator                = "winrm"
  winrm_username              = "packer"
  winrm_use_ssl               = false
  winrm_port                  = 5985
  winrm_timeout               = "30m"
  skip_create_build_key_vault = true
  user_data_file              = "${path.root}/scripts/Enable-WinRM.ps1"
  custom_script               = "powershell -ExecutionPolicy Unrestricted -NoProfile -NonInteractive -Command \"$userData = (Invoke-RestMethod -Headers @{Metadata=$true} -Method GET -Uri http://169.254.169.254/metadata/instance/compute/userData?api-version=2021-01-01$([char]38)format=text); $contents = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($userData)); set-content -path c:\\Windows\\Temp\\userdata.ps1 -value $contents; . c:\\Windows\\Temp\\userdata.ps1;\""

  # Output: Azure Compute Gallery image version
  shared_image_gallery_destination {
    subscription         = var.subscription_id
    resource_group       = var.gallery_resource_group
    gallery_name         = var.gallery_name
    image_name           = var.image_definition_name
    image_version        = var.image_version
    storage_account_type = "Standard_LRS"

    dynamic "target_region" {
      for_each = local.target_regions
      content {
        name = target_region.value
      }
    }
  }
  shared_image_gallery_timeout = "90m"
}

build {
  name    = "msftlabs-windows11"
  sources = ["source.azure-arm.windows11"]

  # Staged here and moved into Windows\Web\Wallpaper by Install-LabTools (the file provisioner needs a writable destination).
  provisioner "file" {
    source      = "${path.root}/scripts/host_bg.png"
    destination = "C:/Windows/Temp/host_bg.png"
  }

  provisioner "powershell" {
    script  = "${path.root}/scripts/Install-LabTools.ps1"
    timeout = "45m"
  }

  provisioner "powershell" {
    inline = ["New-Item -ItemType Directory -Path C:\\labs -Force | Out-Null"]
  }

  # The trailing slash uploads the contents of labs/ into C:\labs (file provisioner docs).
  provisioner "file" {
    source      = "${path.root}/../../labs/"
    destination = "C:/labs"
  }

  provisioner "powershell" {
    script  = "${path.root}/scripts/Test-LabImage.ps1"
    timeout = "10m"
  }

  # Sysprep must be the last provisioner.
  provisioner "powershell" {
    script  = "${path.root}/scripts/Generalize-LabImage.ps1"
    timeout = "45m"
  }

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
    custom_data = {
      image_version        = var.image_version
      source_image_sku     = var.image_sku
      source_image_version = var.source_image_version
    }
  }
}
