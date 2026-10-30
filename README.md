# MSFTLabs Immersion Day

Organizer-managed Azure lab infrastructure built with OpenTofu, PowerShell 7, Azure CLI and Packer. Students connect to pooled Windows 11 Enterprise multi-session desktops through Azure Virtual Desktop (AVD), then use the Azure Portal and preinstalled tools to complete the workshop.

This repository is an executable OpenTofu root, not a reusable child module. Run the commands below from the repository root on the organizer's Windows workstation. Deployment and image builds incur Azure charges. As of 2026-10-28 the shared foundation, the in-VNet image-build runner, image version 1.0.0, five lab users and two AVD session hosts are deployed in Central US; see [Current deployment state](#current-deployment-state) for exactly what has and has not been verified.

## Contents

- [Current deployment state](#current-deployment-state)
- [How the lab works](#how-the-lab-works)
- [Prerequisites](#prerequisites)
- [Deploy with PowerShell 7](#deploy-with-powershell-7)
- [Inputs](#inputs)
- [Image-build parameters](#image-build-parameters)
- [Outputs](#outputs)
- [Credentials and onboarding](#credentials-and-onboarding)
- [Operations notes](#operations-notes)
- [Cleanup](#cleanup)
- [Repository layout](#repository-layout)
- [References](#references)

## Current Deployment State

Verified against Azure on 2026-10-28. Items marked not verified were built but never exercised end to end.

| Component | State |
| --- | --- |
| Shared foundation (network, Bastion, NAT, gallery, AVD control plane, vault, monitoring) | Deployed in Central US, subscription `msftlabs-misc-demos`. A final plan shows no changes. |
| Image-build runner `msftlabs-runner` | Ubuntu 24.04 at 10.42.2.4 in `snet-runner-build` (no public IP), online in GitHub with labels `self-hosted, linux, msftlabs-image`. |
| Image `win11-immersionday-lab` version `1.0.0` | Published and replicated to Central US, West US 3 and West US 2 (later builds replicate to Central US only). Built in about 30 minutes from `win11-26h2-avd`; Sysprep reached `IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE`. |
| Lab users | `num_of_labusers = 5` (`LabUser001`-`LabUser005`) with per-user resource groups and the staff CSV. TAPs are reusable and expire after eight hours, so renew them before the event. |
| AVD hosts | `lab-avd-001` and `lab-avd-002` (`Standard_D8s_v5`, image 1.0.0) are `Available` with every health check passing. No scaling plan is deployed, so the hosts stay powered on. |
| Host registration token | Expires `2026-11-05T02:33:26Z`; renew `avd_registration_expiration` before any later plan that keeps hosts. |
| Host administrator password | Generated and stored in the lab Key Vault as `avd-local-admin-password`. |
| Not verified | A student signing in and opening a desktop, the Chocolatey-based image build (Install-LabTools, Oh My Posh, Markdone, the Windows Terminal fragment and `C:\labs`), and the GitHub workflow `.github/workflows/build-image.yml` (not pushed). |

## How the Lab Works

1. OpenTofu creates the shared lab resource group, Compute Gallery/image definition, networking (including a dedicated runner and build subnet), the self-hosted image-build runner VM, AVD control plane, credential vault, boot-diagnostics storage and central Log Analytics workspace. Session-host count stays at zero until an image version exists.
2. The organizer registers the runner (`-Stage Runner`) and then explicitly runs the image stage. Packer runs on that runner, builds a generalized Windows 11 Enterprise multi-session image in the lab subnet, installs the tools and publishes a numbered version to the gallery.
3. The organizer selects that image version and increases the session-host count. OpenTofu creates private Windows VMs, joins them to Microsoft Entra ID and registers them with the pooled host pool through the registration extension.
4. A positive lab-user count creates numbered Entra accounts, their AVD security group and one dedicated exercise resource group per account (`LAB-LabUser001`, etc.). Each user receives Owner on their own exercise group. The security group automatically receives desktop access and VM-login permissions; no manual AVD principal list is required.
5. The credential publisher issues reusable, eight-hour Temporary Access Passes (TAPs), stores initial credentials in Key Vault and exports the staff CSV. Students complete browser onboarding, then connect to their assigned desktop.

All Azure infrastructure in this root uses one configured subscription and region. Shared desktop infrastructure uses the configured shared resource group; student exercises use separate per-user resource groups. Additional replication regions copy the image; they do not deploy additional AVD environments. OpenTofu owns the shared infrastructure, student resource groups, accounts and access assignments. Packer owns image versions and its temporary build resources.

The workshop covers networking, storage, an Ubuntu/Nginx status-page VM and monitoring. This root supplies the desktop environment, student exercise scopes and shared operational monitoring, not the exercise workloads. It does **not** deploy the status page/student storage/load balancer, student Log Analytics workspaces, Grafana or SRE Agent. Students create those resources inside their own exercise group during the workshop.

### Shared Infrastructure and Monitoring

The core resource group is represented by `azurerm_resource_group.shared`, rather than the historical image-only label. Its Azure name remains `resource_group_name`; the included `moved` block migrates the old OpenTofu address without replacing the group or its contents.

| Telemetry source | Destination and collection |
| --- | --- |
| AVD session-host VMs | Serial boot logs and screenshots in the shared custom boot-diagnostics storage account. |
| Azure Bastion | All supported resource log categories, including audit activity, in Log Analytics. |
| AVD and image-build subnet NSGs | All supported resource log categories, including `NetworkSecurityGroupEvent` and `NetworkSecurityGroupRuleCounter`, in Log Analytics. |
| AVD host pool, desktop application group and workspace | All supported diagnostic log categories in Log Analytics, using dedicated resource-specific tables such as `WVDConnections` and `WVDErrors`. |
| Supported platform metrics on the diagnostic targets | All metric categories returned by Azure's diagnostic-category discovery, exported to the same workspace where supported. |

The diagnostic settings discover categories separately for each resource during an authorized plan/apply instead of assuming the same categories exist everywhere. Logs begin after diagnostic settings are enabled, and ingestion/availability may take time. Bastion and NSG logs use their service-default Log Analytics table mode. NSG events/counters are not packet/IP traffic flow logs; no Network Watcher flow logs or Traffic Analytics are provisioned here. Windows guest event logs, performance counters and AVD Insights guest collection require a separate Azure Monitor Agent/data collection rule setup, which this slice does not install.

The boot account is Standard LRS/StorageV2 in the same subscription and region as session-host VMs; premium and zone-redundant storage are not supported for boot diagnostics. HTTPS/TLS 1.2 is enforced and anonymous blob access is disabled. Its public endpoint remains enabled, while Shared Key authorization and local users are disabled to match what governance enforces on the account (the CLI cannot read boot logs while Shared Key is off); do not distribute account keys or grant student access. Boot blobs are not automatically ingested into Log Analytics, and there is no configured automatic blob expiry. Packer temporary VMs and student-created VMs are not automatically attached to this account.

The shared workspace uses `PerGB2018`, Entra authorization and workspace-scoped query permissions, with public ingestion/query endpoints. Students receive no shared workspace role through this code. Workspace retention and daily quota are configurable; the initial `-1` quota is uncapped to avoid interrupting event logs. A positive cap can stop ingestion after it is reached and is not a guaranteed spending ceiling. Storage, ingestion and retention charges apply. Protect state/backups because providers retain storage/workspace keys even though no keys are exposed in the new outputs.

### Student Resource Groups

For each generated account, OpenTofu creates `LAB-<LabUser name>` in the configured subscription and region, with the shared lab tags plus a `LabUser` tag. For example, `LabUser001` owns `LAB-LabUser001`. Owner is assigned directly to the corresponding user object ID at that resource-group scope, not to the student security group or at subscription scope. Owner permits resource management and RBAC delegation within that group; it does not bypass Azure Policy or automatically grant service data-plane roles.

`num_of_labusers` controls the accounts, exercise groups and Owner assignments together; no additional input is required. Zero users creates no student groups, and reducing the count schedules the corresponding accounts, resource groups and assignments for deletion. Names are subscription-wide: existing groups with the same names require deliberate resolution/import. Clean up student-created resources before removing their groups because the provider's non-empty-resource-group deletion guard remains enabled.

### Desktop Image

The image contains machine-wide PowerShell 7, Azure CLI, Bicep, Git and Visual Studio Code (with built-in Markdown preview) installed with Chocolatey, plus the pinned Markdone zip (unsigned, so verified by SHA256 only), the pinned standalone Oh My Posh binary (the Chocolatey package is a per-user MSIX that Sysprep rejects) and the Meslo Nerd Font registered machine-wide, which opens `C:\labs\LabGuideExample.md` at every user logon through a machine-wide `Run` registry value (`markview.exe` under `C:\Program Files\MarkView`, from the MSI's INSTALLDIR). Oh My Posh starts from the all-users PowerShell 7 profile, and a Windows Terminal fragment sets the font for the PowerShell profile. The repository's `labs/` folder is uploaded to `C:\labs`. The WinGet CLI is not used in the build: Microsoft documents it as unsupported in the system context and it needs App Installer registered for the user.

The installer resolves current stable tool releases at build time. The source is the latest regional stable Windows 11 multi-session Marketplace SKU unless explicitly selected. No lab credentials, Entra join, host-pool registration or registration token is baked into the generalized image.

## Prerequisites

### Workstation and Versions

Install every required tool with [WinGet](https://learn.microsoft.com/windows/package-manager/winget/), the Windows Package Manager, and make `pwsh`, `az`, `tofu`, `packer` and `gh` available on PATH. Do not install these tools with Chocolatey, Scoop, manual downloads or other package managers, so that every organizer workstation gets the same publisher-signed packages and upgrades the same way. Use PowerShell 7.4 or later in the 7.x family for the [native-command error handling](https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_preference_variables#psnativecommanduseerroractionpreference) shown below; the repository scripts declare PowerShell 7.0 as their minimum. Azure PowerShell (`Az` module) is not required.

#### Install the Tools with WinGet

| Tool | WinGet package ID | Repository requirement |
| --- | --- | --- |
| PowerShell 7 | `Microsoft.PowerShell` | 7.4 or later (7.0 minimum for the scripts) |
| Azure CLI | `Microsoft.AzureCLI` | Current stable release |
| OpenTofu | `OpenTofu.Tofu` | `>= 1.13.1, < 2.0.0` |
| Packer | `Hashicorp.Packer` | `>= 1.16.1` |
| GitHub CLI | `GitHub.cli` | Current stable release; signed in with admin rights on the repository for the Runner stage |

Run these in a PowerShell terminal. The Azure CLI and PowerShell installers may show an elevation prompt; accept it from a normal user session rather than running the whole terminal as administrator.

```powershell
winget install --id Microsoft.PowerShell --exact --source winget
winget install --id Microsoft.AzureCLI --exact --source winget
winget install --id OpenTofu.Tofu --exact --source winget
winget install --id Hashicorp.Packer --exact --source winget
winget install --id GitHub.cli --exact --source winget
```

Open a new terminal afterward so the updated PATH is loaded, then confirm the versions meet the table above.

```powershell
pwsh --version
az version --output table
tofu version
packer version
gh --version
```

Check for newer versions and upgrade with WinGet only, using the same package IDs. Stay inside the repository's version ranges, and recheck the table above before moving to a new major release.

```powershell
winget upgrade --id OpenTofu.Tofu --exact --source winget
winget upgrade --id Hashicorp.Packer --exact --source winget
winget upgrade --id Microsoft.AzureCLI --exact --source winget
winget upgrade --id Microsoft.PowerShell --exact --source winget
```

**Duplicate installs:** a second copy of `tofu` or `packer` from another package manager can shadow the WinGet one. The machine PATH is searched before the user PATH, so an older Chocolatey copy in `C:\ProgramData\chocolatey\bin` wins over a WinGet copy even when both are installed. List every copy with `Get-Command tofu, packer -All | Select-Object Name, Version, Source`, and remove the non-WinGet copy with that tool's own uninstall command (an elevated terminal is required for machine-wide installs).

| Dependency               | Repository requirement or pin                     | Publisher documentation                                                                                                                                                                                       |
| ------------------------ | ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| OpenTofu CLI             | `>= 1.13.1, < 2.0.0`                            | [OpenTofu releases](https://github.com/opentofu/opentofu/releases)                                                                                                                                             |
| Packer CLI               | `>= 1.16.1`                                     | [Packer releases](https://github.com/hashicorp/packer/releases)                                                                                                                                                |
| AzureRM provider         | `5.9.0`                                         | [AzureRM releases](https://github.com/hashicorp/terraform-provider-azurerm/releases)                                                                                                                           |
| AzureAD provider         | `3.10.0`                                        | [AzureAD releases](https://github.com/hashicorp/terraform-provider-azuread/releases)                                                                                                                           |
| Random provider          | `3.9.1`                                         | [Random releases](https://github.com/hashicorp/terraform-provider-random/releases)                                                                                                                             |
| Microsoft Graph provider | `0.6.0`                                         | [Microsoft Graph releases](https://github.com/microsoft/terraform-provider-msgraph/releases)                                                                                                                   |
| PowerShell 7 / Azure CLI | Current stable releases compatible with the above | [PowerShell installation](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows), [Azure CLI installation](https://learn.microsoft.com/cli/azure/install-azure-cli-windows) |

These are repository requirements/pins, not a promise that each pin remains the newest release. Recheck the linked publisher releases before updating them or preparing another event. Keep the generated provider lock file under source control; never commit state or saved plans.

### Azure and Entra Permissions

Use an approved organizer identity in the configured tenant and subscription. Azure resource permissions and Entra directory permissions are separate.

| Operation                              | Required permission/capability                                                                                                                                                                                |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Create shared Azure resources and RBAC | Resource creation/deletion plus role-assignment write permissions at the applicable scopes. Subscription Owner is one broad option; an approved scoped/custom-role combination is preferable where practical. |
| Create users and group membership      | Entra User Administrator or equivalent approved user/group-management permissions. Subscription Owner does not grant these.                                                                                   |
| Configure TAP eligibility              | Authentication Policy Administrator and the required Microsoft Graph authorization/consent.                                                                                                                   |
| Issue TAPs to ordinary lab users       | Authentication Administrator and the required Graph authorization/consent. Privileged users require Privileged Authentication Administrator.                                                                  |
| Publish/read credential secrets        | Key Vault Secrets Officer is assigned to the applying AzureRM identity by this root; allow time for RBAC propagation.                                                                                         |
| Build the image | Performed by the runner VM's system-assigned managed identity (Contributor on the subscription, created by this root): gallery image-version write, temporary resource group/VM creation and deletion, and joining the build subnet. The organizer running the Image stage needs the GitHub CLI signed in with rights to dispatch workflows on the repository. No certificate Key Vault is created by the image workflow. |

Azure CLI login alone does not grant missing Graph scopes or consent. The providers and credential helper must use an identity authorized for both directory operations and Azure resources. Arrange required consent and any role activation with the tenant administrators before applying. [Setting Up Lab Tenant](#setting-up-lab-tenant) lists the exact permissions the service principal needs and the Azure CLI commands that grant them.

### Setting Up Lab Tenant

A positive `num_of_labusers` makes the `azuread` and `msgraph` providers call Microsoft Graph to read domains, create users and groups, and read/update the Temporary Access Pass (TAP) policy. The credential publisher also calls Graph to issue TAPs. Run these steps once per tenant as a Global Administrator or Privileged Role Administrator, before setting `num_of_labusers` above zero.

**Why a local `az login` can still fail with 403:** the `azuread`, `msgraph` and `azurerm` providers prefer the `ARM_CLIENT_ID`/`ARM_CLIENT_SECRET` environment variables over `use_cli = true`. If those variables exist, including at User scope, the providers sign in as that service principal and ignore your Azure CLI session, even if you are a Global Administrator. Check with `Get-ChildItem Env:ARM_*` and `[Environment]::GetEnvironmentVariable('ARM_CLIENT_ID', 'User')`. Separately, the Azure CLI's own Graph token has no `Policy.Read.All`, `Policy.ReadWrite.AuthenticationMethod` or `UserAuthenticationMethod.ReadWrite.All` scope, so the TAP policy read and TAP creation return 403 under any CLI-only identity. Adding the scopes with `az login --scope` is not possible: Microsoft first-party apps cannot be consented to Graph this way and the sign-in fails with `AADSTS65002`. Use a service principal with the application permissions below.

| Graph application permission | Used for |
| --- | --- |
| `User.ReadWrite.All` | Create lab users (`azuread_user`) |
| `Group.ReadWrite.All` | Create the lab group and memberships |
| `Domain.Read.All` | Read the tenant default domain (`azuread_domains`) |
| `Application.Read.All` | Not used by the current configuration; kept in case a later change needs to look up applications or service principals |
| `Policy.Read.All` | Read the TAP policy (`msgraph_resource` data source) |
| `Policy.ReadWrite.AuthenticationMethod` | Enable TAP for the lab group (`msgraph_resource_action`) |
| `UserAuthenticationMethod.ReadWrite.All` | Issue TAPs (credential publisher) |

Grant the permissions to the existing `ARM_CLIENT_ID` service principal and give admin consent. The role IDs below are the Microsoft Graph application role IDs in the public cloud; confirm them with `az ad sp show --id 00000003-0000-0000-c000-000000000000 --query "appRoles[].{value:value,id:id}"` if consent fails.

```powershell
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$GraphAppId = '00000003-0000-0000-c000-000000000000'
$AppId = $env:ARM_CLIENT_ID

$GraphRoles = @(
    '741f803b-c850-494e-b5df-cde7c675a1ca' # User.ReadWrite.All
    '62a82d76-70ea-41e2-9197-370581804d09' # Group.ReadWrite.All
    'dbb9058a-0e50-45d7-ae91-66909b5d4664' # Domain.Read.All
    '9a5d68dd-52b0-4cc2-bd40-abcf44ac3a30' # Application.Read.All
    '246dd0d5-5bd0-4def-940b-0421030a5b68' # Policy.Read.All
    '29c18626-4985-4dcd-85c0-193eef327366' # Policy.ReadWrite.AuthenticationMethod
    '50483e42-d915-4231-9639-7fdb7fd190e5' # UserAuthenticationMethod.ReadWrite.All
)

az ad app permission add --id $AppId --api $GraphAppId --api-permissions ($GraphRoles | ForEach-Object { "$_=Role" })
az ad app permission admin-consent --id $AppId
```

Verify the assignments after a minute or two; the output should list all seven role IDs. Admin consent can lag or silently skip a role; if one is still missing (this happened with `Application.Read.All`, which made the Phase 2 plan fail with a 403 on the AVD service-principal lookup), create the assignment directly: `az rest --method POST --url "https://graph.microsoft.com/v1.0/servicePrincipals/$SpObjectId/appRoleAssignments" --body '{"principalId":"<spObjectId>","resourceId":"<graphSpObjectId>","appRoleId":"<roleId>"}'`.

```powershell
$SpObjectId = az ad sp show --id $AppId --query id --output tsv
az rest --method GET --url "https://graph.microsoft.com/v1.0/servicePrincipals/$SpObjectId/appRoleAssignments" --query "value[].appRoleId" --output tsv
```

The credential publisher gets its Graph token from `az account get-access-token`. Before applying a positive `num_of_labusers`, sign Azure CLI in as the same service principal so that token carries these application roles, then run the apply from that session. Do not commit or echo the secret.

```powershell
az login --service-principal --username $env:ARM_CLIENT_ID --password $env:ARM_CLIENT_SECRET --tenant $env:ARM_TENANT_ID
az account set --subscription $env:ARM_SUBSCRIPTION_ID
```

These permissions let the service principal create and modify users, groups and authentication methods across the tenant. Use a dedicated lab tenant or subscription, protect the client secret, and revoke the consent after the event by deleting the Graph app-role assignments, then removing the requested permissions.

```powershell
$Assignments = az rest --method GET --url "https://graph.microsoft.com/v1.0/servicePrincipals/$SpObjectId/appRoleAssignments" --query "value[?resourceDisplayName=='Microsoft Graph'].id" --output tsv
foreach ($AssignmentId in $Assignments) {
    az rest --method DELETE --url "https://graph.microsoft.com/v1.0/servicePrincipals/$SpObjectId/appRoleAssignments/$AssignmentId"
}
az ad app permission delete --id $AppId --api $GraphAppId
```

#### Azure RBAC for the service principal

The same service principal also applies the Azure resources, so it needs Azure RBAC on the lab subscription in addition to the Graph permissions above.

| Azure requirement | Why |
| --- | --- |
| `Owner` on the subscription (or a management group above it) | Creates the shared and per-user resource groups and all lab resources, and writes the role assignments in this root: `Owner` on each `LAB-<LabUser>` group, `Desktop Virtualization User` and `Virtual Machine User Login` for the lab group, and `Key Vault Secrets Officer` on the credential vault for itself. |
| Scoped alternative: `Contributor` plus `Role Based Access Control Administrator` on the subscription | Contributor cannot create role assignments, so the second role is required; use it instead of Owner where the tenant restricts Owner. |
| `Key Vault Secrets Officer` on the credential vault | Assigned to the applying identity by this root, not granted manually. The credential publisher uses it to write the per-user secrets, so allow time for RBAC propagation after the first apply. |
| Registered resource providers | AzureRM automatic registration is disabled; see the provider list below. |

```powershell
$SubscriptionScope = "/subscriptions/$env:ARM_SUBSCRIPTION_ID"

az role assignment create --assignee-object-id $SpObjectId --assignee-principal-type ServicePrincipal --role 'Owner' --scope $SubscriptionScope

# Scoped alternative to Owner
az role assignment create --assignee-object-id $SpObjectId --assignee-principal-type ServicePrincipal --role 'Contributor' --scope $SubscriptionScope
az role assignment create --assignee-object-id $SpObjectId --assignee-principal-type ServicePrincipal --role 'Role Based Access Control Administrator' --scope $SubscriptionScope
```

Verify the effective Azure roles, including inherited ones.

```powershell
az role assignment list --all --assignee $AppId --include-inherited --query "[].{role:roleDefinitionName,scope:scope}" --output table
```

The Azure CLI session used for the OpenTofu applies and publisher scripts must run as an identity with the same Azure roles. Signing in as this service principal, as shown above, satisfies both. The image build itself runs on the runner VM and uses the runner's own managed identity instead, so the organizer's identity is not involved in the build.

Confirm AVD/Windows licensing, Entra SSO and Conditional Access requirements, regional VM availability/quota, and Internet access to Azure, Graph, Key Vault, AVD and publisher download endpoints. Image builds run on a self-hosted GitHub runner VM inside the lab VNet (subnet `snet-runner-build`, no public IP). Packer builds the Windows VM in that same subnet with a private IP and connects to it over WinRM HTTP port 5985, which never leaves the VNet; the subnet NSG allows 5985/5986 only from the subnet itself and SSH/RDP only from the Bastion subnet. The runner signs in to Azure with its system-assigned managed identity (Contributor on the subscription so Packer can create its temporary resource group). No workstation inbound rule, public IP, Key Vault or WinRM certificate is involved (`skip_create_build_key_vault`). The runner admin password is stored in the lab Key Vault as `runner-admin-password`; connect with Azure Bastion.

Ensure the required resource providers, including `Microsoft.Compute`, `Microsoft.Network`, `Microsoft.KeyVault`, `Microsoft.DesktopVirtualization`, `Microsoft.Storage`, `Microsoft.OperationalInsights` and `Microsoft.Insights`, are registered. AzureRM automatic provider registration is disabled. The organizer also needs workspace/storage creation and diagnostic-setting write permissions. Confirm policy permits the configured public endpoints, resource types, regions and sizes. The fixed `SecurityControl = "Ignore"` tag is an organizer-confirmed, MCAPS-subscription-specific approved lab exception, not a general policy workaround for other tenants.

## Deploy with PowerShell 7

### Guided Setup with Setup-LabEnvironment.ps1

[scripts/Setup-LabEnvironment.ps1](scripts/Setup-LabEnvironment.ps1) is the only script in `scripts/`. It walks an organizer through the whole deployment so they do not need to know the OpenTofu or Packer commands. It is a PowerShell 7 wrapper around Azure CLI that prepares the identities, runs the image-build preflight checks, and then calls OpenTofu and Packer. OpenTofu and Packer remain the source of truth for what gets deployed. Scripts those tools run live beside them: [packer/windows11/scripts/](packer/windows11/scripts) (the WinRM bootstrap and the in-guest tool install, test and Sysprep scripts) and [infra/scripts/](infra/scripts) (the credential publisher, CSV exporter and host-registration template).

```powershell
pwsh ./scripts/Setup-LabEnvironment.ps1
```

**Permissions the signed-in user needs.** The script signs in as you with `az login` for the first stage only, and checks these before changing anything. PIM-eligible roles are not detected, so activate them first.

| Scope | Required role | Why |
| --- | --- | --- |
| Microsoft Entra | Global Administrator, or Privileged Role Administrator plus Application Administrator (or Cloud Application Administrator) | Create the app registration and service principal, create its client secret, and grant and consent the Graph application roles |
| Azure subscription | Owner, or Contributor plus User Access Administrator (or Role Based Access Control Administrator) | Assign Owner to the service principal on the subscription and register the resource providers |
| Workstation | PowerShell 7.0+, Azure CLI, OpenTofu and Packer on PATH, plus Internet access to Azure and Graph | Install all four with WinGet as described in [Install the Tools with WinGet](#install-the-tools-with-winget); the setup script stops with an error if one is missing or too old |

**Stages.** Run all of them, or resume one with `-Stage ServicePrincipal`, `Phase1`, `Runner`, `Image` or `Phase2`. Each stage prints progress, asks before anything billable is applied, and on an error offers to retry that step or abort.

| Stage | What it does |
| --- | --- |
| `ServicePrincipal` | Signs you in, checks your permissions, creates or reuses the service principal (default `sp-msftlabs-immersion-day`, override with `-ServicePrincipalName`), creates a client secret, assigns Azure Owner on the subscription, grants the seven Graph application roles, registers the required resource providers, then signs in as the service principal and confirms its Graph token carries every role. |
| `Phase1` | Runs `tofu init`, then `tofu plan -out=labbuild.plan` to validate the whole configuration. If `terraform.tfvars` is not filled out (for example zero lab users) it prompts for the resource group, region, owner and lab-user count. It then applies only the core infrastructure with lab users and hosts deferred, so one-time passes do not expire during the image build. |
| `Runner` | Waits for the runner VM's cloud-init to finish installing Azure CLI, OpenTofu, Packer, Git, GitHub CLI and PowerShell, registers it with the repository using a short-lived token from `gh` (needs repository admin; the token never enters OpenTofu state), and sets the non-secret repository variables used by `.github/workflows/build-image.yml`. |
| `Image` | Checks the build prerequisites (Azure context, VM size and quota, a Generation 2 multi-session source image, runner online), validates the template locally, then requires `packer/`, `labs/` and `.github/` to be committed and pushed. After you confirm the paid build it dispatches the `build-image.yml` workflow, which the runner executes (`packer init`, `validate`, `build`), follows the run and writes its log to `.logs/setup.log`. It offers to reuse an already published version instead. |
| `Phase2` | Sizes the hosts from the lab-user count, asks for the host administrator password (or generates one and stores it in the lab Key Vault), records the host count, image version and a 7-day registration expiry in `terraform.tfvars`, then plans and applies users, TAPs, credentials, and hosts. Needs the seven Graph roles (including `Application.Read.All`) on the service principal. Hosts register themselves through the registration extension; see [Operations notes](#operations-notes) for the recovery steps when a host is replaced. |

**Host sizing.** Maximum hosts is the lab-user count divided by 4, rounded up. OpenTofu creates the maximum number of hosts and no scaling plan is deployed, so every host stays powered on until the lab is torn down.

**Secrets and cleanup.** The service principal secret is held in the script's process environment. After the first stage the script asks whether to also store `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`, `ARM_TENANT_ID` and `ARM_SUBSCRIPTION_ID` in your user environment for manual OpenTofu runs; that storage is unencrypted in your profile, so decline it on shared workstations. Rerunning the stage reuses a working stored secret or appends a new one; remove old secrets from the app registration when they are no longer needed. OpenTofu and Packer run as the service principal inside a temporary Azure CLI profile that is deleted when the script ends, so your own Azure CLI login is not changed. Saved plans (`labbuild.plan`, `labphase1.plan`, `labphase2.plan`) and the temporary host-password file are deleted on exit.

**Live log.** Everything the script prints, plus the live output of the tools it runs, is appended to `.logs/setup.log` at the repository root (git-ignored). Each line is a UTC timestamp, a tab, then the entry, so the file reads as a time series: `2026-10-28T11:04:56.123Z<TAB>[packer] ==> ...`. OpenTofu output is tagged `[tofu]` and Packer output `[packer]`, including `init`, `validate` and the full `build`; Azure CLI calls are tagged `[az]` with the command name and exit code only. Prompts and your answers are recorded, except password prompts. Secrets, client secrets and Azure CLI output are not logged, and OpenTofu masks sensitive values itself. Each run starts and ends with a `=== run start` and `=== run end` marker. Follow a running build from a second terminal with `Get-Content .logs/setup.log -Wait -Tail 20`.

**Destroy.** `./scripts/Setup-LabEnvironment.ps1 -Destroy` tears the lab down and runs no other stage. It signs in as the service principal, runs `tofu init`, warns about student resource groups that still contain resources and any leftover temporary Packer groups, refreshes the stored path of the TAP-policy cleanup script, and previews the destroy plan. It then asks you to type the shared resource group name, offers to delete the Packer-published image versions (the gallery cannot be destroyed while they exist), and runs `tofu destroy`. Key Vault purge protection keeps the soft-deleted vault for 7 days. See [Cleanup](#cleanup) for the preconditions.

The manual commands below remain valid for organizers who prefer to run each tool directly.

The following commands are instructions for organizer execution; they are not run automatically. Use the same checkout, local state and organizer identity through every stage. Review plans before applying.

### 1. Configure and Authenticate

Edit [infra/terraform.tfvars](infra/terraform.tfvars) using the [input reference](#inputs). The checked-in values target the current event, not a generic environment. For initial image preparation, keep these values:

```hcl
avd_session_host_count      = 0
avd_image_version           = null
avd_admin_password          = null
avd_registration_expiration = null
```

**TAP timing:** phase 1 uses `num_of_labusers = 0`, which defers accounts, student resource groups, TAP policy changes and credential publication. Set the count to the desired event population, such as `100`, shortly before onboarding. A positive count creates users and issues TAPs even with zero hosts. Do not reduce the count to zero after users exist unless you intend to delete them and their exercise groups.

Open a PowerShell 7 terminal at the repository root. Set these identifiers to match the tfvars file; these shell values select CLI context and do not replace the OpenTofu inputs.

```powershell
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$TenantId = '477bacc4-4ada-4431-940b-b91cf6cb3fd4'
$SubscriptionId = '934600ac-0f19-44b8-b439-b4c5f02d8a7d'

az login --tenant $TenantId
az account set --subscription $SubscriptionId
az account show --query '{subscription:id,tenant:tenantId,state:state}' --output table
```

The image-build wrapper rejects a disabled subscription, a tenant/subscription mismatch or a cloud other than `AzureCloud`.

### 2. Deploy the Shared Infrastructure

```powershell
tofu -chdir=infra init
tofu -chdir=infra plan -out=foundation.tfplan
tofu -chdir=infra apply foundation.tfplan
tofu -chdir=infra output portal_url
```

This creates the gallery definition, networking, Bastion, NAT, AVD control plane and credential vault. If the user count is positive, it also creates users/group access and publishes credentials. This step also creates the runner VM, its subnet and NSG, and the role assignment for its managed identity. There are no session-host VMs until step 5.

If credential publication fails after new role assignments, resolve RBAC propagation, identity permissions or network reachability and retry the apply. Do not weaken vault access or tenant authentication policies. The publisher reuses matching saved credential records on retries.

### 3. Build and Publish the Image

Register the runner once, then choose a new numeric image version. The Runner stage waits for the runner's tool installation and registers it with GitHub; the Image stage checks the prerequisites and builds on the runner, prompting before the paid build starts:

```powershell
./scripts/Setup-LabEnvironment.ps1 -Stage Runner
./scripts/Setup-LabEnvironment.ps1 -Stage Image -ImageVersion 1.0.0
```

Both stages ask for confirmation interactively, so run them in a normal terminal. The build log is streamed into `.logs/setup.log` and also lives on the runner at `/opt/imagebuild/<version>/build.log`.

The Image stage reads `packer_configuration` from the current OpenTofu state, checks the active Azure context, regional source image and VM-size availability, vCPU quota and version uniqueness, then invokes Packer. The template [packer/windows11/windows11.pkr.hcl](packer/windows11/windows11.pkr.hcl) uses the HashiCorp `azure-arm` builder (plugin 2.6.5 or newer, installed by `packer init`) with the Windows 11 Enterprise multi-session Marketplace image, Trusted Launch, and publishes straight to the Azure Compute Gallery.

The build follows the documented Packer pattern: [Enable-WinRM.ps1](packer/windows11/scripts/Enable-WinRM.ps1) runs on the VM at provisioning time to open WinRM on 5985; then `powershell` provisioners run [Install-LabTools.ps1](packer/windows11/scripts/Install-LabTools.ps1) (Chocolatey packages, the pinned Markdone zip, the Meslo font, the all-users PowerShell profile and the Windows Terminal fragment, all as the `packer` user), a `file` provisioner uploads `labs/` to `C:\labs`, [Test-LabImage.ps1](packer/windows11/scripts/Test-LabImage.ps1) checks the result and finally [Generalize-LabImage.ps1](packer/windows11/scripts/Generalize-LabImage.ps1), which runs the documented `Sysprep.exe /oobe /generalize /quiet /quit /mode:vm` and waits for the generalized registry state. Sysprep runs last, as the Packer documentation requires.

The organizer-approved image preparation disables BitLocker on the disposable build VM's OS volume and waits up to 15 minutes for full decryption before Sysprep. The captured base image is BitLocker-free; Azure managed-disk encryption at rest, Secure Boot and vTPM remain enabled. This step does not change existing hosts or configure their BitLocker policy. The generalization provisioner is limited to 45 minutes.

Wait for image publication and replication to complete before using the version. Build files and the Packer manifest are stored under the ignored `artifacts/images/<version>` directory. Existing image versions are never overwritten; the setup script confirms the gallery version is `Succeeded` after the build. Packer generates the temporary `packer` administrator password and deletes the temporary resource group (named `pkr-immersionday-*`) when the build ends. **A failed build keeps its temporary VM and resource group by default** (the setup script uses `packer build -on-error=abort`) so it can be troubleshot; the log prints the retained group name. The retained VM keeps running and incurring charges until you run `az group delete --name <group> --yes`. Pass `-CleanupOnFailure` to `Setup-LabEnvironment.ps1` to delete a failed build's temporary resources automatically instead.

### 4. Configure Hosts and Event Users

Update the existing tfvars file with the published version, host count and desired user count. For example, 13 hosts at the configured maximum of eight sessions each provide a nominal limit of 104 sessions for 100 users; confirm actual workload capacity and quota rather than treating the limit as a sizing guarantee.

```hcl
num_of_labusers        = 100
avd_session_host_count = 13
avd_image_version      = "1.0.0"
```

Generate a registration expiry in the same PowerShell terminal:

```powershell
$RegistrationExpiry = [DateTimeOffset]::UtcNow.AddHours(12).ToString('yyyy-MM-ddTHH:mm:ssZ')
$RegistrationExpiry
```

Set `avd_registration_expiration` in tfvars to that UTC timestamp. It must be between one hour and 30 days after the plan time. Recalculate it for later plans that deploy hosts; a stale timestamp can block an unrelated plan while the host count remains positive.

**Administrator password:** remove the `avd_admin_password = null` assignment from the local tfvars file before the next command, leaving the variable declaration unchanged. An explicit tfvars value, including null, overrides `TF_VAR_avd_admin_password`. Keep real passwords out of tracked files and command-line arguments. The password must be 12-123 characters and satisfy Azure Windows password complexity requirements.

### 5. Deploy Session Hosts

The following prompts locally for the administrator password, supplies it through the process environment and removes the environment value afterward. For future plans/applies, supply the same password again unless intentionally rotating it. Do not print the environment value or capture it in logs.

```powershell
$AdminPassword = Read-Host 'Session-host local administrator password' -AsSecureString
try {
    $env:TF_VAR_avd_admin_password = [System.Net.NetworkCredential]::new('', $AdminPassword).Password
    tofu -chdir=infra plan -out=session-hosts.tfplan
    tofu -chdir=infra apply session-hosts.tfplan
} finally {
    Remove-Item Env:TF_VAR_avd_admin_password -ErrorAction SilentlyContinue
    $AdminPassword.Dispose()
}

tofu -chdir=infra output avd_configuration
tofu -chdir=infra output -raw lab_users_csv_path
tofu -chdir=infra output lab_credentials_key_vault
```

The password is still stored in local state and the saved plan; environment delivery does not eliminate that storage. Do not restore the null tfvars assignment while intending to plan with a positive host count. Before teardown, remove saved plans no longer needed through the approved credential-retention process.

Allow the registration extension/restart to finish (about five minutes after the VM is created). Confirm registration with `az rest --method GET --url "https://management.azure.com/subscriptions/<subscriptionId>/resourceGroups/<group>/providers/Microsoft.DesktopVirtualization/hostPools/<hostPool>/sessionHosts?api-version=2024-04-03"`, which should list every host as `Available`. Before distributing access, also confirm the hosts report Available in the host pool, group membership and role assignments have propagated, the CSV/vault records exist, and a test lab account can complete onboarding and open the desktop. These are organizer acceptance steps, not checks performed during README preparation.

## Inputs

All inputs are declared in [infra/variables.tf](infra/variables.tf), with **no variable defaults**. Supply configuration in [infra/terraform.tfvars](infra/terraform.tfvars), except real secrets delivered through an approved runtime mechanism. Fixed and derived values live in [infra/locals.tf](infra/locals.tf). Table examples are the current checked-in choices, not defaults. Azure naming, policy, region and quota restrictions still apply beyond the local validations described here.

### Environment

| Input                   | Type            | Purpose and acceptable values                                                                                                                                                                  | Current configuration                                            |
| ----------------------- | --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| `subscription_id`     | `string`      | Enabled target Azure subscription GUID. Must belong to the configured tenant.                                                                                                                  | `934600ac-0f19-44b8-b439-b4c5f02d8a7d`                         |
| `tenant_id`           | `string`      | Microsoft Entra tenant GUID for Azure resources and lab accounts.                                                                                                                              | `477bacc4-4ada-4431-940b-b91cf6cb3fd4`                         |
| `resource_group_name` | `string`      | Dedicated shared lab resource-group name; use an Azure-valid name. Also participates in group/vault naming.                                                                                    | `msftlabs-cus-immersionday`                                    |
| `location`            | `string`      | Azure region supported by all selected services/SKUs. Prefer canonical region codes such as`centralus`; checked-in casing is shown at right. All shared resources and hosts use this region. | `CentralUS`                                                    |
| `owner`               | `string`      | Non-empty responsible team/person; becomes the enforced Owner tag.                                                                                                                             | `immersionday-admins`                                          |
| `tags`                | `map(string)` | Additional resource tags. Fixed`ManagedBy`, `SecurityControl` and `Owner` values from locals override matching keys.                                                                     | `Environment = "Labs"`, `Project = "msftlabs-immersion-day"` |

### Gallery and Image Definition

| Input                     | Type             | Purpose and acceptable values                                                                                                                                                                                                                                                                                        | Current configuration                          |
| ------------------------- | ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------- |
| `gallery_name`          | `string`       | Gallery name; 1-80 characters, starts with a letter, then letters/digits/underscores/periods. No hyphens; also meet Azure uniqueness rules.                                                                                                                                                                          | `msftlabs_cus_immersionday_gallery`          |
| `image_definition_name` | `string`       | Azure-valid image definition name receiving Packer versions.                                                                                                                                                                                                                                                         | `win11-immersionday-lab`                     |
| `replication_regions`   | `list(string)` | Additional supported regions for image replicas;`[]` means source region only. The source `location` is always included and duplicates are removed. Does not create remote-region hosts.                                                                                                                         | `[]`                                     |
| `gallary_sharing`       | `string`       | Keep the existing spelling. Validation accepts`Private`, `Groups`, `Community`; only `Private` is the documented workshop path. Group/direct sharing needs separate approval/setup; community sharing is public and needs metadata not configured here. Changing this value alone does not complete sharing. | `Private`                                    |
| `image_ostype`          | `string`       | Schema accepts`Windows` or `Linux`, but this Packer/AVD workflow requires `Windows`. Linux would require a different image and host implementation.                                                                                                                                                            | `Windows`                                    |
| `image_description`     | `string`       | Non-empty gallery/image description.                                                                                                                                                                                                                                                                                 | Windows 11 multi-session lab tools description |
| `image_identifier`      | `object`       | Required custom-image identifier fields described below; this is not the Marketplace source-image selector.                                                                                                                                                                                                          | See below                                      |

| `image_identifier` field | Type       | Meaning / current value                                          |
| -------------------------- | ---------- | ---------------------------------------------------------------- |
| `publisher`              | `string` | Custom image publisher identifier:`MSFTLABS`.                  |
| `offer`                  | `string` | Custom image offer identifier:`ImmersionDay`.                  |
| `sku`                    | `string` | Custom image SKU identifier:`Windows11EnterpriseMultiSession`. |

Use non-empty Azure-valid identifier strings and a distinct publisher/offer/SKU combination within the gallery.

### Network and Bastion

`network_config` is an object with all fields required. CIDRs must be valid IPv4, all subnets must fit inside the VNet, and the three subnet ranges must be distinct and non-overlapping. Bastion requires `/26` or larger, meaning a prefix length of 26 or less.

| `network_config` field    | Type       | Purpose / current value                                                                                             |
| --------------------------- | ---------- | ------------------------------------------------------------------------------------------------------------------- |
| `name`                    | `string` | Azure-valid VNet name:`vnet-msftlabs-cus-immersionday`.                                                           |
| `address_space`           | `string` | VNet IPv4 CIDR:`10.42.0.0/22`.                                                                                    |
| `avd_subnet_name`         | `string` | Session-host subnet name:`snet-avd`.                                                                              |
| `avd_subnet_cidr`         | `string` | Session-host IPv4 range:`10.42.1.0/24`. Reserve enough addresses for hosts and Azure's reserved subnet addresses. |
| `image_build_subnet_name` | `string` | Runner and Packer build subnet name: `snet-runner-build`.                                                         |
| `image_build_subnet_cidr` | `string` | Runner and Packer build subnet IPv4 range: `10.42.2.0/26`.                                                        |
| `bastion_subnet_cidr`     | `string` | Bastion IPv4 range:`10.42.0.0/26`. Subnet name is fixed to `AzureBastionSubnet`.                                |

| `bastion_config` field | Type       | Purpose and acceptable values                                             | Current configuration                 |
| ------------------------ | ---------- | ------------------------------------------------------------------------- | ------------------------------------- |
| `name`                 | `string` | Azure-valid Bastion resource name.                                        | `msftlabs-cus-immersionday-bastion` |
| `sku`                  | `string` | `Basic` or `Standard`; native-client tunneling requires `Standard`. | `Standard`                          |
| `tunneling_enabled`    | `bool`   | `true` enables native-client tunneling; `false` disables it.          | `true`                              |

### Runner

`runner_config` is a required object with the self-hosted GitHub runner that builds the image from inside the VNet. The VM is placed in the `image_build` subnet (`snet-runner-build`), has no public IP, and is reached through Azure Bastion.

| `runner_config` field | Type | Purpose and acceptable values | Current configuration |
| --- | --- | --- | --- |
| `name` | `string` | 3-15 lowercase letters/digits/hyphens; also the VM and GitHub runner name. | `msftlabs-runner` |
| `size` | `string` | Regional VM SKU for the runner; the build VM it launches uses `-VmSize` instead. | `Standard_D2s_v5` |
| `admin_username` | `string` | Local Linux administrator and the account the runner service runs as. | `runneradmin` |
| `github_repository` | `string` | `owner/repository` the runner registers with; the signed-in `gh` user needs admin rights on it. | `MSFTLabs/msftlabs-immersion-day` |

The runner's admin password is generated by OpenTofu and stored in the lab Key Vault as `runner-admin-password`. The subnet NSG allows Bastion to ports 22 and 3389 and the subnet itself to ports 5985 and 5986 (WinRM to the build VM); everything else inbound is denied.

### Users and Credential Vault

| Input / object field                     | Type            | Purpose and acceptable values                                                                                                                                                                                            | Current configuration |
| ---------------------------------------- | --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------- |
| `num_of_labusers`                      | `number`      | Integer`0..999`; creates numbered accounts and automatic group-based AVD access. `0` disables user/group/TAP creation, not the shared infrastructure/vault. Reducing the count deletes accounts above the new count. | `5`    |
| `key_vault_config.name_prefix`         | `string`      | 1-15 characters, starts with a letter, then letters/digits/hyphens; no trailing or consecutive hyphens. Locals append a deterministic eight-character hash suffix; final name must be globally available.                | `kv-msftlabs-cus`   |
| `key_vault_config.staff_principal_ids` | `set(string)` | Approved staff Entra user/group/service-principal**object GUIDs** for vault-secret read access; not UPNs or application/client IDs. `[]` adds no staff readers. Does not grant AVD access.                       | `[]`                |

### AVD Control Plane and Hosts

`avd_config` is an object with all fields required. Azure-valid resource names, supported Windows VM sizes and adequate capacity are required in addition to the explicit validation rules below.

| `avd_config` field          | Type       | Purpose and acceptable values                                                                                                                                             | Current configuration             |
| ----------------------------- | ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------- |
| `host_pool_name`            | `string` | Pooled AVD host-pool name.                                                                                                                                                | `hp-msftlabs-cus-immersionday`  |
| `workspace_name`            | `string` | AVD workspace name.                                                                                                                                                       | `ws-msftlabs-cus-immersionday`  |
| `application_group_name`    | `string` | Desktop application-group name.                                                                                                                                           | `dag-msftlabs-cus-immersionday` |
| `desktop_display_name`      | `string` | Desktop/workspace friendly label seen by users.                                                                                                                           | `Immersion Day Lab Desktop`     |
| `session_host_name_prefix`  | `string` | Starts with a letter; at most 11 letters/digits/hyphens. Hosts append`-001`, `-002`, etc., fitting the Windows computer-name limit.                                   | `lab-avd`                       |
| `session_host_size`         | `string` | Regional VM SKU supporting the Gen2/Trusted Launch Windows image; confirm availability and family/total-vCPU quota.                                                       | `Standard_D8s_v5`               |
| `session_host_os_disk_type` | `string` | Provider disk options include`Standard_LRS`, `StandardSSD_LRS`, `Premium_LRS`, `StandardSSD_ZRS`, `Premium_ZRS`; chosen region/VM size must support the option. | `StandardSSD_LRS`               |
| `maximum_sessions_per_host` | `number` | Positive integer session limit per pooled host; does not size VMs or automatically add hosts.                                                                             | `8`                             |
| `load_balancer_type`        | `string` | `BreadthFirst` spreads sessions; `DepthFirst` fills hosts toward their limit first.                                                                                   | `BreadthFirst`                  |
| `admin_username`            | `string` | Azure-valid local Windows administrator name, avoiding reserved names; not a student Entra username.                                                                      | `labadmin`                      |

| Input                           | Type                            | Purpose and acceptable values                                                                                                                                                                                | Foundation value |
| ------------------------------- | ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------- |
| `avd_session_host_count`      | `number`                      | Integer`0..999`; `0` creates no hosts or registration token. Positive values require a published image version, administrator password and valid expiry; practical limits include subnet size and quota. | `0`                 |
| `avd_image_version`           | `string` or `null`          | Numeric`Major.Minor.Patch`, such as `1.0.0`, already published under this root's definition. `null` is allowed only with zero hosts; `latest` and full resource IDs are not accepted.                | `null`              |
| `avd_admin_password`          | Sensitive`string` or `null` | Required for positive host counts; 12-123 characters plus Azure Windows complexity requirements. Use a secret runtime override, not a committed password. Explicit null is allowed only with zero hosts.     | `null`              |
| `avd_registration_expiration` | `string` or `null`          | RFC3339 UTC timestamp, such as`2026-10-14T23:00:00Z`, between one hour and 30 days after plan time. Example timestamp is illustrative, not reusable. `null` is allowed only with zero hosts.             | `null`              |

The current event uses `avd_session_host_count = 2`, `avd_image_version = "1.0.0"`, a registration expiry of `2026-11-05T02:33:26Z` and `avd_admin_password = null` in the tfvars file; the real password lives in Key Vault and is supplied at plan/apply time (see [Operations notes](#operations-notes)).

### Fixed Settings

Review [infra/locals.tf](infra/locals.tf) when changing implementation policy rather than event inputs. Fixed settings include naming/password generation, default managed-domain selection, US usage location, eight-hour reusable TAPs, private host NICs, Entra RDP properties, Trusted Launch, NAT/public-IP SKUs, vault RBAC/retention and enforced tags. Start VM on Connect is disabled; no autoscaling plan is deployed.

### Shared Monitoring Inputs

`monitoring_config` is a required object in [infra/terraform.tfvars](infra/terraform.tfvars), with no variable defaults. The storage SKU/security settings, diagnostic targets/category discovery and workspace billing tier are fixed in locals.

| Field | Type | Purpose and acceptable values | Current configuration |
| --- | --- | --- | --- |
| `boot_storage_name_prefix` | `string` | 1-16 lowercase letters/digits. A deterministic eight-character suffix is appended; final storage-account name must be globally available. | `stmsftcusboot` |
| `workspace_name` | `string` | 4-63 letters/digits/hyphens, with no leading/trailing hyphen. | `law-msftlabs-cus-immersionday` |
| `workspace_retention_days` | `number` | Integer `30..730` for the shared workspace's default log retention. Table-specific/service retention rules may differ; this does not expire boot blobs. | `30` |
| `workspace_daily_quota_gb` | `number` | `-1` for uncapped ingestion, or a positive daily GB quota. Reaching a positive cap interrupts collection. | `-1` |

## Image-Build Parameters

[scripts/Setup-LabEnvironment.ps1](scripts/Setup-LabEnvironment.ps1) accepts these parameters for the image build; they are distinct from the OpenTofu inputs.

| Parameter                        | Accepted value / behavior                                                                                                                                                               |
| -------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `-ImageVersion`                | New numeric`Major.Minor.Patch`, for example `1.0.0`; used as the prompt default. A published version is never overwritten.                                                          |
| `-ImageSku`                    | Stable regional Windows 11 multi-session SKU matching`win11-YYhN-avd`. The latest available match is used if omitted.                                                                  |
| `-VmSize`                      | Approved, available build VM SKU; script default is`Standard_D4s_v5`. Separate from the AVD host size.                                                                                |
| `-OpenTofuCommand`             | OpenTofu executable name/path; script default`tofu`.                                                                                                                                  |
| `-PackerCommand`               | Packer executable name/path; script default`packer`.                                                                                                                                  |
| `-CleanupOnFailure`            | Switch. Deletes a failed build's temporary VM and resource group. Omitted (default), failed builds are kept for troubleshooting and the log shows how to inspect and delete them.        |

## Outputs

Read a named output with `tofu -chdir=infra output <name>`, adding `-raw` for a string or `-json` for structured data. Prefer named outputs over a full JSON state/output dump when sharing operational information.

| Output                           | Content                                                                                                                             | Sensitive? |
| -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- | ---------- |
| `gallery_id`                   | Gallery resource ID.                                                                                                                | No         |
| `image_definition_id`          | Image definition ID used for Packer publication.                                                                                    | No         |
| `packer_configuration`         | Build subscription/tenant, location, gallery identifiers, replica regions, tags and the VNet, resource group and subnet the Packer build VM joins.                             | No         |
| `portal_url`                   | Tenant-qualified gallery portal URL, not a student desktop URL.                                                                     | No         |
| `network_configuration`        | VNet/subnet/Bastion identifiers and NAT egress public IP. The `image_build` subnet hosts the runner and Packer build VMs. | No         |
| `runner_configuration`         | Runner VM name, private IP, managed-identity principal, vault URI of the admin password, repository and labels. | No         |
| `avd_configuration`            | Host-pool/workspace/application-group IDs, host VM IDs/private IPs, selected image version and host-pool portal URL.                | No         |
| `lab_users`                    | Created account UPNs and Entra object IDs.                                                                                          | No         |
| `lab_user_group_id`            | Generated security-group object ID, or null with zero users.                                                                        | No         |
| `lab_user_initial_credentials` | Creation-time UPNs and initial passwords; no TAPs. Avoid printing or exporting this output casually.                                | Yes        |
| `lab_users_csv_path`           | Path to`artifacts/credentials/LabUsers.csv`; the path is non-secret, the file is not.                                             | No         |
| `lab_credentials_key_vault`    | Vault name/ID/URI and expected versionless secret paths; not credential values or proof that publication succeeded.                 | No         |

The non-secret `lab_resource_groups` output maps each LabUser to their exercise-group name/ID and owner object ID/UPN. Read it with `tofu -chdir=infra output lab_resource_groups` to distribute the correct exercise scope to students.

The `shared_resource_group` output provides the core group name/ID/location. The non-secret `monitoring_configuration` output provides the boot-storage name/ID/blob endpoint, workspace name/resource ID/customer ID and diagnostic-setting IDs. Read it with `tofu -chdir=infra output monitoring_configuration`; it contains no storage or workspace keys.

## Credentials and Onboarding

The publisher creates one JSON vault secret per user, such as `labuser001-credentials`, and exports `artifacts/credentials/LabUsers.csv`. `LabUser` is the sign-in UPN; `Assigned Student` starts blank and staff-entered assignments are preserved by UPN on later exports. Import CSV columns as text in spreadsheet software and share records only through approved staff/student channels.

Passwords are cryptographically random and retained in local state. Unchanged applies do not rotate them. Users must change their initial password at first sign-in; initial vault/CSV records become stale after a student changes their password. Name collisions with existing tenant accounts require deliberate resolution/import, not automatic takeover.

TAPs are issued immediately when credentials are published, expire after eight hours and are usable once. They are approved onboarding/recovery authentication, **not an MFA or Conditional Access bypass** and not a replacement for the student's current password. The workflow retains existing active policy targets, does not weaken lifetime limits/exclusions, and stops for incompatible policy settings. If TAP was disabled, the new eligibility is restricted to the lab group instead of activating dormant targets.

Before connecting to AVD, students complete the tenant's approved browser onboarding/password-change flow. Then open [Windows App in a browser](https://windows.cloud.microsoft/), sign in with the lab UPN, select **Devices**, find the configured desktop and select **Connect**. Use a current supported desktop browser with WebGL enabled and AVC support; mobile browsers are not supported. See [Microsoft&#39;s Windows App connection guidance](https://learn.microsoft.com/windows-app/get-started-connect-devices-desktops-apps?tabs=web-avd&pivots=azure-virtual-desktop). The legacy Remote Desktop web client is no longer supported in the public cloud. Licensing, SSO, authentication strengths and Conditional Access still apply independently of account creation and RBAC.

Retries reuse matching vault records; they do not automatically renew expired or used TAPs. Authorized renewal through [infra/scripts/Publish-LabCredentials.ps1](infra/scripts/Publish-LabCredentials.ps1) with `-RenewTap` requires its configured sensitive environment inputs and deliberately replaces passes in the vault/CSV. Do not assume rerunning apply renews passes. If only the CSV is lost, replacement of `terraform_data.lab_credentials_csv[0]` with a positive user count rebuilds it from matching records without renewing passes.

Local state, state backups, saved plans and the CSV contain secrets. Restrict them to organizers, retain one authoritative state and never commit/share them. TAPs are written directly to vault/CSV rather than provider outputs; initial passwords and VM administrator credentials still live in state/plans. The exporter restricts the credentials directory to the exporting Windows account and SYSTEM. The vault has a public endpoint but requires authenticated data-plane RBAC; it is not anonymous access.

## Operations Notes

These are the behaviors and recovery steps learned while building and deploying the current environment. Each one was observed on the live deployment.

### Why images are built on an in-VNet runner

Packer has to reach the Windows build VM over WinRM. From an organizer workstation this never worked here: the workstation's Global Secure Access client sits on the network adapter and TCP connects to the VM's public IP appear to succeed while the VM never receives the traffic, and the tenant's governance automation (`MCAPSGovernance-AutomationApp`) rewrote the temporary build NSG about 20 minutes into a build, removing the allow rule. Building from a runner inside the VNet avoids both: the build VM gets a private IP in `snet-runner-build`, WinRM (HTTP 5985, with `AllowUnencrypted` because Packer's NTLM client does not seal the HTTP body) never leaves the VNet, and no public IP or inbound rule is needed.

### Operating the runner

- Connect with Azure Bastion native-client tunneling as `runneradmin`; the password is in the lab Key Vault secret `runner-admin-password`.
- The runner runs as the systemd service `actions.runner.MSFTLabs-msftlabs-immersion-day.msftlabs-runner.service`. Check it with `sudo systemctl status <service>`, and confirm GitHub sees it with `gh api repos/MSFTLabs/msftlabs-immersion-day/actions/runners`.
- Tools were installed by cloud-init (log `/var/log/runner-bootstrap.log`, inventory `/opt/runner-tools.txt`). The registration token is short-lived and is never stored in OpenTofu state; rerun `-Stage Runner` to register again.
- The setup script dispatches the `build-image.yml` workflow and polls the run. The runner checks out the repository, so `packer/`, `labs/` and `.github/` must be committed and pushed first; the Image stage stops if they are not. The Packer log is in the workflow run on GitHub, and a failed run keeps the temporary VM unless `-CleanupOnFailure` was used.
- The runner identity has Contributor on the whole subscription because Packer creates its own temporary resource group. Scope it down only if you can still allow that group creation.
- `.github/workflows/build-image.yml` runs the build on the runner using the repository variables the Runner stage sets. It starts when `packer/CHANGELOG.md` changes on `main` (the version comes from its first `## [x.y.z]` heading, and a version already in the gallery is skipped) or when dispatched by the Image stage. It has not been pushed or exercised.

### Image build behavior

- A failed build keeps its temporary VM and resource group (`pkr-immersionday-*`) unless `-CleanupOnFailure` is used. Delete kept groups promptly, because the VM keeps billing.
- `Install-LabTools.ps1` runs as the `packer` user. The WinGet CLI is not used because Microsoft documents it as unsupported in the system context; Sysprep also stays as the `packer` user because running Sysprep as SYSTEM is unsupported on Windows 11.
- Never install per-user (MSIX/Appx) packages before Sysprep; the Chocolatey, MSI and `oh-my-posh font install` (elevated, system-wide) steps are all machine-wide.

### AVD host registration

- The registration extension passes the registration script as plain base64 (`base64encode`) and runs it with `Invoke-Expression`. The gzip form (`base64gzip` with a `GzipStream` decompress) looks fine but the Custom Script extension silently runs nothing, with exit code 0 and empty output, so do not reintroduce it. The command must stay under 8191 characters (currently about 5800).
- The Entra join extension (`AADLoginForWindows`) must not set `enableAutomaticUpgrade`; Azure rejects it with a 409.
- `Application.Read.All` is granted but no longer used by the plan (it was needed to look up the AVD service principal for the removed scaling plan).
- **Replacing a host used to leave a stale session-host record** in the host pool, and the new VM's agent then failed with `NAME_ALREADY_REGISTERED` (and later `ENDPOINT_NOT_FOUND`). `terraform_data.session_host_record` now deletes the record (`infra/scripts/Remove-AvdSessionHostRecord.ps1`, destroy-time, `az rest` DELETE with `force=true`) before the old VM is replaced, so no manual step is needed. It needs `pwsh` and a signed-in `az` session on the machine running the apply, and a missing record is treated as success. If you still have to recover by hand: delete the record with `az rest --method DELETE --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/<group>/providers/Microsoft.DesktopVirtualization/hostPools/<pool>/sessionHosts/<host>" --url-parameters api-version=2024-04-03 force=true` (pass `force=true` through `--url-parameters`; a literal `&` in `--url` is swallowed by `az.cmd`), then on the VM set `HKLM:\SOFTWARE\Microsoft\RDInfraAgent` values `IsRegistered=0` and `RegistrationToken=<token from the host pool's retrieveRegistrationToken>` and restart the `RDAgentBootLoader` service. Do the delete first and only once per host.
- No AVD scaling plan is deployed, so hosts are never deallocated automatically; stop them with `az vm deallocate` if you want to save cost between sessions.

### Supplying the host administrator password

The guided Phase 2 stage generates the host password and stores it as `avd-local-admin-password` in the vault. To plan or apply by hand later, read it from the vault into a git-ignored `infra/zz-lab-phase2.auto.tfvars.json` (`{"avd_admin_password": "..."}`) for both the plan and the apply, then delete the file. A saved plan applied without the same variable fails with a variable-mismatch error.

### Expected plan noise

Tenant governance periodically strips the `SecurityControl = Ignore` tag (your approved MCAPS exception) from resources. A plan may therefore show many harmless in-place tag updates that re-add it.

## Cleanup

Full teardown removes the shared lab environment and managed Entra accounts, not just student desktops. Confirm the event has ended, account deletion is approved and required credential records have been retained securely. Do not use independent state copies or delete the resource group manually as a substitute for an orderly destroy. `./scripts/Setup-LabEnvironment.ps1 -Destroy` automates steps 3 and 4 below with confirmations (it does not clear student-created resources or reset the host count for you); see [Guided Setup](#guided-setup-with-setup-labenvironmentps1).

1. Stop student sessions and remove student-created exercise resources inside each `LAB-LabUserXXX` group. Those workloads are not tracked by this root, and the non-empty-resource-group deletion guard prevents deleting their groups while resources remain. The final destroy also removes the managed student resource groups and their Owner assignments.
2. Set `avd_session_host_count = 0` and the image/password/registration inputs back to null in the existing tfvars file. Plan/apply to remove session-host VMs before deleting their source image versions. Keep the current user count unless account deletion is intended at this stage.
3. Delete each approved Packer-managed image version explicitly; it is outside OpenTofu state and must be removed before the image definition/gallery can be deleted.
4. Review and apply the full destroy plan, using the same state and an identity authorized for Azure and Entra cleanup.

Before the final destroy also remove the runner's registration so GitHub does not keep an offline runner: on the runner (via Bastion) run `cd /opt/actions-runner && sudo ./svc.sh stop && sudo ./svc.sh uninstall`, then `sudo -u runneradmin ./config.sh remove --token <removal token from gh api -X POST repos/<owner>/<repo>/actions/runners/remove-token>`, and delete the `AZURE_*`, `GALLERY_*`, `IMAGE_*`, `VNET_*`, `REPLICATION_REGIONS` and `RESOURCE_TAGS` repository variables set by the Runner stage. Delete any leftover `pkr-immersionday-*` groups.

Example host-removal and image-version cleanup, run from the same authenticated PowerShell terminal after updating tfvars:

```powershell
tofu -chdir=infra plan -out=remove-hosts.tfplan
tofu -chdir=infra apply remove-hosts.tfplan

$GalleryConfiguration = tofu -chdir=infra output -json packer_configuration | ConvertFrom-Json
$ImageVersionToDelete = '1.0.0'
az sig image-version delete `
    --resource-group $GalleryConfiguration.gallery_resource_group `
    --gallery-name $GalleryConfiguration.gallery_name `
    --gallery-image-definition $GalleryConfiguration.image_definition_name `
    --gallery-image-version $ImageVersionToDelete

tofu -chdir=infra plan -destroy -out=destroy.tfplan
tofu -chdir=infra apply destroy.tfplan
```

Before full teardown, retain any required diagnostic evidence; destroying the shared storage account removes its boot-log data. Workspace removal and Azure retention behavior do not replace an approved evidence export. Diagnostic settings and their shared workspace/storage are managed by the same root.

## Repository Layout

| Path | Purpose |
| --- | --- |
| `scripts/Setup-LabEnvironment.ps1` | The guided wrapper (stages `ServicePrincipal`, `Phase1`, `Runner`, `Image`, `Phase2`, and `-Destroy`). The only file in `scripts/`. |
| `infra/*.tf`, `infra/terraform.tfvars` | The OpenTofu root: `main.tf` (gallery, vault, resource groups), `networking.tf`, `avd.tf`, `labusers.tf`, `runner.tf`, `locals.tf`, `variables.tf`, `outputs.tf`, `providers.tf`, `terraform.tf`. |
| `infra/scripts/` | Files the OpenTofu root calls: `Publish-LabCredentials.ps1`, `Export-LabUserCsv.ps1`, `Register-AvdSessionHost.ps1.tftpl` (the AVD registration script template) and `runner-cloud-init.yaml` (runner tool installation). |
| `packer/windows11/windows11.pkr.hcl` | The `azure-arm` image template. |
| `packer/windows11/scripts/` | Guest scripts: `Enable-WinRM.ps1`, `Install-LabTools.ps1`, `Test-LabImage.ps1` and `Generalize-LabImage.ps1`. |
| `labs/` | Lab guides and their `images/`; uploaded into the image at `C:\labs`. |
| `.github/workflows/build-image.yml` | Workflow that builds the image on the runner: starts on a `packer/CHANGELOG.md` change on `main` or by dispatch, and skips a version already in the gallery (not pushed or exercised). |
| `packer/CHANGELOG.md` | Image changelog; its first `## [x.y.z]` heading is the version the workflow and the Image stage build. |
| `notes.md` | Workshop scenario, lab outlines and talking points; not deployment documentation. |

Git-ignored and sensitive: `infra/*.tfstate*`, saved plans (`*.tfplan`), `infra/zz-lab-phase2.auto.tfvars.json`, `artifacts/` (including `credentials/LabUsers.csv`), `.logs/` and `.tools/`.

## References

- [AVD prerequisites/licensing](https://learn.microsoft.com/azure/virtual-desktop/prerequisites), [Entra-joined session hosts and access roles](https://learn.microsoft.com/azure/virtual-desktop/azure-ad-joined-session-hosts), and [Windows App browser connection guidance](https://learn.microsoft.com/windows-app/get-started-connect-devices-desktops-apps?tabs=web-avd&pivots=azure-virtual-desktop).
- [AVD golden-image preparation](https://learn.microsoft.com/azure/virtual-desktop/set-up-golden-image) and [Windows Enterprise multi-session FAQ](https://learn.microsoft.com/azure/virtual-desktop/windows-multisession-faq).
- [Compute Gallery RBAC sharing](https://learn.microsoft.com/azure/virtual-machines/share-gallery) and [direct-sharing preview](https://learn.microsoft.com/azure/virtual-machines/share-gallery-direct). Cross-tenant sharing is not configured by this root.
- [TAP configuration/onboarding](https://learn.microsoft.com/entra/identity/authentication/howto-authentication-temporary-access-pass), [create a TAP](https://learn.microsoft.com/graph/api/authentication-post-temporaryaccesspassmethods?view=graph-rest-1.0), and [update TAP policy](https://learn.microsoft.com/graph/api/temporaryaccesspassauthenticationmethodconfiguration-update?view=graph-rest-1.0).
- [Key Vault RBAC](https://learn.microsoft.com/azure/key-vault/general/rbac-guide) and [soft delete/purge protection](https://learn.microsoft.com/azure/key-vault/general/soft-delete-overview).
- [VM boot diagnostics and storage limitations](https://learn.microsoft.com/azure/virtual-machines/boot-diagnostics), [Bastion monitoring](https://learn.microsoft.com/azure/bastion/monitor-bastion), [NSG event/rule-counter diagnostics](https://learn.microsoft.com/azure/virtual-network/virtual-network-nsg-manage-log), and [AVD diagnostic routing](https://learn.microsoft.com/azure/virtual-desktop/diagnostics-log-analytics).
- [Packer WinRM communicator](https://developer.hashicorp.com/packer/docs/communicators/winrm), [Azure `azure-arm` builder options](https://developer.hashicorp.com/packer/integrations/hashicorp/azure/latest/components/builder/arm) and the plugin's `example/windows_skip_key_vault` samples, which the WinRM bootstrap follows.
- [Self-hosted GitHub Actions runners](https://docs.github.com/actions/hosting-your-own-runners), [WinGet troubleshooting](https://learn.microsoft.com/windows/package-manager/winget/troubleshooting), [Sysprep as SYSTEM on Windows 11](https://learn.microsoft.com/troubleshoot/windows-client/setup-upgrade-and-drivers/sysprep-as-system-windows-11) and [Custom Script extension for Windows](https://learn.microsoft.com/azure/virtual-machines/extensions/custom-script-windows).
- [Owner role permissions](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/privileged#owner) and [Azure RBAC scope](https://learn.microsoft.com/azure/role-based-access-control/scope-overview).
- [PowerShell installation](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows), [Azure CLI installation](https://learn.microsoft.com/cli/azure/install-azure-cli-windows), and [Packer Azure ARM builder](https://developer.hashicorp.com/packer/integrations/hashicorp/azure/latest/components/builder/arm).
