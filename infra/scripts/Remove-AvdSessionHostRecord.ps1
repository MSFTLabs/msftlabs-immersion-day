[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

## Deletes a session host's record from its AVD host pool; settings arrive as JSON in LAB_AVD_RECORD_SETTINGS.
$settings = $env:LAB_AVD_RECORD_SETTINGS | ConvertFrom-Json
$url = "https://management.azure.com/subscriptions/$($settings.subscription_id)/resourceGroups/$($settings.resource_group)/providers/Microsoft.DesktopVirtualization/hostPools/$($settings.host_pool)/sessionHosts/$($settings.host_name)"

# force=true goes through --url-parameters because a literal & in --url is swallowed by az.cmd.
$output = az rest --method DELETE --url $url --url-parameters "api-version=$($settings.api_version)" force=true 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    if ($output -match 'ResourceNotFound|NotFound') {
        Write-Output "No session host record for $($settings.host_name) in $($settings.host_pool); nothing to delete."
        return
    }
    throw "Deleting the session host record for $($settings.host_name) failed: $output"
}
Write-Output "Deleted the session host record for $($settings.host_name) from $($settings.host_pool)."
