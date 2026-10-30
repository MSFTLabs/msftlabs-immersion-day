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

# Packer signs in through the Azure CLI; use the lab SPN when its Codespaces secrets are present.
if [ -n "${ARM_CLIENT_ID:-}" ] && [ -n "${ARM_CLIENT_SECRET:-}" ]; then
  az login --service-principal --username "$ARM_CLIENT_ID" --password "$ARM_CLIENT_SECRET" --tenant "$ARM_TENANT_ID" --output none
  az account set --subscription "$ARM_SUBSCRIPTION_ID"
  az account show --query '{subscription:name,identity:user.name}' -o tsv
fi

# Downloads the Azure plugin; the first real check that the container can reach the plugin host.
packer init packer/windows11
packer validate -syntax-only packer/windows11
