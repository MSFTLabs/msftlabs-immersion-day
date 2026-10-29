# Changelog

A new Packer image build starts when this file changes on `main`. The build publishes the version in the first `## [x.y.z]` heading to the Azure Compute Gallery, and skips the build when that version already exists. Add a new heading at the top for every image change, and follow [Semantic Versioning](https://semver.org/).

## [1.0.2] - 2026-10-29

### Changed

- Markdone (pinned zip, SHA256-checked, installed to `C:\Program Files\Markdone`) replaces MarkView; `C:\labs\LabGuideExample.md` opens in it at every user logon.
- Dark mode and the lab wallpaper (`host_bg.png`, copied to `C:\Windows\Web\Wallpaper\MsftLabs`) are the defaults for new users, set in the Default user hive.

### Fixed

- The VS Code integrated terminal uses `MesloLGM Nerd Font` (set in the Default profile `settings.json`, copied to each new user), so Oh My Posh glyphs no longer render as boxes.

## [1.0.1] - 2026-10-29

### Added

- Chocolatey-managed machine-wide tools: PowerShell 7, Azure CLI, Git, Visual Studio Code and Bicep.
- MarkView (pinned MSI) for reading Markdown lab guides.
- Oh My Posh as a pinned, signed standalone binary on the machine PATH (the Chocolatey package is a per-user MSIX that Sysprep rejects), started from the all-users PowerShell 7 profile.
- Meslo Nerd Font registered machine-wide (copied to `C:\Windows\Fonts` and HKLM) and a Windows Terminal fragment that sets it as the font.
- The repository `labs/` folder uploaded to `C:\labs`.
- `C:\labs\LabGuideExample.md` opens in MarkView at every user logon (machine-wide `Run` key).

### Removed

- The user-run `C:\Scripts\Install-OhMyPosh.ps1` since this will now be baked in via Chocolatey.

## [1.0.0] - 2026-10-25

### Added

- Windows 11 Enterprise multi-session image with PowerShell 7, Azure CLI, Git, Visual Studio Code and Bicep, built privately on the in-VNet runner.
