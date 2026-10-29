#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Publish', 'Cleanup')]
    [string]$Mode,
    [switch]$RenewTap
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest
if (-not $env:LAB_PUBLISH_SETTINGS) { throw 'OpenTofu credential settings are required.' }
$settings = $env:LAB_PUBLISH_SETTINGS | ConvertFrom-Json
$env:LAB_PUBLISH_SETTINGS = $null
$users = @()
if ($Mode -eq 'Publish') {
    if (-not $env:LAB_PUBLISH_USERS) { throw 'The sensitive user payload is required.' }
    $users = @($env:LAB_PUBLISH_USERS | ConvertFrom-Json)
}
$env:LAB_PUBLISH_USERS = $null

function Get-AccessToken {
    param([string]$Audience)
    $arguments = @('account', 'get-access-token', '--tenant', $settings.tenant_id, '--resource', $Audience, '--output', 'json', '--only-show-errors')
    try {
        $response = (& az @arguments | Out-String) | ConvertFrom-Json
        if (-not $response.accessToken) { throw 'Missing token.' }
        return $response.accessToken
    } catch { throw 'Could not obtain the required Azure CLI token in the configured tenant.' }
}

function Invoke-ServiceRequest {
    param([string]$Method, [string]$Uri, [string]$Token, $Body, [switch]$AllowNotFound)
    $arguments = @{ Method = $Method; Uri = $Uri; Headers = @{ Authorization = "Bearer $Token" }; TimeoutSec = 60 }
    if ($null -ne $Body) { $arguments.Body = $Body | ConvertTo-Json -Depth 20; $arguments.ContentType = 'application/json' }
    try { return Invoke-RestMethod @arguments }
    catch {
        $responseProperty = $_.Exception.PSObject.Properties['Response']
        $status = if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) { [int]$responseProperty.Value.StatusCode } else { 0 }
        if ($AllowNotFound -and $status -eq 404) { return $null }
        throw "Credential service request failed (HTTP $status). Check permissions, policy and RBAC propagation; response bodies are withheld to protect secrets."
    }
}

$graphToken = $null
$vaultToken = $null
try {
    $graphToken = Get-AccessToken -Audience $settings.graph_base_uri
    if ($Mode -eq 'Cleanup') {
        $policyUri = "$($settings.graph_base_uri)/$($settings.graph_api_version)/$($settings.policy_url)"
        $policy = Invoke-ServiceRequest -Method Get -Uri $policyUri -Token $graphToken
        $targets = @($policy.includeTargets | Where-Object { $_.id -ne $settings.group_id })
        if ($targets.Count -ne @($policy.includeTargets).Count) {
            Invoke-ServiceRequest -Method Patch -Uri $policyUri -Token $graphToken -Body @{
                '@odata.type' = $settings.policy_type
                includeTargets = $targets
            } | Out-Null
        }
        Write-Output 'Removed only the lab-group TAP target from the current policy.'
        return
    }

    $vaultToken = Get-AccessToken -Audience 'https://vault.azure.net'
    $exportRows = [Collections.Generic.List[object]]::new()
    foreach ($user in $users) {
        $secretName = $settings.secret_name_format.Replace('%s', $user.Name.ToLowerInvariant())
        $secretUri = "$($settings.vault_uri.TrimEnd('/'))/secrets/${secretName}?api-version=$($settings.vault_api_version)"
        $bundle = Invoke-ServiceRequest -Method Get -Uri $secretUri -Token $vaultToken -AllowNotFound
        $record = if ($null -ne $bundle) { $bundle.value | ConvertFrom-Json } else { $null }
        if ($record -and $record.UserObjectId -ne $user.ObjectId) { throw 'Existing vault credentials belong to a different account; resolve the record before publishing.' }
        if ($RenewTap -or -not $record -or $record.Password -cne $user.Password) {
            $tapUri = "$($settings.graph_base_uri)/$($settings.graph_api_version)/users/$($user.ObjectId)/authentication/temporaryAccessPassMethods"
            $tap = Invoke-ServiceRequest -Method Post -Uri $tapUri -Token $graphToken -Body @{
                lifetimeInMinutes = $settings.tap_lifetime_minutes
                isUsableOnce = $settings.tap_is_usable_once
            }
            if ([string]::IsNullOrWhiteSpace($tap.temporaryAccessPass)) { throw 'TAP creation did not return its one-time secret.' }
            $record = [pscustomobject]@{
                UserObjectId = $user.ObjectId
                LabUser = $user.LabUser
                Password = $user.Password
                TAP = $tap.temporaryAccessPass
                TapMethodId = $tap.id
                TapStartDateTime = $tap.startDateTime
                TapLifetimeInMinutes = $tap.lifetimeInMinutes
                TapIsUsableOnce = $tap.isUsableOnce
            }
            Invoke-ServiceRequest -Method Put -Uri $secretUri -Token $vaultToken -Body @{
                value = ($record | ConvertTo-Json -Depth 8)
                contentType = $settings.content_type
            } | Out-Null
        }
        if ([string]::IsNullOrWhiteSpace($record.TAP)) { throw 'The retained credential record has no TAP secret.' }
        $exportRows.Add([pscustomobject]@{
            LabUser = $record.LabUser
            Password = $record.Password
            TAP = $record.TAP
            'Assigned Student' = ''
        })
        Write-Output "Published or reused credentials for $($user.Name); secret values were not printed."
    }
    $env:LAB_CREDENTIALS_JSON = ConvertTo-Json -InputObject $exportRows.ToArray() -Depth 8
    & (Join-Path $PSScriptRoot 'Export-LabUserCsv.ps1') -Path $settings.csv_path
} finally {
    $env:LAB_PUBLISH_USERS = $null
    $env:LAB_CREDENTIALS_JSON = $null
    $graphToken = $null
    $vaultToken = $null
    $record = $null
    $tap = $null
    $users = $null
    $exportRows = $null
}