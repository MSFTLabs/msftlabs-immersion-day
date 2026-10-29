[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

## BitLocker must be fully decrypted before Sysprep.
$osVolume = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction SilentlyContinue
if ($osVolume -and $osVolume.VolumeStatus -ne 'FullyDecrypted') {
    Write-Output 'Decrypting the build VM OS volume before Sysprep.'
    Disable-BitLocker -MountPoint $env:SystemDrive | Out-Null
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ((Get-BitLockerVolume -MountPoint $env:SystemDrive).VolumeStatus -ne 'FullyDecrypted') {
        if ($timer.Elapsed.TotalMinutes -ge 15) { throw 'OS-volume decryption exceeded 15 minutes; Sysprep will not run.' }
        Start-Sleep -Seconds 10
    }
}

## Documented Packer azure-arm Sysprep sequence. Spent way more time getting this to work with newer Gen2 BitLocker based images than I care to admit..
while ($true) {
    $services = Get-Service -Name RdAgent, WindowsAzureTelemetryService, WindowsAzureGuestAgent -ErrorAction SilentlyContinue
    if (@($services | Where-Object { $_.Status -ne 'Running' }).Count -eq 0) { break }
    Write-Output "Waiting for Azure guest services: $(($services | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ', ')"
    Start-Sleep -Seconds 5
}

if (Test-Path "$env:SystemRoot\System32\Sysprep\unattend.xml") { Remove-Item "$env:SystemRoot\System32\Sysprep\unattend.xml" -Force }
& "$env:SystemRoot\System32\Sysprep\Sysprep.exe" /oobe /generalize /quiet /quit /mode:vm

while ($true) {
    $imageState = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State').ImageState
    Write-Output "ImageState: $imageState"
    if ($imageState -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { break }
    Start-Sleep -Seconds 10
}
Write-Output 'Sysprep completed; Packer will stop and capture the generalized VM.'
