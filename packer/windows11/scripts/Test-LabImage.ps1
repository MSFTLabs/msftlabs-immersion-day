[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
$env:AZURE_BICEP_USE_BINARY_FROM_PATH = 'True'

$edition = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID
if ($edition -ne 'ServerRdsh') {
    throw "Expected Windows Enterprise multi-session (ServerRdsh), found $edition."
}

$checks = @(
    @{ Name = 'PowerShell'; Command = 'pwsh.exe'; Arguments = @('-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()') }
    @{ Name = 'AzureCLI'; Command = 'az.cmd'; Arguments = @('--version') }
    @{ Name = 'Git'; Command = 'git.exe'; Arguments = @('--version') }
    @{ Name = 'Bicep'; Command = 'bicep.exe'; Arguments = @('--version') }
    @{ Name = 'VSCode'; Command = 'code.cmd'; Arguments = @('--version') }
    @{ Name = 'OhMyPosh'; Command = 'oh-my-posh.exe'; Arguments = @('--version') }
)

foreach ($check in $checks) {
    $command = Get-Command -Name $check.Command -ErrorAction Stop
    $commandArguments = $check.Arguments
    $result = (& $command.Source @commandArguments | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($result)) {
        throw "$($check.Name) did not run successfully: $result"
    }
    Write-Output "$($check.Name): $(($result -split "`r?`n")[0])"
}

$userAppx = @(Get-AppxPackage -AllUsers | Where-Object { $_.Name -in @('Microsoft.PowerShell', 'JanDeDobbeleer.OhMyPosh', 'ohmyposh.cli', 'Microsoft.AzureCLI') })
if ($userAppx.Count -gt 0) { throw "Per-user Appx packages found that would break Sysprep: $($userAppx.Name -join ', ')" }

$markViewKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{095AE493-66FA-4620-87E7-F76F3F79DBE0}'
if (-not (Test-Path -LiteralPath $markViewKey)) { throw 'MarkView is not installed machine-wide.' }
Write-Output "MarkView: $((Get-ItemProperty -LiteralPath $markViewKey).DisplayVersion)"

$logonCommand = (Get-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'MsftLabsGuide' -ErrorAction Stop).MsftLabsGuide
if ($logonCommand -notmatch 'markview\.exe"? "C:\\labs\\LabGuideExample\.md"$') { throw "Unexpected lab guide logon command: $logonCommand" }
if (-not (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'MarkView\markview.exe'))) { throw 'markview.exe is missing from Program Files.' }

$mesloFonts = @((Get-Item -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts').Property | Where-Object { $_ -match '^Meslo.*Nerd Font' })
if ($mesloFonts.Count -eq 0) { throw 'No Meslo Nerd Font is installed system-wide.' }
Write-Output "Fonts: $($mesloFonts -join '; ')"

$allUsersProfile = (& pwsh.exe -NoProfile -Command '$PROFILE.AllUsersAllHosts' | Out-String).Trim()
if (-not (Select-String -LiteralPath $allUsersProfile -SimpleMatch 'oh-my-posh init pwsh' -Quiet)) { throw "Oh My Posh is not initialised in $allUsersProfile." }

$fragment = Join-Path $env:ProgramData 'Microsoft\Windows Terminal\Fragments\MsftLabs\lab.json'
if (-not (Test-Path -LiteralPath $fragment)) { throw "The Windows Terminal fragment is missing: $fragment" }

if (-not (Test-Path -LiteralPath 'C:\labs\LabGuideExample.md')) { throw 'C:\labs\LabGuideExample.md was not uploaded.' }
Write-Output "Labs: $((Get-ChildItem -LiteralPath C:\labs -Recurse -File).Count) files under C:\labs"

Write-Output 'Tool versions and machine-wide image configuration passed.'
