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

$markdoneExe = Join-Path $env:ProgramFiles 'Markdone\Markdone.exe'
if (-not (Test-Path -LiteralPath $markdoneExe)) { throw 'Markdone.exe is missing from Program Files.' }
Write-Output "Markdone: $((Get-Item -LiteralPath $markdoneExe).VersionInfo.FileVersion)"

$logonCommand = (Get-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'MsftLabsGuide' -ErrorAction Stop).MsftLabsGuide
if ($logonCommand -notmatch 'Markdone\.exe"? "C:\\labs\\LabGuideExample\.md"$') { throw "Unexpected lab guide logon command: $logonCommand" }

$mesloFonts = @((Get-Item -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts').Property | Where-Object { $_ -match '^Meslo.*Nerd Font' })
if ($mesloFonts.Count -eq 0) { throw 'No Meslo Nerd Font is installed system-wide.' }
Write-Output "Fonts: $($mesloFonts -join '; ')"

$allUsersProfile = (& pwsh.exe -NoProfile -Command '$PROFILE.AllUsersAllHosts' | Out-String).Trim()
if (-not (Select-String -LiteralPath $allUsersProfile -SimpleMatch 'oh-my-posh init pwsh' -Quiet)) { throw "Oh My Posh is not initialised in $allUsersProfile." }

$fragment = Join-Path $env:ProgramData 'Microsoft\Windows Terminal\Fragments\MsftLabs\lab.json'
if (-not (Test-Path -LiteralPath $fragment)) { throw "The Windows Terminal fragment is missing: $fragment" }

$vscodeSettings = Join-Path $env:SystemDrive 'Users\Default\AppData\Roaming\Code\User\settings.json'
if (-not (Test-Path -LiteralPath $vscodeSettings)) { throw "The VS Code default settings are missing: $vscodeSettings" }
$terminalFont = (Get-Content -LiteralPath $vscodeSettings -Raw | ConvertFrom-Json).'terminal.integrated.fontFamily'
if ($terminalFont -notmatch '^.Meslo.* Nerd Font.$') { throw "Unexpected VS Code terminal font: $terminalFont" }
Write-Output "VS Code terminal font: $terminalFont"

$wallpaper = Join-Path $env:SystemRoot 'Web\Wallpaper\MsftLabs\host_bg.png'
if (-not (Test-Path -LiteralPath $wallpaper)) { throw "The lab wallpaper is missing: $wallpaper" }
& reg.exe load 'HKU\LabDefaultTest' 'C:\Users\Default\NTUSER.DAT' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not load the Default user hive (exit code $LASTEXITCODE)." }
try {
    $personalize = Get-ItemProperty -LiteralPath 'Registry::HKEY_USERS\LabDefaultTest\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    $desktop = Get-ItemProperty -LiteralPath 'Registry::HKEY_USERS\LabDefaultTest\Control Panel\Desktop'
    if ($personalize.AppsUseLightTheme -ne 0 -or $personalize.SystemUsesLightTheme -ne 0) { throw 'Dark mode is not the default for new users.' }
    if ($desktop.Wallpaper -ne $wallpaper) { throw "Unexpected default wallpaper: $($desktop.Wallpaper)" }
    Write-Output "Default user: dark mode on, wallpaper $($desktop.Wallpaper)"
    Remove-Variable personalize, desktop
}
finally {
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    $unloaded = $false
    foreach ($attempt in 1..10) {
        & reg.exe unload 'HKU\LabDefaultTest' | Out-Null
        if ($LASTEXITCODE -eq 0) { $unloaded = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $unloaded) { throw 'Could not unload the Default user hive; Sysprep would fail.' }
}

if (-not (Test-Path -LiteralPath 'C:\labs\LabGuideExample.md')) { throw 'C:\labs\LabGuideExample.md was not uploaded.' }
Write-Output "Labs: $((Get-ChildItem -LiteralPath C:\labs -Recurse -File).Count) files under C:\labs"

Write-Output 'Tool versions and machine-wide image configuration passed.'
