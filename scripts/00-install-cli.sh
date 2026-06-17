#!/usr/bin/env bash
# Install (or update) the vCluster CLI into ~/.local/bin (already on PATH).
# Usage: ./scripts/00-install-cli.sh [version]
#   version defaults to the latest GitHub release.
set -euo pipefail

VERSION="${1:-}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
OS="linux"
ARCH="amd64"   # adjust to arm64 on a Pi/ARM host

if [[ -z "$VERSION" ]]; then
  VERSION="$(curl -fsSL https://api.github.com/repos/loft-sh/vcluster/releases/latest \
    | grep -m1 '"tag_name"' | cut -d'"' -f4)"
fi

echo ">> Installing vcluster CLI ${VERSION} for ${OS}-${ARCH} into ${INSTALL_DIR}"
mkdir -p "$INSTALL_DIR"
url="https://github.com/loft-sh/vcluster/releases/download/${VERSION}/vcluster-${OS}-${ARCH}"
tmp="$(mktemp)"
curl -fL -o "$tmp" "$url"
install -m 0755 "$tmp" "${INSTALL_DIR}/vcluster"
rm -f "$tmp"

echo ">> Done:"
"${INSTALL_DIR}/vcluster" version
