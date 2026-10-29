# Changelog

A new Packer image build starts when this file changes on `main`. The build publishes the version in the first `## [x.y.z]` heading to the Azure Compute Gallery, and skips the build when that version already exists. Add a new heading at the top for every image change, and follow [Semantic Versioning](https://semver.org/).

## [1.0.1] - 2026-10-29

### Added

- Chocolatey-managed machine-wide tools: PowerShell 7, Azure CLI, Git, Visual Studio Code, Bicep and Oh My Posh.
- MarkView (pinned MSI) for reading Markdown lab guides.
- Meslo Nerd Font installed system-wide, Oh My Posh in the all-users PowerShell 7 profile and a Windows Terminal fragment that sets the font.
- The repository `labs/` folder uploaded to `C:\labs`.
- `C:\labs\LabGuideExample.md` opens in MarkView at every user logon (machine-wide `Run` key).

### Removed

- The user-run `C:\Scripts\Install-OhMyPosh.ps1` since this will now be baked in via Chocolatey. 

## [1.0.0] - 2026-10-25

### Added

- Windows 11 Enterprise multi-session image with PowerShell 7, Azure CLI, Git, Visual Studio Code and Bicep, built privately on the in-VNet runner.
