#!/usr/bin/env bash
# Remove every platform app from a single vcluster -- the inverse of
# 11-install-platform.sh. Use this to tear platform apps down WITHOUT deleting
# the vcluster itself (uninstall.sh's `vcluster delete` already removes them when
# you drop the whole vcluster).
#
# For each directory under platform/, we run inside the vcluster (via
# `vcluster connect ... --`):  helm uninstall <app> -n <app>  +  delete ns <app>.
# This assumes the install used release name == namespace == the app dir name
# (true for platform/argocd: release "argocd" in namespace "argocd").
#
# Usage: ./scripts/12-uninstall-platform.sh <vc-name> [namespace]
#   e.g. ./scripts/12-uninstall-platform.sh ec-00
#
# Env:
#   HOST_CONTEXT  host kube-context (default: xeon-local)
#   PLATFORM_DIR  where the apps live (default: <repo>/platform)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

NAME="${1:?usage: 12-uninstall-platform.sh <vc-name> [namespace]}"
NAMESPACE="${2:-vcluster-${NAME}}"
HOST_CONTEXT="${HOST_CONTEXT:-xeon-local}"
PLATFORM_DIR="${PLATFORM_DIR:-$here/../platform}"

shopt -s nullglob
apps=("$PLATFORM_DIR"/*/install.sh)
if [[ ${#apps[@]} -eq 0 ]]; then
  echo "   (no platform apps found in ${PLATFORM_DIR})"; exit 0
fi

# Build the per-app teardown commands, run them all in one connection.
cmd=""
for app_install in "${apps[@]}"; do
  app="$(basename "$(dirname "$app_install")")"
  echo "   - [${NAME}] removing platform app '${app}'"
  cmd+="helm uninstall ${app} -n ${app} >/dev/null 2>&1 || true; "
  cmd+="kubectl delete namespace ${app} --ignore-not-found >/dev/null 2>&1 || true; "
done

vcluster connect "$NAME" --namespace "$NAMESPACE" --context "$HOST_CONTEXT" -- \
  bash -c "$cmd"
echo "   - [${NAME}] platform apps removed"
