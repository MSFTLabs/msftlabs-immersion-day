[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

## Update this list to add additional tools/software to the labs.
$packages = @(
    @{ Id = 'powershell-core' }
    @{ Id = 'azure-cli' }
    @{ Id = 'git' }
    @{ Id = 'vscode' }
    @{ Id = 'bicep' }
)

## Oh My Posh: the Chocolatey package is a per-user MSIX (rejected by Sysprep), so use the signed standalone release binary pinned by SHA256.
$ohMyPosh = @{
    Url    = 'https://github.com/JanDeDobbeleer/oh-my-posh/releases/download/v31.9.1/posh-windows-amd64.exe'
    Sha256 = 'C2B34D2E8D9DB243172170CE4ADB70B0BD1476D29D355BC783CFA886724EB27E'
}

## Markdone is not in Chocolatey and ships as an unsigned zip with one self-contained exe, so pin the stable release by SHA256.
$markdone = @{
    Url    = 'https://apps.tomlabs.cz/dl/Markdone/stable/0.6.2/Markdone-win-x64.zip'
    Sha256 = 'B6209ECAA81B419EB02BB83DD5B5B63FD29461F267EF6D00BC53E15332D0C12B'
}

$terminalPowerShellProfileGuid = '{574e775e-4f2a-5b96-ac1e-a2962a402336}'

## Chocolatey
if (-not (Get-Command -Name choco.exe -ErrorAction SilentlyContinue)) {
    Write-Output 'Installing Chocolatey.'
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
}
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
$choco = (Get-Command -Name choco.exe -ErrorAction Stop).Source
Write-Output "Using Chocolatey $(& $choco --version) at $choco"

foreach ($package in $packages) {
    Write-Output "Installing $($package.Id)"
    $arguments = @('install', $package.Id, '-y', '--no-progress')
    # The powershell-core package refuses to overwrite a PowerShell 7 it did not install unless forced.
    if ($package.Id -eq 'powershell-core' -and (Get-Command -Name pwsh.exe -ErrorAction SilentlyContinue)) { $arguments += '--force' }
    if ($package.ContainsKey('Params')) { $arguments += "--params=$($package.Params)" }
    & $choco @arguments
    # 1641 and 3010 mean installed, reboot pending; Sysprep follows later in the build.
    if ($LASTEXITCODE -notin @(0, 1641, 3010)) { throw "choco install $($package.Id) failed with exit code $LASTEXITCODE." }
}
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
[Environment]::SetEnvironmentVariable('AZURE_BICEP_USE_BINARY_FROM_PATH', 'True', 'Machine')

## Markdone
$zip = Join-Path $env:TEMP 'Markdone.zip'
Invoke-WebRequest -Uri $markdone.Url -OutFile $zip -UseBasicParsing
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
if ($hash -ne $markdone.Sha256) { throw "Markdone zip hash mismatch: expected $($markdone.Sha256), got $hash." }
$markdoneDirectory = Join-Path $env:ProgramFiles 'Markdone'
New-Item -ItemType Directory -Path $markdoneDirectory -Force | Out-Null
Expand-Archive -LiteralPath $zip -DestinationPath $markdoneDirectory -Force
Remove-Item -LiteralPath $zip -Force

## Open the lab guide in Markdone at every logon.
$markdoneExe = Join-Path $markdoneDirectory 'Markdone.exe'
if (-not (Test-Path -LiteralPath $markdoneExe)) { throw "Markdone was not found at $markdoneExe." }
$logonCommand = "`"$markdoneExe`" `"C:\labs\LabGuideExample.md`""
# The Run key limits the command line to 260 characters.
if ($logonCommand.Length -gt 260) { throw 'The logon command exceeds the 260 character Run key limit.' }
Set-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'MsftLabsGuide' -Value $logonCommand

## Oh My Posh binary on the machine PATH
$poshDirectory = Join-Path $env:ProgramFiles 'oh-my-posh\bin'
New-Item -ItemType Directory -Path $poshDirectory -Force | Out-Null
$posh = Join-Path $poshDirectory 'oh-my-posh.exe'
Invoke-WebRequest -Uri $ohMyPosh.Url -OutFile $posh -UseBasicParsing
$hash = (Get-FileHash -LiteralPath $posh -Algorithm SHA256).Hash
if ($hash -ne $ohMyPosh.Sha256) { throw "Oh My Posh hash mismatch: expected $($ohMyPosh.Sha256), got $hash." }
if ((Get-AuthenticodeSignature -LiteralPath $posh).Status -ne 'Valid') { throw 'Oh My Posh signature is not valid.' }
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if (($machinePath -split ';') -notcontains $poshDirectory) { [Environment]::SetEnvironmentVariable('Path', "$machinePath;$poshDirectory", 'Machine') }
$env:Path += ";$poshDirectory"

## The font CLI installs per user even when elevated (checked on a kept build VM), so copy the files to Windows\Fonts and register them in HKLM.
& $posh font install meslo --plain
if ($LASTEXITCODE -ne 0) { throw "oh-my-posh font install failed with exit code $LASTEXITCODE." }

$userFontKey = Get-Item -LiteralPath 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
$fontKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
$mesloFonts = @($userFontKey.Property | Where-Object { $_ -match '^Meslo.*\(TrueType\)$' })
if ($mesloFonts.Count -eq 0) { throw 'oh-my-posh font install registered no Meslo fonts for the build user.' }
foreach ($name in $mesloFonts) {
    $source = [string]$userFontKey.GetValue($name)
    Copy-Item -LiteralPath $source -Destination (Join-Path $env:SystemRoot 'Fonts') -Force
    Set-ItemProperty -Path $fontKey -Name $name -Value (Split-Path $source -Leaf)
    Remove-ItemProperty -LiteralPath $userFontKey.PSPath -Name $name
    Remove-Item -LiteralPath $source -Force
}
$preferredFont = $mesloFonts | Where-Object { $_ -match '^MesloLGM Nerd Font Regular \(TrueType\)$|^MesloLGM Nerd Font \(TrueType\)$' } | Select-Object -First 1
if (-not $preferredFont) { $preferredFont = $mesloFonts | Where-Object { $_ -notmatch 'Mono|Propo|Bold|Italic' } | Sort-Object Length | Select-Object -First 1 }
if (-not $preferredFont) { throw 'No regular Meslo Nerd Font was found to use in Windows Terminal.' }
$fontFace = $preferredFont -replace ' (Regular )?\(TrueType\)$', ''
Write-Output "Windows Terminal font face: $fontFace"

## All-users PowerShell 7 profile that starts Oh My Posh

$pwsh = (Get-Command -Name pwsh.exe -ErrorAction Stop).Source
$allUsersProfile = (& $pwsh -NoProfile -Command '$PROFILE.AllUsersAllHosts' | Out-String).Trim()
if (-not $allUsersProfile) { throw 'Could not resolve the PowerShell 7 all-users profile path.' }
Set-Content -LiteralPath $allUsersProfile -Value 'if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) { oh-my-posh init pwsh --strict | Invoke-Expression }' -Encoding utf8

## Windows Terminal has no machine-wide settings.json; a fragment updates the default PowerShell profile for every user.
$fragmentDirectory = Join-Path $env:ProgramData 'Microsoft\Windows Terminal\Fragments\MsftLabs'
New-Item -ItemType Directory -Path $fragmentDirectory -Force | Out-Null
$fragment = @{ profiles = @(@{ updates = $terminalPowerShellProfileGuid; font = @{ face = $fontFace } }) } | ConvertTo-Json -Depth 6
[IO.File]::WriteAllText((Join-Path $fragmentDirectory 'lab.json'), $fragment, [Text.UTF8Encoding]::new($false))

## VS Code has no machine-wide settings file; the Default profile is copied into each new user profile at first sign-in.
$vscodeSettingsDirectory = Join-Path $env:SystemDrive 'Users\Default\AppData\Roaming\Code\User'
New-Item -ItemType Directory -Path $vscodeSettingsDirectory -Force | Out-Null
$vscodeSettings = @{ 'terminal.integrated.fontFamily' = "'$fontFace'" } | ConvertTo-Json
[IO.File]::WriteAllText((Join-Path $vscodeSettingsDirectory 'settings.json'), $vscodeSettings, [Text.UTF8Encoding]::new($false))

## Lab wallpaper through local user Group Policy, the method Microsoft's FederalAVD example uses; values copied from the Default hive were overwritten at first sign-in (checked on a rebuilt host).
$wallpaperDirectory = Join-Path $env:SystemRoot 'Web\Wallpaper\MsftLabs'
New-Item -ItemType Directory -Path $wallpaperDirectory -Force | Out-Null
$wallpaper = Join-Path $wallpaperDirectory 'host_bg.png'
if (-not (Test-Path -LiteralPath 'C:\Windows\Temp\host_bg.png')) { throw 'host_bg.png was not uploaded to C:\Windows\Temp.' }
Copy-Item -LiteralPath 'C:\Windows\Temp\host_bg.png' -Destination $wallpaper -Force
Remove-Item -LiteralPath 'C:\Windows\Temp\host_bg.png' -Force

$policyDirectory = Join-Path $env:SystemRoot 'System32\GroupPolicy'
$policyFile = Join-Path $policyDirectory 'User\Registry.pol'
$gptFile = Join-Path $policyDirectory 'gpt.ini'
if ((Test-Path -LiteralPath $policyFile) -or (Test-Path -LiteralPath $gptFile)) { throw "Local Group Policy already exists in $policyDirectory; merge instead of overwriting." }

# MS-GPREG Registry.pol: 'PReg' + version 1, then [key;value;type;size;data] entries in UTF-16LE.
$policyKey = 'Software\Microsoft\Windows\CurrentVersion\Policies\System'
$policyValues = @(
    @{ Name = 'Wallpaper'; Data = $wallpaper }
    @{ Name = 'WallpaperStyle'; Data = '10' }
)
$stream = [IO.MemoryStream]::new()
$writer = [IO.BinaryWriter]::new($stream)
$writer.Write([Text.Encoding]::ASCII.GetBytes('PReg'))
$writer.Write([uint32]1)
foreach ($value in $policyValues) {
    $data = [Text.Encoding]::Unicode.GetBytes($value.Data + [char]0)
    $writer.Write([byte[]](0x5B, 0x00))
    $writer.Write([Text.Encoding]::Unicode.GetBytes($policyKey + [char]0))
    $writer.Write([byte[]](0x3B, 0x00))
    $writer.Write([Text.Encoding]::Unicode.GetBytes($value.Name + [char]0))
    $writer.Write([byte[]](0x3B, 0x00))
    $writer.Write([uint32]1)
    $writer.Write([byte[]](0x3B, 0x00))
    $writer.Write([uint32]$data.Length)
    $writer.Write([byte[]](0x3B, 0x00))
    $writer.Write($data)
    $writer.Write([byte[]](0x5D, 0x00))
}
$writer.Flush()
New-Item -ItemType Directory -Path (Split-Path $policyFile) -Force | Out-Null
[IO.File]::WriteAllBytes($policyFile, $stream.ToArray())
$writer.Dispose()
$stream.Dispose()

# User policy version 1 (high word) and the Registry CSE with its user tool extension GUID, as FederalAVD writes them.
$gpt = "[General]`r`ngPCUserExtensionNames=[{35378EAC-683F-11D2-A89A-00C04FBBCFA2}{D02B1F73-3407-48AE-BA88-E8213C6761F1}]`r`nVersion=65536`r`n"
[IO.File]::WriteAllText($gptFile, $gpt, [Text.Encoding]::ASCII)

Write-Output 'Tool installs completed.'
