# vCluster on `xeon-local`

This repo documents installing [vCluster](https://www.vcluster.com/) on the local
host cluster (kube-context **`xeon-local`**, node `nicolfo-xeon`) and provides
reusable scripts to create, connect to, share, and delete virtual clusters.

> **Start here:** [`docs/architecture.md`](./docs/architecture.md) — the authoritative
> architecture, the public-access design decision, and the exact step-by-step runbook.
> Companion doc: [`docs/external-dns.md`](./docs/external-dns.md) (auto-DNS for tenant apps).

---

## What is vCluster?

vCluster runs **fully isolated, virtual Kubernetes clusters _inside_ a namespace
of a real ("host") cluster**. Each virtual cluster has its own API server, its own
control plane, and its own view of namespaces, RBAC, CRDs, etc. — but its actual
workloads (pods) are scheduled onto the host cluster's nodes.

Key concepts:

| Concept | Meaning |
|---|---|
| **Host cluster** | The real cluster (here: `xeon-local`). Runs the vcluster control-plane pod and all synced workloads. |
| **Virtual cluster** | A lightweight K8s API server (a StatefulSet pod) that tenants treat as their own dedicated cluster. |
| **Syncer** | The component that copies pods (and selected resources) from the virtual cluster down to the host namespace, and status back up. |

**Why use it:** strong multi-tenancy and "give each team/customer their own cluster"
without the cost of standing up real clusters. A tenant can be `cluster-admin`
*inside* their vcluster (install CRDs, create namespaces) while having **zero**
access to the host cluster.

### What it looks like in practice

A pod created *inside* the vcluster:

```
# inside vcluster "demo"
$ kubectl get pods
NAME    READY   STATUS    AGE
nginx   1/1     Running   30s
```

…appears on the **host**, namespaced and renamed by the syncer:

```
# on host xeon-local, namespace vcluster-demo
$ kubectl get pods -n vcluster-demo
NAME                                            READY   STATUS    AGE
demo-0                                          1/1     Running   2m     <- the vcluster control plane
coredns-...-x-kube-system-x-demo                1/1     Running   1m     <- synced
nginx-x-default-x-demo                          1/1     Running   30s    <- the synced "nginx" pod
```

---

## What was installed (on 2026-06-16)

1. **vCluster CLI v0.34.2** → `~/.local/bin/vcluster` (already on `PATH`).
   ```bash
   ./scripts/00-install-cli.sh
   ```
2. **A demo virtual cluster** named `demo` in host namespace `vcluster-demo`,
   configured via [`vcluster.yaml`](./vcluster.yaml).

### Host-cluster facts that shaped the config

- StorageClass `local-path` exists but is **not** the default → pinned explicitly
  in `vcluster.yaml` (`controlPlane.statefulSet.persistence.volumeClaim.storageClass`).
- Backing store set to the **OSS embedded database (SQLite on the PVC)**. The
  embedded *etcd* option is a vCluster **Pro** feature and fails without a
  Platform login, so we pass `--add=false` and use the database store.
- Ingress controller is `traefik`; ingress sync is left **off** by default.

---

## Quick start

```bash
# 1. Install/upgrade the CLI (idempotent)
./scripts/00-install-cli.sh

# 2. Create a single virtual cluster "demo" (uses vcluster.yaml)
vcluster create demo --namespace vcluster-demo --values vcluster.yaml --connect=false --add=false

# 3. Run a command inside it without changing your current context
vcluster connect demo -n vcluster-demo -- kubectl get ns

# 4. Or attach your shell to it (adds a kube-context + local proxy)
vcluster connect demo -n vcluster-demo
#    ...switch back to the host any time:
kubectl config use-context xeon-local
#    ...stop the proxy:
vcluster disconnect

# 5. See status
vcluster list

# 6. Tear it down
vcluster delete demo --namespace vcluster-demo
```

> For the full public-access fleet (vclusters + tunnel connector + External-DNS +
> per-vcluster kubeconfigs), use **`./scripts/install.sh`** (prompts for the domain
> and a Cloudflare API token) and **`./scripts/uninstall.sh`** to tear it back down.

---

## Giving someone access to a vcluster

The goal: hand a teammate a kubeconfig that grants **admin inside the vcluster**
and **nothing on the host**. Use [`scripts/03-grant-access.sh`](./scripts/03-grant-access.sh),
which wraps:

```bash
vcluster connect <name> -n <ns> --print \
  --service-account kube-system/admin-user \
  --cluster-role cluster-admin \
  --token-expiration 86400
```

This creates a ServiceAccount + ClusterRoleBinding **inside the vcluster**, mints a
time-limited token, and prints a self-contained kubeconfig (token-based — not the
admin client cert).

```bash
# token-based kubeconfig, 24h TTL, scoped to the vcluster only
./scripts/03-grant-access.sh demo vcluster-demo ./kubeconfig-demo.yaml

# recipient uses it:
KUBECONFIG=./kubeconfig-demo.yaml kubectl get ns
```

### Local vs. remote access — the `server` endpoint

The vcluster API is exposed as a **ClusterIP** Service on the host, so it is not
reachable from outside by default. The printed kubeconfig's `server:` field must
point at something the recipient can actually reach:

- **Same machine / quick test** — leave `SERVER` unset. The kubeconfig points at a
  local proxy port; the recipient runs `vcluster connect demo -n vcluster-demo`
  (or a `kubectl port-forward svc/demo -n vcluster-demo 8443:443`) to open it.
- **Remote teammate (via ingress + Cloudflare tunnel)** — this is exactly how the
  `ec-0X` fleet is exposed and is the **authoritative, live** path. See
  **[docs/architecture.md](./docs/architecture.md)** (dedicated `vcluster` tunnel +
  Traefik `IngressRoute` + External-DNS). Per-vcluster ingress resources live at
  [`ingress/ec-0X-ingressroute.yaml`](./ingress/); generate more with
  `scripts/07-expose-ingress.sh`. Short version:
  ```bash
  ./scripts/07-expose-ingress.sh <vc> <vc>.nicolfo.it          # in-cluster route
  CF_API_TOKEN=xxx DOMAIN=<domain> ./scripts/09-route-dns.sh <vc>.<domain>   # DNS -> vcluster tunnel (API token)
  SERVER=https://<vc>.nicolfo.it CLUSTER_ROLE=cluster-admin TTL=86400 PUBLIC_TLS=1 \
    ./scripts/03-grant-access.sh <vc> vcluster-<vc> ./kubeconfig-<vc>.yaml
  ```
- **Quick alternative — NodePort (same LAN):**
  `kubectl patch svc demo -n vcluster-demo -p '{"spec":{"type":"NodePort"}}'`
  then `SERVER=https://192.168.0.159:<nodePort>` (add `--insecure` to the kubeconfig).

> Verified: the generated SA-token kubeconfig was tested through a port-forward and
> authenticated as `system:serviceaccount:kube-system:admin-user` inside the vcluster.

### Narrower access (least privilege)

Bind a smaller role instead of `cluster-admin`, and/or a shorter TTL:

```bash
CLUSTER_ROLE=view TTL=3600 \
  ./scripts/03-grant-access.sh demo vcluster-demo ./kubeconfig-readonly.yaml
```

---

## Scripts reference

| Script | Purpose |
|---|---|
| `scripts/install.sh` | **Main entrypoint.** Stand up the whole stack; prompts for `DOMAIN` + Cloudflare API token (everything else has a default). |
| `scripts/uninstall.sh` | Tear the stack down (keeps the tunnel + DNS; `PURGE_DNS=1` to also drop records). |
| `scripts/00-install-cli.sh [version]` | Install/upgrade the vcluster CLI into `~/.local/bin`. |
| `scripts/03-grant-access.sh [name] [ns] [out]` | Generate a shareable, token-based kubeconfig. Env: `SERVER`, `SA`, `CLUSTER_ROLE`, `TTL`. |
| `scripts/06-create-many.sh [prefix] [count]` | Create `<prefix>-00..<prefix>-(N-1)` in parallel and wait for ready. |
| `scripts/07-expose-ingress.sh <name> <hostname> [ns]` | Generate+apply a Traefik `IngressRoute` exposing one vcluster at `<hostname>`. `OUT=` to save manifest, `APPLY=0` to dry-run. |
| `scripts/08-deploy-external-dns.sh` | Deploy External-DNS (Cloudflare). Env: `DOMAIN`, `TUNNEL_CNAME`, `CF_API_TOKEN`. |
| `scripts/09-route-dns.sh <host>...` | Create/ensure proxied CNAMEs `<host> -> tunnel` via the Cloudflare API token. Env: `DOMAIN`, `CF_API_TOKEN`, `TUNNEL_ID`. |

> Single-vcluster create/connect/status/delete are just thin wrappers over the
> `vcluster` CLI — use `vcluster create|connect|list|delete` directly (see Quick start).

`03-grant-access.sh` extra flag: `PUBLIC_TLS=1` strips the embedded vcluster CA so
the kubeconfig validates against system root CAs (use when `SERVER` is behind a
publicly-trusted cert like Cloudflare).

### Batch example — the `ec-00..ec-09` fleet

```bash
# 1. create 10 vclusters
./scripts/06-create-many.sh ec 10

# 2. expose each at ec-0X.nicolfo.it and save the manifest under ingress/
for i in $(seq 0 9); do n=$(printf "ec-%02d" "$i"); \
  OUT="ingress/${n}-ingressroute.yaml" ./scripts/07-expose-ingress.sh "$n" "${n}.nicolfo.it"; done

# 3. mint one cluster-admin kubeconfig per cluster (24h), into kubeconfigs/
for i in $(seq 0 9); do n=$(printf "ec-%02d" "$i"); \
  SERVER="https://${n}.nicolfo.it" CLUSTER_ROLE=cluster-admin TTL=86400 PUBLIC_TLS=1 \
  ./scripts/03-grant-access.sh "$n" "vcluster-$n" "kubeconfigs/kubeconfig-${n}.yaml"; done

# delete the whole fleet later (or just run ./scripts/uninstall.sh):
for i in $(seq 0 9); do n=$(printf 'ec-%02d' "$i"); vcluster delete "$n" --namespace "vcluster-$n"; done
```

**Cloudflare side (one-time, covers all 10):** instead of 10 separate routes, add a
single **wildcard** tunnel hostname `*.nicolfo.it → https://traefik.ingress.svc.cluster.local:443`
(`noTLSVerify: true`) plus a wildcard DNS `*.nicolfo.it` CNAME to the tunnel. Then
`ec-00.nicolfo.it … ec-09.nicolfo.it` all resolve automatically.

All scripts default to vcluster `demo` / namespace `vcluster-demo` / host context
`xeon-local`. Override the host context with the `HOST_CONTEXT` env var.

---

## Notes & gotchas

- **OSS vs Pro:** we run pure OSS. Pro/Platform features (embedded etcd, the
  `vcluster platform` UI, sleep mode, etc.) require a Platform login; the create
  script passes `--add=false` to stay in OSS mode.
- **CLI updates:** a newer CLI (v0.35.0) exists; re-run `00-install-cli.sh` to bump.
- **State lives on a PVC** (`local-path`, 5Gi) named after the StatefulSet; deleting
  the namespace removes it. `vcluster delete <name> --namespace vcluster-<name>` (and
  `uninstall.sh`) remove the namespace too.
