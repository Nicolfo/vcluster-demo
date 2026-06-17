#!/usr/bin/env bash
# Create N virtual clusters named <prefix>-00 .. <prefix>-(N-1), in parallel,
# each in its own namespace "vcluster-<name>", then wait until all are ready.
#
# Usage: ./scripts/06-create-many.sh [prefix] [count]
#   prefix defaults to "ec"
#   count  defaults to 10
set -euo pipefail

PREFIX="${1:-ec}"
COUNT="${2:-10}"
HOST_CONTEXT="${HOST_CONTEXT:-xeon-local}"
VALUES="${VALUES:-$(dirname "$0")/../vcluster.yaml}"

names=()
for i in $(seq 0 $((COUNT - 1))); do names+=("$(printf "%s-%02d" "$PREFIX" "$i")"); done

echo ">> Creating ${COUNT} vclusters: ${names[0]} .. ${names[-1]} (context ${HOST_CONTEXT})"
for name in "${names[@]}"; do
  # --upgrade: create if missing, otherwise apply the (possibly changed) values
  # to the existing vcluster in place. Makes this script / install.sh re-runnable.
  vcluster create "$name" --namespace "vcluster-$name" \
    --context "$HOST_CONTEXT" --values "$VALUES" --upgrade \
    --connect=false --add=false >"/tmp/vc-$name.log" 2>&1 &
done
wait

echo ">> Waiting for control planes to become ready..."
for name in "${names[@]}"; do
  kubectl --context "$HOST_CONTEXT" -n "vcluster-$name" \
    wait --for=condition=ready pod -l app=vcluster --timeout=300s >/dev/null 2>&1 &
done
wait

echo ">> Done:"
vcluster list
