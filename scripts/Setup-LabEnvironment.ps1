#Requires -Version 7.0
<#
.SYNOPSIS
    Guided end-to-end setup of the MSFTLabs Immersion Day environment.

.DESCRIPTION
    Stage ServicePrincipal: signs in with YOUR Azure CLI identity, creates (or reuses) the lab service principal and grants its Azure, Entra (Graph) and resource-provider prerequisites.
    Stage Phase1: runs OpenTofu init/plan, walks you through terraform.tfvars when it is not filled out, then applies the core infrastructure with lab users and hosts deferred.
    Stage Runner: waits for the in-VNet self-hosted GitHub runner VM to finish installing its tools, registers it with the repository and sets the repository variables used by the build-image workflow.
    Stage Image: validates the Packer template, then builds the image ON the runner (private networking, no public IP) and publishes a version to the Azure Compute Gallery.
    Stage Phase2: sizes the AVD hosts from the lab-user count, then applies users, TAPs and hosts.
    OpenTofu and Packer stay the source of truth; this script only prepares identities and calls them. OpenTofu and Packer run as the service principal in a temporary, isolated Azure CLI profile, so your own Azure CLI login is not changed.

.PARAMETER Stage
    All (default) runs every stage in order. Use a single stage to resume after a failure.

.PARAMETER Destroy
    Tears down everything OpenTofu manages for the lab (OpenTofu destroy) after a preview and a typed confirmation. Packer-published image versions are deleted first because the gallery cannot be removed while they exist. Other stages are not run.

.PARAMETER CleanupOnFailure
    By default a failed Packer image build KEEPS its temporary VM and resource group so you can troubleshoot it (the VM keeps running and incurs charges until you delete the group; the script logs the exact commands). Use this switch to have a failed build delete its temporary resources instead.

.NOTES
    Everything the script and the tools it calls print is also written live to .logs/setup.log at the repository root. Each line is a UTC timestamp, a tab, then the entry (tool output is tagged [tofu], [packer] or [az]). The log is appended across runs. Secrets are not logged.

.EXAMPLE
    ./scripts/Setup-LabEnvironment.ps1

.EXAMPLE
    ./scripts/Setup-LabEnvironment.ps1 -Destroy
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'ServicePrincipal', 'Phase1', 'Runner', 'Image', 'Phase2')]
    [string]$Stage = 'All',
    [string]$ServicePrincipalName = 'sp-msftlabs-immersion-day',
    [string]$TenantId,
    [string]$SubscriptionId,
    [string]$ImageVersion,
    [string]$ImageSku,
    [string]$VmSize = 'Standard_D4s_v5',
    [string]$OpenTofuCommand = 'tofu',
    [string]$PackerCommand = 'packer',
    [switch]$Destroy,
    [switch]$CleanupOnFailure
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Set-StrictMode -Version Latest

