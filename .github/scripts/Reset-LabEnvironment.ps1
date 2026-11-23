#Requires -Version 7.0
<#
.SYNOPSIS
    Removes everything the three phase workflows create, so the lab can be tested again from nothing.

.DESCRIPTION
    Run it signed in with 'az login' as a Global Administrator who is also Owner of the subscription. Deleting resources by hand leaves things behind that break the next deployment, so this removes them in the order that works.
    Azure
      1. Gallery image versions, so the gallery deletes cleanly.
      2. Diagnostic settings (kept by Azure after their resource is deleted, they fail the next deployment with "already exists").
      3. The Log Analytics workspace, permanently, so none is recovered later.
      4. The shared lab resource group, every LAB-* student resource group, and any temporary Packer build groups (pkr-immersionday-*).
      5. Key Vaults purged (the lab vault and Packer's temporary vaults). A vault with purge protection cannot be purged; the date its name is free is reported.
      6. Subscription-scope role assignments of the deleted VMs' managed identities.
      7. The state resource group (unless -KeepState).
    Microsoft Entra
      8. LabUser accounts and the lab group, deleted and then purged from the recycle bin.
      9. Device records of the AVD session hosts (a stale record blocks the next Entra join).
     10. Temporary Access Pass policy targets that point at a group that no longer exists.
    GitHub (when -Repository is given)
     11. The registered runner and the repository variables the deployment sets. Secrets are never touched.
    Local
     12. The staff credentials CSV under artifacts/credentials.

.PARAMETER DeploymentName
    State deployment name; empty uses resource_group_name from infra/terraform.tfvars.

.PARAMETER Repository
    GitHub owner/repo whose runner and variables should be cleared, for example BenTheCloudGuy/bentest-immersion-day.

.PARAMETER KeepState
    Keep the <deploymentName>-state resource group.

.PARAMETER WhatIf
    List what would be removed and change nothing.

.PARAMETER Force
    Skip the typed confirmation.
#>
[CmdletBinding()]
param(
    [string]$DeploymentName,
    [string]$Repository,
    [switch]$KeepState,
    [switch]$WhatIf,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$tfvars = Get-Content -LiteralPath (Join-Path $repositoryRoot 'infra/terraform.tfvars') -Raw
function Get-TfVarString([string]$Name) {
    $match = [regex]::Match($tfvars, "(?m)^\s*$Name[ \t]*=[ \t]*`"(?<value>[^`"]+)`"")
    if (-not $match.Success) { throw "$Name must be a quoted string in infra/terraform.tfvars." }
    return $match.Groups['value'].Value
}
$resourceGroup = Get-TfVarString 'resource_group_name'
$subscriptionId = Get-TfVarString 'subscription_id'
$hostPrefix = Get-TfVarString 'session_host_name_prefix'
if (-not $DeploymentName) { $DeploymentName = $resourceGroup }
$stateResourceGroup = "$DeploymentName-state"
$labGroupName = "$resourceGroup-avd-labusers"
$diagnosticSettingName = 'lab-to-log-analytics'
$runnerName = 'msftlabs-runner'
$repositoryVariables = 'AZURE_SUBSCRIPTION_ID', 'AZURE_TENANT_ID', 'AZURE_LOCATION', 'GALLERY_RESOURCE_GROUP', 'GALLERY_NAME', 'IMAGE_DEFINITION_NAME', 'REPLICATION_REGIONS', 'VNET_NAME', 'VNET_RESOURCE_GROUP', 'VNET_SUBNET_NAME', 'RESOURCE_TAGS'
$diagnosticTypes = 'Microsoft.Network/bastionHosts', 'Microsoft.DesktopVirtualization/hostPools', 'Microsoft.DesktopVirtualization/applicationGroups', 'Microsoft.DesktopVirtualization/workspaces', 'Microsoft.Network/networkSecurityGroups'
$tapPolicyUrl = 'https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/TemporaryAccessPass'

function Write-Step([string]$Message) { Write-Host "$([DateTime]::UtcNow.ToString('HH:mm:ss')) $Message" }

# Runs az and returns parsed JSON, or $null for no output. Failures throw unless -AllowFailure.
function Invoke-AzJson {
    param([string[]]$Arguments, [switch]$AllowFailure, [switch]$NoSubscription)
    $scope = if ($NoSubscription) { @() } else { @('--subscription', $subscriptionId) }
    $output = & az @Arguments @scope --only-show-errors --output json 2>&1
    $text = ($output | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        if ($AllowFailure) { return $null }
        throw "az $($Arguments[0]) $($Arguments[1]) failed: $(($output | Out-String).Trim())"
    }
    if ($text) { return ($text | ConvertFrom-Json) }
}

function Test-GroupExists([string]$Name) {
    return (& az group exists --name $Name --subscription $subscriptionId --only-show-errors | Out-String).Trim() -eq 'true'
}

function Wait-GroupsDeleted([string[]]$Names) {
    $deadline = (Get-Date).AddMinutes(60)
    while ($true) {
        $remaining = @($Names | Where-Object { Test-GroupExists $_ })
        if ($remaining.Count -eq 0) { return }
        if ((Get-Date) -gt $deadline) { throw "Resource groups were not deleted within 60 minutes: $($remaining -join ', ')." }
        Write-Step "Waiting for resource group(s) to finish deleting: $($remaining -join ', ')"
        Start-Sleep -Seconds 30
    }
}

# Microsoft Graph with the signed-in user's token. Returns every page of a collection.
$script:GraphToken = $null
function Invoke-Graph {
    param([string]$Method = 'GET', [string]$Uri, $Body)
    if (-not $script:GraphToken) { $script:GraphToken = (& az account get-access-token --resource https://graph.microsoft.com --query accessToken --output tsv --only-show-errors | Out-String).Trim() }
    $arguments = @{ Method = $Method; Uri = $Uri; Headers = @{ Authorization = "Bearer $script:GraphToken" } }
    if ($null -ne $Body) { $arguments.Body = ($Body | ConvertTo-Json -Depth 10); $arguments.ContentType = 'application/json' }
    $response = Invoke-RestMethod @arguments
    if ($Method -ne 'GET') { return }
    $items = [Collections.Generic.List[object]]::new()
    if ($response.PSObject.Properties['value']) {
        $items.AddRange(@($response.value))
        while ($response.PSObject.Properties['@odata.nextLink'] -and $response.'@odata.nextLink') {
            $response = Invoke-RestMethod -Uri $response.'@odata.nextLink' -Headers $arguments.Headers
            $items.AddRange(@($response.value))
        }
        return $items.ToArray()
    }
    return $response
}

function Remove-GraphObject([string]$Collection, [string]$Id, [string]$Label) {
    try { Invoke-Graph -Method DELETE -Uri "https://graph.microsoft.com/v1.0/$Collection/$Id"; Write-Step "Deleted $Label." }
    catch { Write-Step "WARNING: could not delete $Label : $($_.Exception.Message)" }
}

$account = Invoke-AzJson @('account', 'show')
if ($account.id -ne $subscriptionId) { throw "Azure CLI is on subscription $($account.id) but infra/terraform.tfvars targets $subscriptionId. Run az account set first." }
Write-Step "Signed in as $($account.user.name) on $($account.name)."

# ---- Discover everything first
$groups = @(Invoke-AzJson @('group', 'list'))
$studentGroups = @($groups | Where-Object { $_.name -like 'LAB-*' -and $_.tags -and $_.tags.PSObject.Properties['LabUser'] } | ForEach-Object { $_.name })
$packerGroups = @($groups | Where-Object { $_.name -like 'pkr-immersionday-*' } | ForEach-Object { $_.name })
$groupExists = Test-GroupExists $resourceGroup
$stateExists = Test-GroupExists $stateResourceGroup
$resources = @()
if ($groupExists) { $resources = @(Invoke-AzJson @('resource', 'list', '--resource-group', $resourceGroup)) }

$diagnosticTargets = @($resources | Where-Object { $_.type -in $diagnosticTypes })
$workspaces = @($resources | Where-Object { $_.type -eq 'Microsoft.OperationalInsights/workspaces' })
$galleries = @($resources | Where-Object { $_.type -eq 'Microsoft.Compute/galleries' })
$vaults = @($resources | Where-Object { $_.type -eq 'Microsoft.KeyVault/vaults' })
$vms = @($resources | Where-Object { $_.type -eq 'Microsoft.Compute/virtualMachines' })
$identityIds = @()
foreach ($vm in $vms) {
    $principal = (& az vm show --ids $vm.id --query identity.principalId --output tsv --only-show-errors 2>$null | Out-String).Trim()
    if ($principal) { $identityIds += $principal }
}

$labUsers = @(Invoke-Graph -Uri "https://graph.microsoft.com/v1.0/users?`$filter=startswith(displayName,'LabUser')&`$select=id,displayName" | Where-Object { $_.displayName -match '^LabUser\d{3}$' })
$labGroups = @(Invoke-Graph -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$labGroupName'&`$select=id,displayName")
$devices = @(Invoke-Graph -Uri "https://graph.microsoft.com/v1.0/devices?`$filter=startswith(displayName,'$hostPrefix-')&`$select=id,displayName")
$deletedUsers = @(Invoke-Graph -Uri 'https://graph.microsoft.com/v1.0/directory/deletedItems/microsoft.graph.user?$select=id,displayName' | Where-Object { $_.displayName -match '^LabUser\d{3}$' })
$deletedGroups = @(Invoke-Graph -Uri 'https://graph.microsoft.com/v1.0/directory/deletedItems/microsoft.graph.group?$select=id,displayName' | Where-Object { $_.displayName -eq $labGroupName })
$credentialsDirectory = Join-Path $repositoryRoot 'artifacts/credentials'

Write-Step 'Plan:'
Write-Step "  gallery image versions in $($galleries.Count) gallery(ies)"
Write-Step "  diagnostic settings on $($diagnosticTargets.Count) resource(s)"
Write-Step "  Log Analytics workspaces (permanent): $(if ($workspaces) { $workspaces.name -join ', ' } else { 'none' })"
Write-Step "  resource groups: $(@(@($resourceGroup | Where-Object { $groupExists }) + $studentGroups + $packerGroups) -join ', ')"
Write-Step "  Key Vaults to purge: $(if ($vaults) { $vaults.name -join ', ' } else { 'none in the lab group' }) (plus any soft-deleted Packer vault)"
Write-Step "  subscription role assignments for $($identityIds.Count) managed identit(ies)"
Write-Step "  state resource group $stateResourceGroup : $(if (-not $stateExists) { 'not present' } elseif ($KeepState) { 'kept' } else { 'delete' })"
Write-Step "  Entra: $($labUsers.Count) LabUser(s) + $($deletedUsers.Count) in recycle bin; group '$labGroupName' ($($labGroups.Count) active, $($deletedGroups.Count) in recycle bin); $($devices.Count) '$hostPrefix-*' device(s); TAP policy targets with a missing group"
Write-Step "  GitHub: $(if ($Repository) { "$Repository (runner $runnerName and $($repositoryVariables.Count) variables)" } else { 'skipped (no -Repository)' })"
Write-Step "  local credentials folder: $(if (Test-Path -LiteralPath $credentialsDirectory) { 'present' } else { 'not present' })"
if ($WhatIf) { Write-Step 'WhatIf: nothing was changed.'; return }

if (-not $Force) {
    $typed = Read-Host "This deletes the lab, its users and its state. Type the resource group name '$resourceGroup' to confirm"
    if ($typed -cne $resourceGroup) { throw 'Cancelled: the confirmation did not match.' }
}

# ---- Azure
foreach ($gallery in $galleries) {
    $definitions = @(Invoke-AzJson @('sig', 'image-definition', 'list', '--resource-group', $resourceGroup, '--gallery-name', $gallery.name) -AllowFailure)
    foreach ($definition in $definitions) {
        foreach ($version in @(Invoke-AzJson @('sig', 'image-version', 'list', '--resource-group', $resourceGroup, '--gallery-name', $gallery.name, '--gallery-image-definition', $definition.name) -AllowFailure)) {
            & az sig image-version delete --resource-group $resourceGroup --gallery-name $gallery.name --gallery-image-definition $definition.name --gallery-image-version $version.name --subscription $subscriptionId --only-show-errors 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Could not delete image version $($version.name)." }
            Write-Step "Deleted image version $($version.name)."
        }
    }
}
foreach ($target in $diagnosticTargets) {
    & az monitor diagnostic-settings delete --name $diagnosticSettingName --resource $target.id --subscription $subscriptionId --only-show-errors 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not delete the diagnostic setting on $($target.name)." }
    Write-Step "Cleared diagnostic setting on $($target.name)."
}
foreach ($workspace in $workspaces) {
    & az monitor log-analytics workspace delete --resource-group $resourceGroup --workspace-name $workspace.name --force true --yes --subscription $subscriptionId --only-show-errors 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not permanently delete the Log Analytics workspace $($workspace.name)." }
    Write-Step "Permanently deleted Log Analytics workspace $($workspace.name)."
}

$toDelete = @(@($resourceGroup | Where-Object { $groupExists }) + $studentGroups + $packerGroups)
foreach ($name in $toDelete) {
    & az group delete --name $name --yes --no-wait --subscription $subscriptionId --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Could not start deleting $name." }
}
if ($toDelete.Count -gt 0) { Wait-GroupsDeleted $toDelete; Write-Step "Deleted resource group(s): $($toDelete -join ', ')." }

$softDeleted = @(Invoke-AzJson @('keyvault', 'list-deleted'))
$vaultNames = @($vaults.name) + @($softDeleted | Where-Object { $_.name -like 'pkrkv*' } | ForEach-Object { $_.name })
foreach ($name in ($vaultNames | Where-Object { $_ } | Select-Object -Unique)) {
    $entry = @($softDeleted | Where-Object { $_.name -eq $name }) | Select-Object -First 1
    if (-not $entry) { Write-Step "Key Vault $name is not soft-deleted."; continue }
    & az keyvault purge --name $name --location $entry.properties.location --subscription $subscriptionId --only-show-errors 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Step "Purged Key Vault $name." }
    else { Write-Step "WARNING: Key Vault $name cannot be purged (purge protection); its name is held until $($entry.properties.scheduledPurgeDate)." }
}

if ($identityIds.Count -gt 0) {
    $assignments = @(Invoke-AzJson @('role', 'assignment', 'list', '--scope', "/subscriptions/$subscriptionId") | Where-Object { $_.scope -eq "/subscriptions/$subscriptionId" -and $_.principalId -in $identityIds })
    foreach ($assignment in $assignments) {
        & az role assignment delete --ids $assignment.id --subscription $subscriptionId --only-show-errors 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not delete role assignment $($assignment.id)." }
        Write-Step "Removed $($assignment.roleDefinitionName) role assignment for deleted identity $($assignment.principalId)."
    }
}

if ($stateExists -and -not $KeepState) {
    & az group delete --name $stateResourceGroup --yes --no-wait --subscription $subscriptionId --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Could not start deleting $stateResourceGroup." }
    Wait-GroupsDeleted @($stateResourceGroup)
    Write-Step "Deleted state resource group $stateResourceGroup."
}

# ---- Microsoft Entra
foreach ($user in $labUsers) { Remove-GraphObject 'users' $user.id "user $($user.displayName)" }
foreach ($group in $labGroups) { Remove-GraphObject 'groups' $group.id "group $($group.displayName)" }
foreach ($device in $devices) { Remove-GraphObject 'devices' $device.id "device $($device.displayName)" }
Start-Sleep -Seconds 5
$recycled = @(Invoke-Graph -Uri 'https://graph.microsoft.com/v1.0/directory/deletedItems/microsoft.graph.user?$select=id,displayName' | Where-Object { $_.displayName -match '^LabUser\d{3}$' }) +
            @(Invoke-Graph -Uri 'https://graph.microsoft.com/v1.0/directory/deletedItems/microsoft.graph.group?$select=id,displayName' | Where-Object { $_.displayName -eq $labGroupName })
foreach ($item in $recycled) { Remove-GraphObject 'directory/deletedItems' $item.id "recycle-bin item $($item.displayName)" }

try {
    $policy = Invoke-Graph -Uri $tapPolicyUrl
    $keep = @()
    foreach ($target in @($policy.includeTargets)) {
        $exists = $true
        if ($target.id -ne 'all_users') {
            try { Invoke-Graph -Uri "https://graph.microsoft.com/v1.0/groups/$($target.id)?`$select=id" | Out-Null }
            catch { if ($_.Exception.Response.StatusCode.value__ -eq 404) { $exists = $false } else { throw } }
        }
        if ($exists) { $keep += $target } else { Write-Step "Removing TAP policy target for deleted group $($target.id)." }
    }
    if ($keep.Count -ne @($policy.includeTargets).Count) {
        Invoke-Graph -Method PATCH -Uri $tapPolicyUrl -Body @{ '@odata.type' = $policy.'@odata.type'; includeTargets = @($keep) }
    }
} catch { Write-Step "WARNING: could not clean the TAP policy: $($_.Exception.Message)" }

# ---- GitHub
if ($Repository) {
    $runners = (& gh api "repos/$Repository/actions/runners" --jq '[.runners[] | {id, name}]' | Out-String | ConvertFrom-Json)
    foreach ($runner in @($runners | Where-Object { $_.name -eq $runnerName })) {
        & gh api -X DELETE "repos/$Repository/actions/runners/$($runner.id)"
        if ($LASTEXITCODE -ne 0) { throw "Could not remove runner $($runner.name) from $Repository." }
        Write-Step "Removed runner $($runner.name) from $Repository."
    }
    $existing = @(& gh variable list --repo $Repository --json name --jq '.[].name')
    foreach ($name in $repositoryVariables | Where-Object { $_ -in $existing }) {
        & gh variable delete $name --repo $Repository
        if ($LASTEXITCODE -ne 0) { throw "Could not delete repository variable $name." }
        Write-Step "Deleted repository variable $name."
    }
}

# ---- Local
if (Test-Path -LiteralPath $credentialsDirectory) { Remove-Item -LiteralPath $credentialsDirectory -Recurse -Force; Write-Step 'Deleted the local credentials folder.' }

# ---- Verification
Write-Step 'Verification:'
Write-Step "  lab / state resource group exist: $(Test-GroupExists $resourceGroup) / $(Test-GroupExists $stateResourceGroup)"
Write-Step "  LAB-* or pkr-* groups left: $(@(@(Invoke-AzJson @('group', 'list')) | Where-Object { $_.name -like 'LAB-*' -or $_.name -like 'pkr-immersionday-*' }).Count)"
Write-Step "  soft-deleted lab/Packer vaults left: $(@(@(Invoke-AzJson @('keyvault', 'list-deleted')) | Where-Object { $_.name -like 'kv-msftlabs-cus-*' -or $_.name -like 'pkrkv*' }).Count)"
Write-Step "  soft-deleted Log Analytics workspaces left: $(@(@(Invoke-AzJson @('monitor', 'log-analytics', 'workspace', 'list-deleted-workspaces') -AllowFailure) | Where-Object { $_.resourceGroup -ieq $resourceGroup }).Count)"
Write-Step "  LabUsers / lab group / devices left: $(@(Invoke-Graph -Uri "https://graph.microsoft.com/v1.0/users?`$filter=startswith(displayName,'LabUser')&`$select=id").Count) / $(@(Invoke-Graph -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$labGroupName'&`$select=id").Count) / $(@(Invoke-Graph -Uri "https://graph.microsoft.com/v1.0/devices?`$filter=startswith(displayName,'$hostPrefix-')&`$select=id").Count)"
Write-Step 'Reset complete.'
