#!/usr/bin/env bash
# Generate a standalone kubeconfig that you can hand to someone so they can
# access a virtual cluster -- WITHOUT giving them any access to the host cluster.
#
# Usage:
#   ./scripts/03-grant-access.sh [name] [namespace] [output-file]
#
# Env vars:
#   SERVER          External URL the recipient will reach the vcluster API on.
#                   If unset, the printed kubeconfig points at https://localhost:<port>
#                   and the recipient must run `vcluster connect`/port-forward
#                   themselves. For real remote access, expose the vcluster Service
#                   (Ingress/LoadBalancer/NodePort) and pass its URL here, e.g.
#                   SERVER=https://demo.vcluster.example.com
#   SA              ServiceAccount to bind, as namespace/name (default: kube-system/admin-user)
#   CLUSTER_ROLE    ClusterRole to bind to the SA (default: cluster-admin)
#   TTL             Token lifetime in seconds (default: 86400 = 24h)
set -euo pipefail

NAME="${1:-demo}"
NAMESPACE="${2:-vcluster-${NAME}}"
OUT="${3:-./kubeconfig-${NAME}.yaml}"
HOST_CONTEXT="${HOST_CONTEXT:-xeon-local}"
SA="${SA:-kube-system/admin-user}"
CLUSTER_ROLE="${CLUSTER_ROLE:-cluster-admin}"
TTL="${TTL:-86400}"

args=(
  connect "${NAME}"
  --namespace "${NAMESPACE}"
  --context "${HOST_CONTEXT}"
  --print                              # write kubeconfig to stdout, do not switch our context
  --service-account "${SA}"            # token-based auth (not the admin client cert)
  --cluster-role "${CLUSTER_ROLE}"     # creates the SA + ClusterRoleBinding inside the vcluster
  --token-expiration "${TTL}"
)
[[ -n "${SERVER:-}" ]] && args+=(--server "${SERVER}")

echo ">> Generating kubeconfig for vcluster '${NAME}' (SA=${SA}, role=${CLUSTER_ROLE}, ttl=${TTL}s)"
vcluster "${args[@]}" > "${OUT}"
chmod 600 "${OUT}"

# PUBLIC_TLS=1 : the recipient reaches SERVER via a publicly-trusted cert
# (e.g. behind Cloudflare/Let's Encrypt), so drop the embedded vcluster CA and
# let kubectl validate against the system root store -- no --insecure needed.
if [[ "${PUBLIC_TLS:-0}" == "1" ]]; then
  clu="$(kubectl --kubeconfig "${OUT}" config view -o jsonpath='{.clusters[0].name}')"
  kubectl --kubeconfig "${OUT}" config unset "clusters.${clu}.certificate-authority-data" >/dev/null
  echo ">> Stripped vcluster CA (PUBLIC_TLS=1) -> uses system root CAs"
fi

echo ">> Wrote ${OUT}"
echo ">> The recipient uses it with:   KUBECONFIG=${OUT} kubectl get ns"
if [[ -z "${SERVER:-}" ]]; then
  echo "!! NOTE: SERVER not set -> kubeconfig points at localhost. For remote use, expose the vcluster Service and re-run with SERVER=https://..."
fi
