#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Path
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $env:LAB_CREDENTIALS_JSON) { throw 'The sensitive credential payload was not provided by OpenTofu.' }

$rows = @($env:LAB_CREDENTIALS_JSON | ConvertFrom-Json)
$env:LAB_CREDENTIALS_JSON = $null
$headers = @('LabUser', 'Password', 'TAP', 'Assigned Student')
$directory = Split-Path -Path ([IO.Path]::GetFullPath($Path)) -Parent
New-Item -ItemType Directory -Path $directory -Force | Out-Null

if ($IsWindows) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $acl = Get-Acl -LiteralPath $directory
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { $acl.RemoveAccessRuleSpecific($rule) }
    foreach ($principal in @($identity, $system)) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($principal, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $directory -AclObject $acl
} else {
    [IO.File]::SetUnixFileMode($directory, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
}

$assignedStudents = @{}
if (Test-Path -LiteralPath $Path) {
    $existingRows = @(Import-Csv -LiteralPath $Path)
    if ($existingRows.Count -gt 0) {
        foreach ($header in $headers) {
            if ($header -notin $existingRows[0].PSObject.Properties.Name) { throw "Existing CSV is missing the required column: $header" }
        }
    }
    foreach ($row in $existingRows) {
        if ($assignedStudents.ContainsKey($row.LabUser)) { throw 'Existing CSV contains duplicate lab accounts; resolve them before exporting.' }
        $assignedStudents[$row.LabUser] = $row.'Assigned Student'
    }
}

$exportRows = foreach ($row in $rows) {
    if ([string]::IsNullOrWhiteSpace($row.LabUser) -or [string]::IsNullOrWhiteSpace($row.Password) -or [string]::IsNullOrWhiteSpace($row.TAP)) {
        throw 'A lab account is missing its initial password or creation-time TAP. No CSV will be overwritten.'
    }
    [pscustomobject][ordered]@{
        LabUser = $row.LabUser
        Password = $row.Password
        TAP = $row.TAP
        'Assigned Student' = if ($assignedStudents.ContainsKey($row.LabUser)) { $assignedStudents[$row.LabUser] } else { '' }
    }
}

$temporaryPath = Join-Path $directory ([guid]::NewGuid().ToString() + '.csv')
try {
    if ($rows.Count -eq 0) {
        '"LabUser","Password","TAP","Assigned Student"' | Set-Content -LiteralPath $temporaryPath -Encoding utf8
    } else {
        $exportRows | Export-Csv -LiteralPath $temporaryPath -NoTypeInformation -Encoding utf8
    }
    if (-not $IsWindows) {
        [IO.File]::SetUnixFileMode($temporaryPath, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
    }
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    Write-Output "Staff CSV written to $Path; credential values were not printed."
} finally {
    if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
    $rows = $null
    $exportRows = $null
}