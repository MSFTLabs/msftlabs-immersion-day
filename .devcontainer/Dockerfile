FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ARG PACKER_VERSION=1.16.1
ARG TOFU_VERSION=1.13.1

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl gnupg jq unzip \
    && rm -rf /var/lib/apt/lists/*

# HashiCorp's documented verification: a PGP-signed SHA256SUMS, then the archive checksum.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    base="https://releases.hashicorp.com/packer/${PACKER_VERSION}"; \
    cd /tmp; \
    curl -fsSLO "${base}/packer_${PACKER_VERSION}_linux_${arch}.zip"; \
    curl -fsSLO "${base}/packer_${PACKER_VERSION}_SHA256SUMS"; \
    curl -fsSLO "${base}/packer_${PACKER_VERSION}_SHA256SUMS.sig"; \
    curl -fsSL https://www.hashicorp.com/.well-known/pgp-key.txt | gpg --batch --import; \
    gpg --batch --with-colons --fingerprint | grep -q '^fpr:::::::::C874011F0AB405110D02105534365D9472D7468F:'; \
    gpg --batch --verify "packer_${PACKER_VERSION}_SHA256SUMS.sig" "packer_${PACKER_VERSION}_SHA256SUMS"; \
    grep "packer_${PACKER_VERSION}_linux_${arch}.zip" "packer_${PACKER_VERSION}_SHA256SUMS" | sha256sum -c -; \
    unzip -q "packer_${PACKER_VERSION}_linux_${arch}.zip" packer -d /usr/local/bin; \
    rm -rf /tmp/packer_* /root/.gnupg

# OpenTofu release archive checked against the SHA256SUMS published with the release.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    base="https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}"; \
    cd /tmp; \
    curl -fsSLO "${base}/tofu_${TOFU_VERSION}_linux_${arch}.zip"; \
    curl -fsSLO "${base}/tofu_${TOFU_VERSION}_SHA256SUMS"; \
    grep "tofu_${TOFU_VERSION}_linux_${arch}.zip" "tofu_${TOFU_VERSION}_SHA256SUMS" | sha256sum -c -; \
    unzip -q "tofu_${TOFU_VERSION}_linux_${arch}.zip" tofu -d /usr/local/bin; \
    rm -rf /tmp/tofu_*
