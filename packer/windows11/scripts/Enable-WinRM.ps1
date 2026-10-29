## Packer bootstrap Script
$ErrorActionPreference = 'Stop'

Enable-PSRemoting -Force -SkipNetworkProfileCheck

New-NetFirewallRule -Name 'Packer WinRM HTTP' -DisplayName 'Packer WinRM HTTP 5985' -Enabled True -Profile Any -Action Allow -Direction Inbound -LocalPort 5985 -Protocol TCP

Set-Item -Path WSMan:\localhost\Service\Auth\Negotiate -Value $true

## Turns out Packer's NTLM client does not seal the SOAP body, so HTTP 5985 needs this.
Set-Item -Path WSMan:\localhost\Service\AllowUnencrypted -Value $true
Set-Item -Path WSMan:\localhost\MaxTimeoutms -Value 1800000
Restart-Service -Name WinRM
