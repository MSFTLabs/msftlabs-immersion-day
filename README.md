# MSFTLabs Immersion Day

Deploy from GitHub Codespaces or a local VS Code Dev Container using Bash or PowerShell 7. Run commands from the repository root. Deployment and image builds incur Azure charges.

## Local Environment

1. In GitHub, select **Code > Codespaces > Create codespace**, or open the cloned repository in VS Code and select **Dev Containers: Reopen in Container** (requires Docker and the Dev Containers extension).
2. Wait for container setup to install Azure CLI, OpenTofu, Packer, PowerShell 7 and `jq`.
3. Open a Bash or PowerShell 7 terminal and verify the tools:

```text
az version
tofu version
packer version
pwsh --version
```

Use the same checkout and OpenTofu state throughout. For an existing deployment, restore its state securely before applying; do not start with empty state. State and saved plans contain secrets and must not be committed or lost when deleting a Codespace.

### Set MYIP

Restrict access to the temporary Packer VM to the container's public outbound IPv4 address.

**Bash:**

```bash
export MYIP="$(curl -4 --fail --silent --show-error https://api.ipify.org)"
export PKR_VAR_allowed_inbound_ip_addresses="[\"${MYIP}/32\"]"
printf 'Build access: %s/32\n' "$MYIP"
```

**PowerShell 7:**

```powershell
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$env:MYIP = (curl -4 --fail --silent --show-error https://api.ipify.org).Trim()
$env:PKR_VAR_allowed_inbound_ip_addresses = '["' + $env:MYIP + '/32"]'
Write-Host "Build access: $env:MYIP/32"
```

Recalculate these variables if the outbound IP changes. Keep them in the terminal where you run Packer.

### Log In with the Service Principal

Supply `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`, `ARM_TENANT_ID` and `ARM_SUBSCRIPTION_ID` through Codespaces secrets or your approved local environment/secret manager. Never put the client secret in tracked files. The SPN must already have Azure resource/RBAC permissions, required Microsoft Graph application permissions with admin consent for lab users/TAPs, and registered Azure resource providers.

**Bash:**

```bash
az login --service-principal \
  --username "$ARM_CLIENT_ID" \
  --password "$ARM_CLIENT_SECRET" \
  --tenant "$ARM_TENANT_ID" --output none
az account set --subscription "$ARM_SUBSCRIPTION_ID"
az account show --query '{subscription:id,tenant:tenantId,identity:user.name}' --output table
```

**PowerShell 7:**

```powershell
az login --service-principal --username $env:ARM_CLIENT_ID --password $env:ARM_CLIENT_SECRET --tenant $env:ARM_TENANT_ID --output none
az account set --subscription $env:ARM_SUBSCRIPTION_ID
az account show --query '{subscription:id,tenant:tenantId,identity:user.name}' --output table
```

## Phase 1: Deploy the Foundation with OpenTofu

Edit [infra/terraform.tfvars](infra/terraform.tfvars) for your tenant, subscription, region and resource names. For a new lab, start with:

```hcl
num_of_labusers             = 0
avd_session_host_count      = 0
avd_image_version           = null
avd_admin_password          = null
avd_registration_expiration = null
```

**Both shells:**

```text
tofu -chdir=infra init
tofu -chdir=infra validate
tofu -chdir=infra plan -out=foundation.tfplan
```

Review the plan, then apply:

```text
tofu -chdir=infra apply foundation.tfplan
tofu -chdir=infra output packer_configuration
```

This creates the shared infrastructure, including the gallery and AVD control plane, without lab users or session-host VMs. Do not reset user/host counts to zero on a populated lab.

## Phase 2: Build the Image with Packer

Edit [packer/build.pkrvars.json](packer/build.pkrvars.json): match the subscription, tenant, location, gallery resource group, gallery name and image definition to the Phase 1 `packer_configuration` output. Choose a new numeric `image_version`, such as `1.0.4`; existing versions cannot be overwritten.

For this direct local build, leave `virtual_network_name`, `virtual_network_resource_group_name` and `virtual_network_subnet_name` as empty strings. Packer creates a temporary public-IP VM and restricts inbound access using `PKR_VAR_allowed_inbound_ip_addresses` from the `MYIP` step. Do not leave that environment variable unset: the template defaults to unrestricted access. The container needs outbound WinRM TCP 5985 connectivity; this path uses HTTP, so use only an approved lab environment. Setting the VNet fields instead selects a private build and requires private network connectivity from the container.

**Both shells:**

```text
packer init packer/windows11
packer validate -var-file=packer/build.pkrvars.json packer/windows11
packer build -var-file=packer/build.pkrvars.json packer/windows11
```

Wait for successful build and gallery publication before Phase 3. Packer uses your Azure CLI SPN session. No workflow dispatch or runner registration is needed for these commands.

## Phase 3: Deploy AVD with OpenTofu

Update [infra/terraform.tfvars](infra/terraform.tfvars) with the desired user/host counts and the exact image version published in Phase 2:

```hcl
num_of_labusers        = 5
avd_session_host_count = 2
avd_image_version      = "1.0.4"
```

Remove `avd_admin_password = null` from that file so the password environment variable below takes effect. Enter a 12-123 character Windows-compliant password when prompted. These commands generate a fresh registration expiry and override the tfvars timestamp. Run Phase 3 shortly before onboarding: lab-user TAPs expire after eight hours.

**Bash: plan with the password held in the process environment:**

```bash
read -r -s -p 'Session-host administrator password: ' TF_VAR_avd_admin_password
printf '\n'
export TF_VAR_avd_admin_password
registration_expiry=$(date -u -d '+7 days' '+%Y-%m-%dT%H:%M:%SZ')
tofu -chdir=infra plan \
  -var="avd_registration_expiration=$registration_expiry" \
  -out=avd.tfplan
unset TF_VAR_avd_admin_password
```

**PowerShell 7: plan with the password held in the process environment:**

```powershell
$password = Read-Host 'Session-host administrator password' -AsSecureString
try {
    $env:TF_VAR_avd_admin_password = [System.Net.NetworkCredential]::new('', $password).Password
    $registrationExpiry = [DateTimeOffset]::UtcNow.AddDays(7).ToString('yyyy-MM-ddTHH:mm:ssZ')
    tofu -chdir=infra plan -var="avd_registration_expiration=$registrationExpiry" -out=avd.tfplan
} finally {
    Remove-Item Env:TF_VAR_avd_admin_password -ErrorAction SilentlyContinue
    $password.Dispose()
}
```

Only after a successful plan, review it and apply. A saved plan contains the password and does not prompt again.

**Both shells:**

```text
tofu -chdir=infra apply avd.tfplan
tofu -chdir=infra output avd_configuration
tofu -chdir=infra output -raw lab_users_csv_path
```

Allow registration to finish and confirm the hosts are `Available` in the AVD host pool before distributing credentials. Keep the staff CSV private: it contains plaintext passwords and TAPs. Delete saved plans after use, retain state securely, and supply the same administrator password and a fresh expiry for later plans.