$script:RepositoryRoot = Split-Path $PSScriptRoot -Parent
$script:InfraDirectory = Join-Path $script:RepositoryRoot 'infra'
$script:TfVarsPath = Join-Path $script:InfraDirectory 'terraform.tfvars'
$script:PackerDirectory = Join-Path $script:RepositoryRoot 'packer/windows11'
$script:SecretVarsPath = Join-Path $script:InfraDirectory 'zz-lab-phase2.auto.tfvars.json'
$script:LogDirectory = Join-Path $script:RepositoryRoot '.logs'
$script:LogPath = Join-Path $script:LogDirectory 'setup.log'
$script:LogWriter = $null
$script:PlanFiles = @('labbuild.plan', 'labphase1.plan', 'labphase2.plan', 'labdestroy.plan')
$script:NativeOutput = [Collections.Generic.List[string]]::new()
$script:OriginalConfigDir = $env:AZURE_CONFIG_DIR
$script:IsolatedConfig = $null
$script:OriginalArm = @{}
foreach ($name in 'ARM_CLIENT_ID', 'ARM_CLIENT_SECRET', 'ARM_TENANT_ID', 'ARM_SUBSCRIPTION_ID') { $script:OriginalArm[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
$script:Tenant = $null
$script:Subscription = $null
$script:PublishedImageVersion = $ImageVersion
$script:GraphAppId = '00000003-0000-0000-c000-000000000000'
$script:GraphRoles = [ordered]@{
    'User.ReadWrite.All'                     = '741f803b-c850-494e-b5df-cde7c675a1ca'
    'Group.ReadWrite.All'                    = '62a82d76-70ea-41e2-9197-370581804d09'
    'Domain.Read.All'                        = 'dbb9058a-0e50-45d7-ae91-66909b5d4664'
    'Application.Read.All'                   = '9a5d68dd-52b0-4cc2-bd40-abcf44ac3a30'
    'Policy.Read.All'                        = '246dd0d5-5bd0-4def-940b-0421030a5b68'
    'Policy.ReadWrite.AuthenticationMethod'  = '29c18626-4985-4dcd-85c0-193eef327366'
    'UserAuthenticationMethod.ReadWrite.All' = '50483e42-d915-4231-9639-7fdb7fd190e5'
}
$script:ResourceProviders = @('Microsoft.Compute', 'Microsoft.Network', 'Microsoft.KeyVault', 'Microsoft.DesktopVirtualization', 'Microsoft.Storage', 'Microsoft.OperationalInsights', 'Microsoft.Insights')

## Logging

function Initialize-Log {
    try {
        New-Item -ItemType Directory -Path $script:LogDirectory -Force | Out-Null
        $stream = [IO.FileStream]::new($script:LogPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        $script:LogWriter = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
        $script:LogWriter.AutoFlush = $true
    } catch {
        $script:LogWriter = $null
        Write-Host "WARNING: could not open the log file $($script:LogPath): $($_.Exception.Message)"
    }
}

function Close-Log {
    if ($script:LogWriter) {
        $script:LogWriter.Dispose()
        $script:LogWriter = $null
    }
}

## ANSI codes are stripped so the log stays plain text.
function Write-Log {
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Message = '',
        [string]$Source,
        [switch]$Quiet
    )
    $prefix = if ($Source) { "[$Source] " } else { '' }
    foreach ($line in @($Message -split '\r?\n')) {
        $text = [regex]::Replace($line, '\x1B\[[0-9;?]*[ -/]*[@-~]', '')
        if (-not $Quiet) { Write-Host $text }
        if ($script:LogWriter) {
            $stamp = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
            $script:LogWriter.WriteLine("$stamp`t$prefix$text")
        }
    }
}

function Read-HostLogged {
    param([string]$Prompt)
    $answer = Read-Host $Prompt
    Write-Log "PROMPT $Prompt => $answer" -Quiet
    return $answer
}

## Streams line by line so long builds show progress and land in the log as they run.
function Invoke-Native {
    param([string]$Source, [string]$FilePath, [string[]]$Arguments)
    Write-Log "$([IO.Path]::GetFileName($FilePath)) $($Arguments -join ' ')" -Source $Source
    $script:NativeOutput = [Collections.Generic.List[string]]::new()
    & $FilePath @Arguments 2>&1 | ForEach-Object {
        $line = [string]$_
        $script:NativeOutput.Add($line)
        Write-Log $line -Source $Source
    }
    $code = $LASTEXITCODE
    Write-Log "exit code $code" -Source $Source
    return $code
}

## Generic helpers
function Read-Default {
    param([string]$Prompt, [string]$Default)
    $suffix = if ($Default) { " [$Default]" } else { '' }
    $answer = Read-HostLogged "$Prompt$suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

function Confirm-Action {
    param([string]$Prompt, [bool]$DefaultYes = $true)
    $hint = if ($DefaultYes) { 'Y/n' } else { 'y/N' }
    $answer = Read-HostLogged "$Prompt [$hint]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $DefaultYes }
    return $answer.Trim() -match '^(?i)y(es)?$'
}

function Invoke-Az {
    param([string[]]$Arguments, [switch]$Json, [switch]$AllowFailure)
    $errorFile = [IO.Path]::GetTempFileName()
    try {
        $output = & az @Arguments --only-show-errors 2>$errorFile
        $code = $LASTEXITCODE
        $errorText = (Get-Content -LiteralPath $errorFile -Raw -ErrorAction SilentlyContinue)
    } finally {
        Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    }
    Write-Log "az $($Arguments[0]) $($Arguments[1]) -> exit code $code" -Source az -Quiet
    if ($code -ne 0) {
        if ($AllowFailure) { return $null }
        throw "Azure CLI command 'az $($Arguments[0]) $($Arguments[1])' failed: $("$errorText".Trim())"
    }
    $text = ($output | Out-String).Trim()
    if (-not $text) { return $null }
    if ($Json) { return ($text | ConvertFrom-Json) }
    return $text
}

function Invoke-OpenTofu {
    param([string[]]$Arguments)
    $full = @("-chdir=$script:InfraDirectory", $Arguments[0], '-no-color')
    if ($Arguments.Count -gt 1) { $full += $Arguments[1..($Arguments.Count - 1)] }
    $code = Invoke-Native -Source 'tofu' -FilePath $OpenTofuCommand -Arguments $full
    if ($code -ne 0) { throw "OpenTofu '$($Arguments[0])' failed with exit code $code. See $script:LogPath for the full output." }
}

function Get-OpenTofuOutput {
    param([string]$Name)
    $text = (& $OpenTofuCommand "-chdir=$script:InfraDirectory" output -json $Name | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "Could not read the OpenTofu output '$Name'. Apply the core infrastructure first." }
    Write-Log "output $Name = $($text.Trim() -replace '\s+', ' ')" -Source tofu -Quiet
    return ($text | ConvertFrom-Json)
}

function Invoke-Stage {
    param([string]$Name, [scriptblock]$Action)
    while ($true) {
        try {
            Write-Log ''
            Write-Log "=== $Name ==="
            & $Action
            Write-Log "$Name finished."
            return
        } catch {
            Write-Log "ERROR during ${Name}: $($_.Exception.Message)"
            Write-Log "$($_.ScriptStackTrace)" -Quiet
            $choice = Read-HostLogged 'Fix the cause, then [R]etry this step or [A]bort (default: Abort)'
            if ($choice -notmatch '^(?i)r') { throw }
        }
    }
}

function Protect-SecretFile {
    param([string]$Path)
    if ($IsWindows) {
        $acl = Get-Acl -LiteralPath $Path
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($acl.Access)) { $acl.RemoveAccessRuleSpecific($rule) }
        foreach ($principal in @([Security.Principal.WindowsIdentity]::GetCurrent().User, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($principal, 'FullControl', 'Allow'))
        }
        Set-Acl -LiteralPath $Path -AclObject $acl
    } else {
        [IO.File]::SetUnixFileMode($Path, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
    }
}

function New-RandomPassword {
    return 'Aa1!' + [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(14))
}

## terraform.tfvars helpers used to populate values
function Get-TfVar {
    param([string]$Name)
    if (-not (Test-Path -LiteralPath $script:TfVarsPath)) { return $null }
    $pattern = "(?m)^$([regex]::Escape($Name))[ \t]*=[ \t]*(?<value>[^\r\n]*?)[ \t]*\r?$"
    $match = [regex]::Match((Get-Content -LiteralPath $script:TfVarsPath -Raw), $pattern)
    if (-not $match.Success -or $match.Groups['value'].Value -eq 'null') { return $null }
    return $match.Groups['value'].Value.Trim('"')
}

function Set-TfVar {
    param([string]$Name, $Value)
    if ($Value -is [string] -and $Value -match '["\\\r\n]') { throw "The value for $Name contains characters that are not allowed." }
    $text = if ($null -eq $Value) { 'null' } elseif ($Value -is [string]) { '"' + $Value + '"' } else { [string]$Value }
    $content = Get-Content -LiteralPath $script:TfVarsPath -Raw
    $pattern = "(?m)^($([regex]::Escape($Name))[ \t]*=[ \t]*)[^\r\n]*"
    if ([regex]::IsMatch($content, $pattern)) {
        $content = [regex]::Replace($content, $pattern, { param($match) $match.Groups[1].Value + $text })
    } else {
        $content = $content.TrimEnd() + [Environment]::NewLine + "$Name = $text" + [Environment]::NewLine
    }
    [IO.File]::WriteAllText($script:TfVarsPath, $content, [Text.UTF8Encoding]::new($false))
}

function Test-Guid {
    param([string]$Value)
    $parsed = [guid]::Empty
    return (-not [string]::IsNullOrWhiteSpace($Value)) -and [guid]::TryParse($Value, [ref]$parsed)
}

## Prerequisites and identity stage
function Test-Prerequisites {
    $tools = @('az', $OpenTofuCommand)
    if (-not $Destroy) { $tools += $PackerCommand }
    foreach ($tool in $tools) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "'$tool' was not found on PATH. Install it with WinGet (see the README section 'Install the Tools with WinGet': Microsoft.AzureCLI, OpenTofu.Tofu, Hashicorp.Packer) and reopen the terminal." }
    }
    $packerVersion = if ($Destroy) { 'Packer not required' } else { (& $PackerCommand version | Select-Object -First 1) }
    Write-Log "PowerShell $($PSVersionTable.PSVersion); $((& $OpenTofuCommand version | Select-Object -First 1)); $packerVersion"
}

function Connect-UserIdentity {
    $env:AZURE_CONFIG_DIR = $script:OriginalConfigDir
    if (-not $script:OriginalConfigDir) { Remove-Item Env:AZURE_CONFIG_DIR -ErrorAction SilentlyContinue }
    $account = Invoke-Az @('account', 'show') -Json -AllowFailure
    if ($account -and $account.user.type -eq 'servicePrincipal') { throw 'Azure CLI is signed in as a service principal. Run this stage as yourself: az logout, then rerun the script.' }
    if (-not $account -or ($TenantId -and $account.tenantId -ne $TenantId)) {
        Write-Log 'Signing in to Azure with your own identity (a browser window opens).'
        $loginArguments = @('login', '--only-show-errors', '--output', 'none')
        if ($TenantId) { $loginArguments += @('--tenant', $TenantId) }
        & az @loginArguments
        if ($LASTEXITCODE -ne 0) { throw 'Azure CLI sign-in failed.' }
        $account = Invoke-Az @('account', 'show') -Json
    }
    $tenantDefault = if ($TenantId) { $TenantId } elseif (Test-Guid (Get-TfVar 'tenant_id')) { Get-TfVar 'tenant_id' } else { $account.tenantId }
    $subscriptionDefault = if ($SubscriptionId) { $SubscriptionId } elseif (Test-Guid (Get-TfVar 'subscription_id')) { Get-TfVar 'subscription_id' } else { $account.id }
    $script:Tenant = Read-Default 'Tenant ID' $tenantDefault
    $script:Subscription = Read-Default 'Subscription ID' $subscriptionDefault
    if (-not (Test-Guid $script:Tenant) -or -not (Test-Guid $script:Subscription)) { throw 'Tenant and subscription must be GUIDs.' }
    Invoke-Az @('account', 'set', '--subscription', $script:Subscription) | Out-Null
    $account = Invoke-Az @('account', 'show') -Json
    if ($account.tenantId -ne $script:Tenant) { throw "Subscription $($script:Subscription) belongs to tenant $($account.tenantId), not $($script:Tenant). Sign in to that tenant with az login --tenant." }
    Write-Log "Signed in as $($account.user.name); subscription $($account.name) ($($account.id))."
}

function Test-UserPermissions {
    $warnings = [Collections.Generic.List[string]]::new()
    $roles = @(Invoke-Az @('rest', '--method', 'GET', '--url', 'https://graph.microsoft.com/v1.0/me/transitiveMemberOf/microsoft.graph.directoryRole?$select=displayName', '--query', 'value[].displayName', '--output', 'tsv') -AllowFailure | ForEach-Object { $_ -split "`n" } | Where-Object { $_ })
    $hasEntra = $roles -contains 'Global Administrator' -or (($roles -contains 'Privileged Role Administrator') -and ($roles -contains 'Application Administrator' -or $roles -contains 'Cloud Application Administrator'))
    if (-not $hasEntra) { $warnings.Add('Entra: you need Global Administrator, or Privileged Role Administrator plus Application (or Cloud Application) Administrator, to create the app and grant Graph roles.') }
    $userId = Invoke-Az @('ad', 'signed-in-user', 'show', '--query', 'id', '--output', 'tsv') -AllowFailure
    $azureRoles = @()
    if ($userId) {
        $azureRoles = @(Invoke-Az @('role', 'assignment', 'list', '--assignee', $userId, '--include-inherited', '--include-groups', '--subscription', $script:Subscription, '--query', '[].roleDefinitionName', '--output', 'tsv') -AllowFailure | ForEach-Object { $_ -split "`n" } | Where-Object { $_ })
    }
    $hasAzure = $azureRoles -contains 'Owner' -or (($azureRoles -contains 'User Access Administrator' -or $azureRoles -contains 'Role Based Access Control Administrator') -and $azureRoles -contains 'Contributor')
    if (-not $hasAzure) { $warnings.Add('Azure: you need Owner (or Contributor plus User Access Administrator) on the subscription to assign roles and register resource providers.') }
    if ($warnings.Count -eq 0) { Write-Log 'Your Entra and Azure permissions satisfy the prerequisites.'; return }
    foreach ($warning in $warnings) { Write-Log "WARNING: $warning" }
    if (-not (Confirm-Action 'Some checks could not be confirmed (PIM-eligible roles are not detected). Continue anyway?' $false)) { throw 'Stopped: activate or request the required roles, then rerun.' }
}

function Get-ServicePrincipalDetails {
    $apps = @(Invoke-Az @('ad', 'app', 'list', '--display-name', $ServicePrincipalName, '--query', "[?displayName=='$ServicePrincipalName'].appId", '--output', 'tsv') | ForEach-Object { $_ -split "`n" } | Where-Object { $_ })
    if ($apps.Count -gt 1) { throw "More than one app registration is named '$ServicePrincipalName'. Remove the duplicates or pass a different -ServicePrincipalName." }
    if ($apps.Count -eq 0) {
        Write-Log "Creating app registration '$ServicePrincipalName'."
        $appId = Invoke-Az @('ad', 'app', 'create', '--display-name', $ServicePrincipalName, '--sign-in-audience', 'AzureADMyOrg', '--query', 'appId', '--output', 'tsv')
    } else {
        $appId = $apps[0]
        Write-Log "Reusing app registration '$ServicePrincipalName' ($appId)."
    }
    $objectId = Invoke-Az @('ad', 'sp', 'list', '--filter', "appId eq '$appId'", '--query', '[0].id', '--output', 'tsv')
    if (-not $objectId) {
        Write-Log 'Creating the service principal.'
        $objectId = Invoke-Az @('ad', 'sp', 'create', '--id', $appId, '--query', 'id', '--output', 'tsv')
    }
    return @{ AppId = $appId; ObjectId = $objectId }
}

function Test-ServicePrincipalSecret {
    param([string]$AppId, [string]$Secret)
    $probe = Join-Path ([IO.Path]::GetTempPath()) ('azcfg-probe-' + [guid]::NewGuid().ToString('N'))
    $previous = $env:AZURE_CONFIG_DIR
    try {
        $env:AZURE_CONFIG_DIR = $probe
        & az login --service-principal --username $AppId --password $Secret --tenant $script:Tenant --only-show-errors --output none 2>$null
        return ($LASTEXITCODE -eq 0)
    } finally {
        $env:AZURE_CONFIG_DIR = $previous
        if (-not $previous) { Remove-Item Env:AZURE_CONFIG_DIR -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Set-ServicePrincipalCredential {
    param([string]$AppId)
    $secret = $null
    $existingId = [Environment]::GetEnvironmentVariable('ARM_CLIENT_ID', 'Process')
    $existingSecret = [Environment]::GetEnvironmentVariable('ARM_CLIENT_SECRET', 'Process')
    if ($existingId -ne $AppId -or -not $existingSecret) {
        $existingId = [Environment]::GetEnvironmentVariable('ARM_CLIENT_ID', 'User')
        $existingSecret = [Environment]::GetEnvironmentVariable('ARM_CLIENT_SECRET', 'User')
    }
    if ($existingId -eq $AppId -and $existingSecret) {
        if (Test-ServicePrincipalSecret -AppId $AppId -Secret $existingSecret) {
            if (Confirm-Action 'A working client secret for this service principal is already stored in your user environment. Reuse it?') { $secret = $existingSecret }
        } else {
            Write-Log 'The stored client secret no longer works; a new one will be created.'
        }
    }
    if (-not $secret) {
        Write-Log 'Creating a new client secret (valid 1 year, existing secrets are kept).'
        $secret = Invoke-Az @('ad', 'app', 'credential', 'reset', '--id', $AppId, '--append', '--display-name', "lab-setup-$(Get-Date -Format 'yyyyMMdd')", '--years', '1', '--query', 'password', '--output', 'tsv')
    }
    $env:ARM_CLIENT_ID = $AppId
    $env:ARM_CLIENT_SECRET = $secret
    $env:ARM_TENANT_ID = $script:Tenant
    $env:ARM_SUBSCRIPTION_ID = $script:Subscription
    $persist = $false
    if ($existingId -and $existingId -ne $AppId) {
        $persist = Confirm-Action "Your user environment already points ARM_CLIENT_ID at a different identity ($existingId). Replace it with '$ServicePrincipalName'?" $false
    } else {
        $persist = Confirm-Action 'Store ARM_CLIENT_ID, ARM_CLIENT_SECRET, ARM_TENANT_ID and ARM_SUBSCRIPTION_ID in your user environment for later manual OpenTofu runs? The secret is stored unencrypted in your profile.' $false
    }
    if ($persist) {
        foreach ($name in 'ARM_CLIENT_ID', 'ARM_CLIENT_SECRET', 'ARM_TENANT_ID', 'ARM_SUBSCRIPTION_ID') {
            [Environment]::SetEnvironmentVariable($name, [Environment]::GetEnvironmentVariable($name, 'Process'), 'User')
        }
        Write-Log 'ARM_* variables saved to your user environment; new terminals will see them.'
    } else {
        Write-Log 'The secret exists only in this run; rerunning later creates a new one.'
    }
}

function Grant-ServicePrincipalAccess {
    param([hashtable]$Details)
    $scope = "/subscriptions/$script:Subscription"
    $owner = Invoke-Az @('role', 'assignment', 'list', '--assignee', $Details.ObjectId, '--scope', $scope, '--include-inherited', '--query', "[?roleDefinitionName=='Owner'] | length(@)", '--output', 'tsv')
    if ([int]$owner -gt 0) {
        Write-Log 'Azure: Owner is already assigned at the subscription (or above).'
    } else {
        Invoke-Az @('role', 'assignment', 'create', '--assignee-object-id', $Details.ObjectId, '--assignee-principal-type', 'ServicePrincipal', '--role', 'Owner', '--scope', $scope) | Out-Null
        Write-Log "Azure: assigned Owner on $scope."
    }

    $graphPermissions = @($script:GraphRoles.Values | ForEach-Object { "$_=Role" })
    Invoke-Az @(@('ad', 'app', 'permission', 'add', '--id', $Details.AppId, '--api', $script:GraphAppId, '--api-permissions') + $graphPermissions) | Out-Null
    $graphObjectId = Invoke-Az @('ad', 'sp', 'show', '--id', $script:GraphAppId, '--query', 'id', '--output', 'tsv')
    $assignmentsUrl = "https://graph.microsoft.com/v1.0/servicePrincipals/$($Details.ObjectId)/appRoleAssignments"
    $existing = @(Invoke-Az @('rest', '--method', 'GET', '--url', $assignmentsUrl, '--query', 'value[].appRoleId', '--output', 'tsv') -AllowFailure | ForEach-Object { $_ -split "`n" } | Where-Object { $_ })
    foreach ($entry in $script:GraphRoles.GetEnumerator()) {
        if ($existing -contains $entry.Value) { Write-Log "Graph: $($entry.Key) already granted."; continue }
        $bodyFile = [IO.Path]::GetTempFileName()
        try {
            @{ principalId = $Details.ObjectId; resourceId = $graphObjectId; appRoleId = $entry.Value } | ConvertTo-Json -Compress | Set-Content -LiteralPath $bodyFile -Encoding utf8NoBOM
            Invoke-Az @('rest', '--method', 'POST', '--url', $assignmentsUrl, '--headers', 'Content-Type=application/json', '--body', "@$bodyFile") | Out-Null
            Write-Log "Graph: granted $($entry.Key)."
        } finally {
            Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Log 'Entra: the service principal uses the Graph application roles above; no directory role is assigned.'

    foreach ($namespace in $script:ResourceProviders) {
        $state = Invoke-Az @('provider', 'show', '--namespace', $namespace, '--query', 'registrationState', '--output', 'tsv') -AllowFailure
        if ($state -eq 'Registered') { continue }
        Write-Log "Registering resource provider $namespace (can take a minute)."
        Invoke-Az @('provider', 'register', '--namespace', $namespace, '--wait') | Out-Null
    }
    Write-Log 'Azure: required resource providers are registered.'
}

function Connect-ServicePrincipalSession {
    foreach ($name in 'ARM_CLIENT_ID', 'ARM_CLIENT_SECRET', 'ARM_TENANT_ID', 'ARM_SUBSCRIPTION_ID') {
        if (-not [Environment]::GetEnvironmentVariable($name, 'Process')) {
            $userValue = [Environment]::GetEnvironmentVariable($name, 'User')
            if (-not $userValue) { throw "$name is not set. Run the ServicePrincipal stage first (-Stage ServicePrincipal)." }
            [Environment]::SetEnvironmentVariable($name, $userValue, 'Process')
        }
    }
    if ($script:IsolatedConfig -and (Test-Path -LiteralPath $script:IsolatedConfig)) { Remove-Item -LiteralPath $script:IsolatedConfig -Recurse -Force -ErrorAction SilentlyContinue }
    $script:IsolatedConfig = Join-Path ([IO.Path]::GetTempPath()) ('azcfg-lab-' + [guid]::NewGuid().ToString('N'))
    $env:AZURE_CONFIG_DIR = $script:IsolatedConfig
    & az login --service-principal --username $env:ARM_CLIENT_ID --password $env:ARM_CLIENT_SECRET --tenant $env:ARM_TENANT_ID --only-show-errors --output none
    if ($LASTEXITCODE -ne 0) { throw 'Service principal sign-in failed. A brand-new secret can take a short time to become usable.' }
    Invoke-Az @('account', 'set', '--subscription', $env:ARM_SUBSCRIPTION_ID) | Out-Null
}

function Get-GraphTokenRole {
    $token = Invoke-Az @('account', 'get-access-token', '--resource', 'https://graph.microsoft.com', '--query', 'accessToken', '--output', 'tsv')
    $payload = $token.Split('.')[1].Replace('-', '+').Replace('_', '/')
    $token = $null
    while ($payload.Length % 4) { $payload += '=' }
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
    $property = $claims.PSObject.Properties['roles']
    if ($null -eq $property) { return @() }
    return @($property.Value)
}

function Wait-ForGraphRole {
    $attempt = 0
    while ($true) {
        $attempt++
        Connect-ServicePrincipalSession
        $granted = Get-GraphTokenRole
        $missing = @($script:GraphRoles.Keys | Where-Object { $_ -notin $granted })
        if ($missing.Count -eq 0) { Write-Log 'Service principal sign-in works and its Graph token carries every required role.'; return }
        if ($attempt -ge 3) { throw "Graph roles are not yet in the token: $($missing -join ', '). Wait a few minutes and rerun with -Stage Phase1." }
        Write-Log "Graph roles still propagating ($($missing.Count) missing). Waiting 20 seconds before attempt $($attempt + 1) of 3."
        Start-Sleep -Seconds 20
    }
}

function Step-ServicePrincipal {
    Connect-UserIdentity
    Test-UserPermissions
    $details = Get-ServicePrincipalDetails
    Set-ServicePrincipalCredential -AppId $details.AppId
    Grant-ServicePrincipalAccess -Details $details
    Wait-ForGraphRole
}

## Phase 1 core infrastructure stage

function Test-TfVarsNeedInput {
    if (-not (Test-Path -LiteralPath $script:TfVarsPath)) { return $true }
    if (-not (Test-Guid (Get-TfVar 'subscription_id')) -or -not (Test-Guid (Get-TfVar 'tenant_id'))) { return $true }
    foreach ($name in 'resource_group_name', 'location', 'owner') { if (-not (Get-TfVar $name)) { return $true } }
    $users = Get-TfVar 'num_of_labusers'
    return (-not $users) -or ([int]$users -le 0)
}

function Update-TfVarsInteractive {
    if (-not (Test-Path -LiteralPath $script:TfVarsPath)) { throw "$script:TfVarsPath is missing. Restore it from source control; it also holds the network, gallery and AVD settings." }
    Write-Log 'terraform.tfvars needs input (for example num_of_labusers is 0). Press Enter to keep the value shown in brackets.'
    Set-TfVar 'tenant_id' $env:ARM_TENANT_ID
    Set-TfVar 'subscription_id' $env:ARM_SUBSCRIPTION_ID
    Write-Log "tenant_id and subscription_id were set from your sign-in ($env:ARM_TENANT_ID / $env:ARM_SUBSCRIPTION_ID)."
    foreach ($field in @(@('resource_group_name', 'Shared resource group name'), @('location', 'Azure region (for example CentralUS)'), @('owner', 'Owner tag value'))) {
        $value = Read-Default $field[1] (Get-TfVar $field[0])
        if ([string]::IsNullOrWhiteSpace($value)) { throw "$($field[0]) is required." }
        Set-TfVar $field[0] $value
    }
    $users = 0
    while ($true) {
        $answer = Read-Default 'Total number of lab users (1-999)' (Get-TfVar 'num_of_labusers')
        if ([int]::TryParse($answer, [ref]$users) -and $users -ge 1 -and $users -le 999) { break }
        Write-Log 'Enter a whole number from 1 to 999.'
    }
    Set-TfVar 'num_of_labusers' $users
    Write-Log 'terraform.tfvars updated. Network, gallery, monitoring and AVD settings were left as they are; edit them in the file if needed.'
}

function Remove-PlanFile {
    foreach ($plan in $script:PlanFiles) { Remove-Item -LiteralPath (Join-Path $script:InfraDirectory $plan) -Force -ErrorAction SilentlyContinue }
}

function Step-Phase1 {
    Invoke-OpenTofu @('init', '-input=false')
    if (Test-TfVarsNeedInput) {
        Update-TfVarsInteractive
    } else {
        Write-Log "terraform.tfvars is filled out: $(Get-TfVar 'num_of_labusers') lab users in $(Get-TfVar 'location'), resource group $(Get-TfVar 'resource_group_name')."
        if (-not (Confirm-Action 'Use these values?')) { Update-TfVarsInteractive }
    }
    Write-Log 'Planning the full configuration (labbuild.plan) to validate it before anything is applied.'
    Invoke-OpenTofu @('plan', '-input=false', '-out=labbuild.plan')

    $state = @(& $OpenTofuCommand "-chdir=$script:InfraDirectory" state list -no-color 2>$null)
    $hasUsersOrHosts = @($state | Where-Object { $_ -match '^azuread_user\.lab|^azurerm_windows_virtual_machine\.' }).Count -gt 0
    if ($hasUsersOrHosts) {
        Write-Log 'Lab users or hosts already exist in state; Phase 1 would otherwise remove them, so it is skipped. Continue with the Image and Phase2 stages.'
        return
    }
    Write-Log 'Phase 1 deploys the core infrastructure only (network, gallery, AVD control plane, vault, monitoring). Lab users and hosts are deferred so their one-time passes do not expire during the image build.'
    Invoke-OpenTofu @('plan', '-input=false', '-var', 'num_of_labusers=0', '-var', 'avd_session_host_count=0', '-out=labphase1.plan')
    if (-not (Confirm-Action 'Apply the Phase 1 plan above?')) { throw 'Phase 1 apply was declined.' }
    Invoke-OpenTofu @('apply', '-input=false', 'labphase1.plan')
}

## Image stage

function Get-ChangelogVersion {
    $path = Join-Path $script:PackerDirectory '../CHANGELOG.md'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $match = [regex]::Match((Get-Content -LiteralPath $path -Raw), '(?m)^## \[(?<v>[0-9]+\.[0-9]+\.[0-9]+)\]')
    if ($match.Success) { return $match.Groups['v'].Value }
    return $null
}

function Get-GalleryVersion {
    param($Configuration)
    $versions = Invoke-Az @('sig', 'image-version', 'list', '--resource-group', $Configuration.gallery_resource_group, '--gallery-name', $Configuration.gallery_name, '--gallery-image-definition', $Configuration.image_definition_name, '--query', "[?provisioningState=='Succeeded'].name", '--output', 'tsv') -AllowFailure
    return @($versions -split "`n" | Where-Object { $_ -match '^[0-9]+\.[0-9]+\.[0-9]+$' } | Sort-Object { [version]$_ })
}

function Invoke-RunnerShell {
    param($Runner, [string]$Script, [switch]$AllowFailure)
    $file = Join-Path ([IO.Path]::GetTempPath()) ("runner-" + [guid]::NewGuid().ToString('N') + '.sh')
    try {
        [IO.File]::WriteAllText($file, ($Script -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
        $result = Invoke-Az @('vm', 'run-command', 'invoke', '--resource-group', $Runner.resource_group_name, '--name', $Runner.name, '--command-id', 'RunShellScript', '--scripts', "@$file") -Json -AllowFailure:$AllowFailure
    } finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
    if (-not $result) { return $null }
    return [string]$result.value[0].message
}

function Get-GitHubRunnerState {
    param($Runner)
    $text = (& gh api "repos/$($Runner.github_repository)/actions/runners" --jq ".runners[] | select(.name==`"$($Runner.name)`") | .status" 2>$null | Out-String).Trim()
    return $text
}

function Step-Runner {
    $runner = Get-OpenTofuOutput 'runner_configuration'
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'The GitHub CLI (gh) is required to register the runner. Install it with: winget install --id GitHub.cli --exact' }
    Write-Log "Waiting for the runner VM $($runner.name) to finish installing its tools (cloud-init)."
    $deadline = (Get-Date).AddMinutes(25)
    while ($true) {
        $state = Invoke-RunnerShell -Runner $runner -AllowFailure -Script 'if [ -f /opt/runner-bootstrap.done ]; then echo DONE; elif [ -f /opt/runner-bootstrap.failed ]; then echo FAILED; tail -n 40 /var/log/runner-bootstrap.log; else echo PENDING; fi'
        if ($state -match 'DONE') { break }
        if ($state -match 'FAILED') { throw "Runner bootstrap failed:`n$state" }
        if ((Get-Date) -gt $deadline) { throw 'The runner did not finish its bootstrap within 25 minutes.' }
        Write-Log 'Runner bootstrap still running...'
        Start-Sleep -Seconds 30
    }
    Write-Log (Invoke-RunnerShell -Runner $runner -Script 'cat /opt/runner-tools.txt')

    if ((Get-GitHubRunnerState -Runner $runner) -eq 'online') {
        Write-Log "Runner $($runner.name) is already registered and online."
    } else {
        Write-Log "Registering the runner with $($runner.github_repository)."
        $token = (& gh api -X POST "repos/$($runner.github_repository)/actions/runners/registration-token" --jq .token | Out-String).Trim()
        if (-not $token) { throw 'Could not create a runner registration token. gh needs admin rights on the repository.' }
        $labels = ($runner.labels | Where-Object { $_ -notin @('self-hosted', 'linux') }) -join ','
        $registerScript = @"
set -e
cd /opt/actions-runner
if [ -f .runner ]; then ./svc.sh stop || true; ./svc.sh uninstall || true; sudo -u $($runner.admin_username) ./config.sh remove --token '$token' || true; fi
sudo -u $($runner.admin_username) ./config.sh --unattended --replace --url 'https://github.com/$($runner.github_repository)' --token '$token' --name '$($runner.name)' --labels '$labels' --work /opt/actions-runner/_work
./svc.sh install $($runner.admin_username)
./svc.sh start
"@
        $registerOutput = Invoke-RunnerShell -Runner $runner -Script $registerScript
        Write-Log ($registerOutput -replace [regex]::Escape($token), '***')
        $deadline = (Get-Date).AddMinutes(3)
        while ((Get-GitHubRunnerState -Runner $runner) -ne 'online') {
            if ((Get-Date) -gt $deadline) { throw 'The runner registered but is not online in GitHub after 3 minutes.' }
            Start-Sleep -Seconds 10
        }
    }
    Write-Log "Runner $($runner.name) is online in GitHub with labels: $($runner.labels -join ', ')."

    $configuration = Get-OpenTofuOutput 'packer_configuration'
    $variables = [ordered]@{
        AZURE_SUBSCRIPTION_ID  = $configuration.subscription_id
        AZURE_TENANT_ID        = $configuration.tenant_id
        AZURE_LOCATION         = $configuration.location
        GALLERY_RESOURCE_GROUP = $configuration.gallery_resource_group
        GALLERY_NAME           = $configuration.gallery_name
        IMAGE_DEFINITION_NAME  = $configuration.image_definition_name
        REPLICATION_REGIONS    = ($configuration.replication_regions | ConvertTo-Json -Compress)
        VNET_NAME              = $configuration.virtual_network_name
        VNET_RESOURCE_GROUP    = $configuration.virtual_network_resource_group_name
        VNET_SUBNET_NAME       = $configuration.virtual_network_subnet_name
        RESOURCE_TAGS          = ($configuration.tags | ConvertTo-Json -Compress)
    }
    foreach ($entry in $variables.GetEnumerator()) {
        & gh variable set $entry.Key --repo $runner.github_repository --body ([string]$entry.Value) | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not set the GitHub repository variable $($entry.Key)." }
    }
    Write-Log 'Repository variables for the build-image workflow were set (non-secret values only).'
}


function Invoke-ImageBuild {
    param($Configuration, [string]$Version)
    $packerText = (& $PackerCommand version | Out-String)
    if ($packerText -notmatch 'Packer v(?<Version>[0-9.]+)' -or [version]$Matches.Version -lt [version]'1.16.1') {
        throw 'Packer 1.16.1 or newer is required. Run: winget upgrade --id Hashicorp.Packer --exact --source winget. If packer version still shows an older release, another copy (for example Chocolatey) is earlier on PATH; see the README WinGet section.'
    }
    foreach ($field in @('subscription_id', 'tenant_id', 'location', 'gallery_resource_group', 'gallery_name', 'image_definition_name', 'replication_regions', 'tags', 'virtual_network_name', 'virtual_network_resource_group_name', 'virtual_network_subnet_name')) {
        if ($null -eq $Configuration.PSObject.Properties[$field]) { throw "The packer_configuration output is missing $field. Apply the infrastructure again (Phase1)." }
    }
    $runner = Get-OpenTofuOutput 'runner_configuration'
    if ((Get-GitHubRunnerState -Runner $runner) -ne 'online') { throw 'The self-hosted runner is not online. Run -Stage Runner first.' }
    Write-Log "Packer runs on the in-VNet runner $($runner.name); the build VM gets a private IP in subnet $($Configuration.virtual_network_subnet_name) and WinRM (HTTP 5985) never leaves the VNet."

    $account = Invoke-Az @('account', 'show') -Json
    if ($account.id -ne $Configuration.subscription_id -or $account.tenantId -ne $Configuration.tenant_id -or $account.state -ne 'Enabled' -or $account.environmentName -ne 'AzureCloud') {
        throw 'The active Azure account must match the enabled configured subscription and tenant in AzureCloud.'
    }
    $location = $Configuration.location
    $sizes = @(Invoke-Az @('vm', 'list-skus', '--location', $location, '--resource-type', 'virtualMachines', '--size', $VmSize, '--all') -Json | Where-Object { $_.name -eq $VmSize })
    if ($sizes.Count -ne 1 -or @($sizes[0].restrictions | Where-Object { $_.type -eq 'Location' }).Count -gt 0) { throw "$VmSize is unavailable to this subscription in $location." }
    $vcpus = [int](@($sizes[0].capabilities | Where-Object { $_.name -eq 'vCPUs' })[0].value)
    $usage = @(Invoke-Az @('vm', 'list-usage', '--location', $location) -Json)
    foreach ($quotaName in @('cores', $sizes[0].family)) {
        $quota = @($usage | Where-Object { $_.name.value -eq $quotaName })
        if ($quota.Count -ne 1 -or ($quota[0].limit - $quota[0].currentValue) -lt $vcpus) { throw "Insufficient or unverified regional vCPU quota for $quotaName." }
    }

    $availableSkus = @(Invoke-Az @('vm', 'image', 'list-skus', '--location', $location, '--publisher', 'MicrosoftWindowsDesktop', '--offer', 'windows-11') -Json)
    $multiSession = @($availableSkus | Where-Object { $_.name -match '^win11-[0-9]{2}h[12]-avd$' } | Sort-Object name -Descending)
    $sku = $ImageSku
    if (-not $sku) {
        if ($multiSession.Count -eq 0) { throw 'No stable Windows 11 Enterprise multi-session Marketplace SKU is available in this region.' }
        $sku = $multiSession[0].name
    }
    if ($sku -notin @($multiSession.name)) { throw "The requested multi-session SKU is not available: $sku" }
    $sourceImage = Invoke-Az @('vm', 'image', 'show', '--location', $location, '--urn', "MicrosoftWindowsDesktop:windows-11:${sku}:latest") -Json
    if ($sourceImage.hyperVGeneration -ne 'V2') { throw 'A Generation 2 source image is required.' }

    $variables = [ordered]@{
        subscription_id                     = $Configuration.subscription_id
        tenant_id                           = $Configuration.tenant_id
        location                            = $location
        gallery_resource_group              = $Configuration.gallery_resource_group
        gallery_name                        = $Configuration.gallery_name
        image_definition_name               = $Configuration.image_definition_name
        image_version                       = $Version
        image_sku                           = $sku
        source_image_version                = $sourceImage.name
        replication_regions                 = @($Configuration.replication_regions)
        tags                                = $Configuration.tags
        vm_size                             = $VmSize
        virtual_network_name                = $Configuration.virtual_network_name
        virtual_network_resource_group_name = $Configuration.virtual_network_resource_group_name
        virtual_network_subnet_name         = $Configuration.virtual_network_subnet_name
    }
    $artifactDirectory = Join-Path $script:RepositoryRoot "artifacts/images/$Version"
    New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null
    $variableFile = Join-Path $artifactDirectory 'build.pkrvars.json'
    $variables | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $variableFile -Encoding utf8

    # Validate locally first; creating no Azure resources.
    Push-Location $artifactDirectory
    try {
        $code = Invoke-Native -Source 'packer' -FilePath $PackerCommand -Arguments @('init', $script:PackerDirectory)
        if ($code -ne 0) { throw "packer init failed with exit code $code." }
        $code = Invoke-Native -Source 'packer' -FilePath $PackerCommand -Arguments @('validate', "-var-file=$variableFile", $script:PackerDirectory)
        if ($code -ne 0) { throw "packer validate failed with exit code $code." }
    } finally {
        Pop-Location
    }

    # The runner builds from a GitHub checkout (see .github/workflows/build-image.yml), so packer/ and labs/ must be committed and pushed first.
    $repository = $runner.github_repository
    $branch = ((& git -C $script:RepositoryRoot rev-parse --abbrev-ref HEAD) | Out-String).Trim()
    $sha = ((& git -C $script:RepositoryRoot rev-parse HEAD) | Out-String).Trim()
    $dirty = @(& git -C $script:RepositoryRoot status --porcelain -- packer labs .github)
    if ($dirty.Count -gt 0) { throw "Uncommitted changes in packer/, labs/ or .github/ would be missing from the build:`n$($dirty -join "`n")`nCommit and push them, then rerun -Stage Image." }
    & gh api "repos/$repository/commits/$sha" --silent 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Commit $sha is not on GitHub ($repository). Push branch '$branch', then rerun -Stage Image." }

    $onError = if ($CleanupOnFailure) { 'cleanup' } else { 'abort' }
    Write-Log "Dispatching the build-image workflow on $repository ($branch @ $($sha.Substring(0, 7))) for $sku, gallery version $Version. The self-hosted runner $($runner.name) checks out the repository and runs Packer."
    $dispatchedAt = [DateTime]::UtcNow.AddMinutes(-1)
    $code = Invoke-Native -Source 'gh' -FilePath 'gh' -Arguments @('workflow', 'run', 'build-image.yml', '--repo', $repository, '--ref', $branch, '-f', "image_version=$Version", '-f', "image_sku=$sku", '-f', "on_error=$onError")
    if ($code -ne 0) { throw "Could not dispatch the build-image workflow (exit code $code). The workflow file must exist on GitHub for branch '$branch'." }

    $runId = $null
    $lookup = (Get-Date).AddMinutes(3)
    while (-not $runId) {
        if ((Get-Date) -gt $lookup) { throw 'The dispatched workflow run did not appear within 3 minutes.' }
        Start-Sleep -Seconds 5
        $runs = @((& gh run list --repo $repository --workflow build-image.yml --event workflow_dispatch --branch $branch --limit 10 --json databaseId,createdAt,headSha | Out-String) | ConvertFrom-Json)
        $match = @($runs | Where-Object { $_.headSha -eq $sha -and [DateTime]::Parse($_.createdAt).ToUniversalTime() -ge $dispatchedAt } | Sort-Object createdAt -Descending)
        if ($match.Count -gt 0) { $runId = $match[0].databaseId }
    }
    Write-Log "Workflow run $runId started: https://github.com/$repository/actions/runs/$runId"

    $conclusion = $null
    $deadline = (Get-Date).AddMinutes(150)
    while (-not $conclusion) {
        if ((Get-Date) -gt $deadline) { throw 'The image build did not finish within 150 minutes.' }
        Start-Sleep -Seconds 30
        $state = (& gh run view $runId --repo $repository --json status,conclusion | Out-String) | ConvertFrom-Json
        Write-Log "Workflow run $runId status: $($state.status)" -Quiet
        if ($state.status -eq 'completed') { $conclusion = $state.conclusion }
    }
    $logArguments = if ($conclusion -eq 'success') { @('run', 'view', "$runId", '--repo', $repository, '--log') } else { @('run', 'view', "$runId", '--repo', $repository, '--log-failed') }
    [void](Invoke-Native -Source 'packer' -FilePath 'gh' -Arguments $logArguments)
    Write-Log "Workflow run $runId concluded: $conclusion" -Source packer
    if ($conclusion -ne 'success') {
        $kept = @(Invoke-Az @('group', 'list', '--query', '[].name', '--output', 'tsv') -AllowFailure | ForEach-Object { $_ -split "`n" } | Where-Object { $_ -like 'pkr-immersionday-*' })
        if (-not $CleanupOnFailure) { Write-Log "Build failed. Temporary build resources were KEPT for troubleshooting: $($kept -join ', '). Delete with: az group delete --name <group> --yes. Use -CleanupOnFailure to delete failed builds automatically." }
        throw "The build-image workflow concluded '$conclusion' (see the log)."
    }
}

function Step-Image {
    $configuration = Get-OpenTofuOutput 'packer_configuration'
    $existing = @(Get-GalleryVersion -Configuration $configuration)
    $build = $true
    if ($existing.Count -gt 0) {
        Write-Log "Published image versions: $($existing -join ', ')"
        $build = Confirm-Action 'Build a new image version?' $false
    }
    if ($build) {
        $changelogVersion = Get-ChangelogVersion
        $default = if ($script:PublishedImageVersion) { $script:PublishedImageVersion } elseif ($changelogVersion -and $changelogVersion -notin $existing) { $changelogVersion } elseif ($existing.Count -gt 0) { $latest = [version]$existing[-1]; "$($latest.Major).$($latest.Minor).$($latest.Build + 1)" } else { '1.0.0' }
        $version = Read-Default 'Image version to build (Major.Minor.Patch)' $default
        if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { throw 'The image version must look like 1.0.0.' }
        if ($version -in $existing) { throw "Image version $version already exists; choose a new version." }
        Write-Log 'The build creates a temporary VM, Standard public IP and resource group, installs tools, generalizes the VM and publishes the image. These incur Azure charges and need policy, licensing, quota and HTTPS access to Azure and publisher downloads.'
        if (-not (Confirm-Action 'Start the Packer image build now?')) { throw 'Image build was declined.' }
        Invoke-ImageBuild -Configuration $configuration -Version $version
        $image = Invoke-Az @('sig', 'image-version', 'show', '--resource-group', $configuration.gallery_resource_group, '--gallery-name', $configuration.gallery_name, '--gallery-image-definition', $configuration.image_definition_name, '--gallery-image-version', $version, '--expand', 'ReplicationStatus') -Json
        if ($image.provisioningState -ne 'Succeeded') { throw "Image $version is $($image.provisioningState), not Succeeded." }
        $script:PublishedImageVersion = $version
        Write-Log "Image $version is published in gallery $($configuration.gallery_name)."
    } else {
        $script:PublishedImageVersion = Read-Default 'Existing image version to deploy hosts from' $existing[-1]
        if ($script:PublishedImageVersion -notin $existing) { throw "Image version $($script:PublishedImageVersion) is not published." }
    }
}

## Phase 2 users and hosts stage

function Test-HostCapacity {
    param([int]$HostCount)
    $size = [regex]::Match((Get-Content -LiteralPath $script:TfVarsPath -Raw), '(?m)^\s*session_host_size\s*=\s*"(?<size>[^"]+)"').Groups['size'].Value
    $location = (Get-TfVar 'location').ToLowerInvariant()
    if (-not $size) { return }
    $cores = Invoke-Az @('vm', 'list-sizes', '--location', $location, '--query', "[?name=='$size'].numberOfCores | [0]", '--output', 'tsv') -AllowFailure
    $usage = Invoke-Az @('vm', 'list-usage', '--location', $location, '--query', "[?name.value=='cores'] | [0].{limit:limit,used:currentValue}", '--output', 'json') -Json -AllowFailure
    if (-not $cores -or -not $usage) { Write-Log 'Could not read the regional vCPU quota; confirm capacity manually.'; return }
    $needed = [int]$cores * $HostCount
    $free = [int]$usage.limit - [int]$usage.used
    Write-Log "Capacity check: $HostCount x $size needs $needed vCPUs; $free regional vCPUs are free."
    if ($needed -gt $free) {
        if (-not (Confirm-Action 'The regional vCPU quota looks too small. Continue anyway?' $false)) { throw 'Stopped: request more quota or reduce lab users, then rerun -Stage Phase2.' }
    }
}

function Read-HostAdminPassword {
    Write-Log 'Local administrator password for the session hosts (12-123 characters). Press Enter to generate one and store it in the lab Key Vault.'
    $first = Read-Host 'Password' -AsSecureString
    $plain = ConvertFrom-SecureString $first -AsPlainText
    if ([string]::IsNullOrEmpty($plain)) { return @{ Value = New-RandomPassword; Generated = $true } }
    $second = Read-Host 'Confirm password' -AsSecureString
    if ($plain -cne (ConvertFrom-SecureString $second -AsPlainText)) { throw 'The passwords did not match.' }
    if ($plain.Length -lt 12 -or $plain.Length -gt 123) { throw 'The password must be 12-123 characters.' }
    return @{ Value = $plain; Generated = $false }
}

function Save-GeneratedPassword {
    param([string]$Value)
    $vault = (Get-OpenTofuOutput 'lab_credentials_key_vault').name
    $file = [IO.Path]::GetTempFileName()
    try {
        Set-Content -LiteralPath $file -Value $Value -NoNewline -Encoding utf8NoBOM
        Protect-SecretFile -Path $file
        Invoke-Az @('keyvault', 'secret', 'set', '--vault-name', $vault, '--name', 'avd-local-admin-password', '--file', $file, '--encoding', 'utf-8') | Out-Null
        Write-Log "The generated administrator password is stored in Key Vault '$vault' as 'avd-local-admin-password'."
    } finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}

function Step-Phase2 {
    $users = [int](Get-TfVar 'num_of_labusers')
    if ($users -lt 1) { throw 'num_of_labusers is 0 in terraform.tfvars. Set the lab-user count (rerun -Stage Phase1) before deploying hosts.' }
    if (-not $script:PublishedImageVersion) {
        $configuration = Get-OpenTofuOutput 'packer_configuration'
        $published = @(Get-GalleryVersion -Configuration $configuration)
        if ($published.Count -eq 0) { throw 'No published image version exists. Run the Image stage first.' }
        $script:PublishedImageVersion = Read-Default 'Image version to deploy hosts from' $published[-1]
    }
    $maxHosts = [int][math]::Ceiling($users / 4)
    Write-Log "Sizing: $users lab users / 4 = $maxHosts hosts. All of them are created now and stay powered on (no scaling plan). Image version: $($script:PublishedImageVersion)."
    if (-not (Confirm-Action 'Deploy lab users, TAPs and these hosts?')) { throw 'Phase 2 was declined.' }
    Test-HostCapacity -HostCount $maxHosts

    $password = Read-HostAdminPassword
    if ($password.Generated) { Save-GeneratedPassword -Value $password.Value }
    Set-TfVar 'avd_session_host_count' $maxHosts
    Set-TfVar 'avd_image_version' $script:PublishedImageVersion
    Set-TfVar 'avd_registration_expiration' ([DateTime]::UtcNow.AddDays(7).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))
    Write-Log 'terraform.tfvars now records the host count, image version and a 7-day registration expiry (renew the expiry before later plans that keep hosts).'
    try {
        @{ avd_admin_password = $password.Value } | ConvertTo-Json -Compress | Set-Content -LiteralPath $script:SecretVarsPath -Encoding utf8NoBOM
        Protect-SecretFile -Path $script:SecretVarsPath
        $password = $null
        Invoke-OpenTofu @('plan', '-input=false', '-out=labphase2.plan')
        if (-not (Confirm-Action 'Apply the Phase 2 plan above? This creates the Entra users, issues TAPs, writes credentials to Key Vault and deploys the hosts.')) { throw 'Phase 2 apply was declined.' }
        Invoke-OpenTofu @('apply', '-input=false', 'labphase2.plan')
    } finally {
        Remove-Item -LiteralPath $script:SecretVarsPath -Force -ErrorAction SilentlyContinue
    }
    Write-Log "Done. Staff credentials: $(Join-Path $script:RepositoryRoot 'artifacts/credentials/LabUsers.csv'). Hosts register with the host pool after their extensions finish; check the AVD portal blade in a few minutes."
    Write-Log 'Later manual plans that keep hosts need avd_admin_password supplied again (a git-ignored *.auto.tfvars.json file) and a fresh avd_registration_expiration.'
}

## Destroy

function Get-TofuStateList {
    $lines = @(& $OpenTofuCommand "-chdir=$script:InfraDirectory" state list -no-color 2>$null)
    if ($LASTEXITCODE -ne 0) { return @() }
    return @($lines | Where-Object { $_ })
}

function Remove-GalleryImageVersions {
    try {
        $configuration = Get-OpenTofuOutput 'packer_configuration'
    } catch {
        Write-Log 'The gallery outputs are not available, so image versions were not checked. If the destroy fails on the gallery, delete its image versions manually.'
        return
    }
    $versions = @(Invoke-Az @('sig', 'image-version', 'list', '--resource-group', $configuration.gallery_resource_group, '--gallery-name', $configuration.gallery_name, '--gallery-image-definition', $configuration.image_definition_name, '--query', '[].name', '--output', 'tsv') -AllowFailure | ForEach-Object { $_ -split "`n" } | Where-Object { $_ })
    if ($versions.Count -eq 0) { Write-Log 'The image gallery has no published versions.'; return }
    Write-Log "Packer-published image versions exist and are outside OpenTofu state: $($versions -join ', '). The gallery cannot be destroyed while they exist."
    if (-not (Confirm-Action 'Delete these image versions now?' $false)) { throw 'Destroy stopped: delete the image versions (or confirm their deletion) and rerun -Destroy.' }
    foreach ($version in $versions) {
        Write-Log "Deleting image version $version (can take several minutes)."
        Invoke-Az @('sig', 'image-version', 'delete', '--resource-group', $configuration.gallery_resource_group, '--gallery-name', $configuration.gallery_name, '--gallery-image-definition', $configuration.image_definition_name, '--gallery-image-version', $version) | Out-Null
        Write-Log "Deleted image version $version."
    }
}

function Invoke-LabDestroy {
    $resourceGroup = Get-TfVar 'resource_group_name'
    if (-not $resourceGroup) { throw "resource_group_name is missing from $script:TfVarsPath." }
    Invoke-OpenTofu @('init', '-input=false')
    $state = Get-TofuStateList
    if ($state.Count -eq 0) { Write-Log 'OpenTofu state is empty; there is nothing to destroy.'; return }
    Write-Log "OpenTofu state tracks $($state.Count) objects, including the lab users, student resource groups, hosts, the shared resource group '$resourceGroup' and the Entra lab group."

    $occupied = [Collections.Generic.List[string]]::new()
    foreach ($entry in $state) {
        if ($entry -notmatch '^azurerm_resource_group\.lab_users\["(?<key>[^"]+)"\]$') { continue }
        $group = "LAB-$($Matches.key)"
        $count = Invoke-Az @('resource', 'list', '--resource-group', $group, '--query', 'length(@)', '--output', 'tsv') -AllowFailure
        if ($count -and [int]$count -gt 0) { $occupied.Add("$group ($count resources)") }
    }
    if ($occupied.Count -gt 0) {
        Write-Log "WARNING: student resource groups still contain resources: $($occupied -join ', '). The provider's non-empty-group guard will block their deletion. Remove those resources first."
        if (-not (Confirm-Action 'Continue anyway?' $false)) { throw 'Destroy stopped: clean up the student resource groups, then rerun -Destroy.' }
    }
    $leftover = @(Invoke-Az @('group', 'list', '--query', '[].name', '--output', 'tsv') -AllowFailure | ForEach-Object { $_ -split "`n" } | Where-Object { $_ -like 'pkr-immersionday-*' })
    if ($leftover.Count -gt 0) { Write-Log "WARNING: temporary Packer build groups exist: $($leftover -join ', '). They are not managed by OpenTofu; delete them separately if they are stale." }

    if ($state -contains 'terraform_data.lab_tap_policy_cleanup[0]') {
        Write-Log 'Refreshing the stored path of the TAP-policy cleanup script so its destroy step can run.'
        Invoke-OpenTofu @('apply', '-input=false', '-auto-approve', '-target=terraform_data.lab_tap_policy_cleanup[0]')
    }

    Write-Log 'Previewing the destroy plan (labdestroy.plan).'
    Invoke-OpenTofu @('plan', '-destroy', '-input=false', '-var', 'avd_session_host_count=0', '-out=labdestroy.plan')
    Write-Log "This permanently removes the shared lab environment, the Entra lab users and group and the student resource groups. Key Vault has purge protection, so its soft-deleted vault is retained for 7 days. Staff credential files already on this machine are not deleted."
    $typed = Read-HostLogged "Type the shared resource group name '$resourceGroup' to confirm the destroy (anything else cancels)"
    if ($typed -cne $resourceGroup) { throw 'Destroy cancelled: the confirmation did not match.' }

    Remove-GalleryImageVersions
    Invoke-OpenTofu @('destroy', '-input=false', '-auto-approve', '-var', 'avd_session_host_count=0')
    Write-Log 'OpenTofu destroy completed.'
}

## Main

$exitCode = 0
Initialize-Log
try {
    Write-Log "=== run start: user=$([Environment]::UserName) machine=$([Environment]::MachineName) stage=$Stage destroy=$($Destroy.IsPresent) log=$script:LogPath ==="
    Write-Log 'MSFTLabs Immersion Day lab setup'
    Test-Prerequisites
    if ($Destroy) {
        Invoke-Stage 'Service principal sign-in' { Connect-ServicePrincipalSession }
        Invoke-Stage 'Destroy lab environment' { Invoke-LabDestroy }
        Write-Log 'Destroy finished.'
    } else {
        $runAll = $Stage -eq 'All'
        if ($runAll -or $Stage -eq 'ServicePrincipal') { Invoke-Stage 'Service principal and permissions' { Step-ServicePrincipal } }
        if ($Stage -in @('Phase1', 'Runner', 'Image', 'Phase2')) { Invoke-Stage 'Service principal sign-in' { Connect-ServicePrincipalSession } }
        if ($runAll -or $Stage -eq 'Phase1') { Invoke-Stage 'Phase 1: core infrastructure' { Step-Phase1 } }
        if ($runAll -or $Stage -eq 'Runner') { Invoke-Stage 'Self-hosted runner' { Step-Runner } }
        if ($runAll -or $Stage -eq 'Image') { Invoke-Stage 'Lab image build (Packer)' { Step-Image } }
        if ($runAll -or $Stage -eq 'Phase2') { Invoke-Stage 'Phase 2: users and hosts' { Step-Phase2 } }
        Write-Log 'All requested stages completed.'
    }
} catch {
    Write-Log "Setup stopped: $($_.Exception.Message)"
    Write-Log "$($_.ScriptStackTrace)" -Quiet
    Write-Log 'Rerun with -Stage <ServicePrincipal|Phase1|Runner|Image|Phase2> to resume at that stage, or -Destroy to tear down.'
    $exitCode = 1
} finally {
    Write-Log "=== run end: exit code $exitCode ===" -Quiet
    Remove-PlanFile
    Remove-Item -LiteralPath $script:SecretVarsPath -Force -ErrorAction SilentlyContinue
    $env:AZURE_CONFIG_DIR = $script:OriginalConfigDir
    if (-not $script:OriginalConfigDir) { Remove-Item Env:AZURE_CONFIG_DIR -ErrorAction SilentlyContinue }
    if ($script:IsolatedConfig -and (Test-Path -LiteralPath $script:IsolatedConfig)) { Remove-Item -LiteralPath $script:IsolatedConfig -Recurse -Force -ErrorAction SilentlyContinue }
    foreach ($name in $script:OriginalArm.Keys) { [Environment]::SetEnvironmentVariable($name, $script:OriginalArm[$name], 'Process') }
    Close-Log
}
exit $exitCode
