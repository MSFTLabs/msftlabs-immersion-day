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

## MarkView is not in Chocolatey; the vendor MSI (ALLUSERS=1) is pinned by version and SHA256.
$markView = @{
    Url    = 'https://markview.io/releases/v0.3.30/MarkView_0.3.30_x64_en-US.msi'
    Sha256 = 'F3BD9D45185B337E2EA74FD2775501AC7205F529A5FD7B8C80C50CFCCB44D440'
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

## MarkView
$msi = Join-Path $env:TEMP 'MarkView.msi'
Invoke-WebRequest -Uri $markView.Url -OutFile $msi -UseBasicParsing
$hash = (Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash
if ($hash -ne $markView.Sha256) { throw "MarkView MSI hash mismatch: expected $($markView.Sha256), got $hash." }
if ((Get-AuthenticodeSignature -LiteralPath $msi).Status -ne 'Valid') { throw 'MarkView MSI signature is not valid.' }
$process = Start-Process -FilePath msiexec.exe -ArgumentList @('/i', "`"$msi`"", '/qn', '/norestart', 'ALLUSERS=1', '/l*v', "`"$env:TEMP\MarkView.msi.log`"") -Wait -PassThru
if ($process.ExitCode -notin @(0, 3010)) { throw "MarkView MSI install failed with exit code $($process.ExitCode); see $env:TEMP\MarkView.msi.log." }
Remove-Item -LiteralPath $msi -Force

## Open the lab guide in MarkView at every logon; the MSI installs to Program Files\MarkView (INSTALLDIR in the MSI Directory table).
$markViewExe = Join-Path $env:ProgramFiles 'MarkView\markview.exe'
if (-not (Test-Path -LiteralPath $markViewExe)) { throw "MarkView was not found at $markViewExe." }
$logonCommand = "`"$markViewExe`" `"C:\labs\LabGuideExample.md`""
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

Write-Output 'Tool installs completed.'
