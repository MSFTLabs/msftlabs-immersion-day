#!/usr/bin/env bash
set -euo pipefail

# Named volumes are created root-owned.
sudo chown -R "$(id -u):$(id -g)" "$HOME/.azure" "$HOME/.config/packer"

packer version
tofu version | head -n1
az version --query '"azure-cli"' -o tsv
pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
gh --version | head -n1
jq --version

# Downloads the Azure plugin; the first real check that the container can reach the plugin host.
packer init packer/windows11
packer validate -syntax-only packer/windows11
