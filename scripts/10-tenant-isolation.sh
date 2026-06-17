#!/usr/bin/env bash
# Apply (or with DELETE=1, remove) the ValidatingAdmissionPolicy that confines each
# vcluster's synced tenant Ingresses to its own  <vc>-<app>.<DOMAIN>  host prefix.
#
# Native admission policy — NO Kyverno, NO pods. It is enforced inside the host API
# server; the only footprint is two cluster-scoped objects.
#
# Env:
#   DOMAIN        the published domain (default: nicolfo.it)
#   HOST_CONTEXT  host kube-context  (default: xeon-local)
#   DELETE=1      remove the policy + binding instead of applying
#
# Usage:  DOMAIN=ff26.it ./scripts/10-tenant-isolation.sh
set -euo pipefail

HOST_CONTEXT="${HOST_CONTEXT:-xeon-local}"
DOMAIN="${DOMAIN:-nicolfo.it}"
MANIFEST="$(dirname "$0")/../policy/tenant-isolation.yaml"
K="kubectl --context $HOST_CONTEXT"

if [[ "${DELETE:-0}" == "1" ]]; then
  echo ">> Removing tenant-isolation policy"
  sed "s/nicolfo\.it/${DOMAIN}/g" "$MANIFEST" | $K delete --ignore-not-found -f -
  exit 0
fi

echo ">> Applying tenant-isolation ValidatingAdmissionPolicy (domain=${DOMAIN})"
sed "s/nicolfo\.it/${DOMAIN}/g" "$MANIFEST" | $K apply -f -
