# vCluster on `xeon-local` — Architecture & Runbook

Authoritative description of the setup: how it's wired, the design decisions, and
the exact steps to operate it. **Status: live and verified** (vcluster APIs and
tenant-app auto-publish both reachable from the internet).

---

## 1. Big picture

```
                              INTERNET
                                 │
                                 ▼
                        ┌─────────────────────────┐
                        │   Cloudflare (DNS + TLS) │  Universal SSL (1-level)
                        └────────────┬────────────┘
        ┌────────────────────────────┼───────────────────────────────┐
        │ production tunnel f7f3c592  │  vcluster tunnel 82051912      │
        │ (token/dashboard-managed)   │  (locally-managed, config.yml) │
        │  chat / k8s / rdp / .ovh    │  ec-0X APIs + tenant apps      │
        └────────────────────────────┼───────────────────────────────┘
                                 ▼ (both connectors run in-cluster)
   host cluster  xeon-local  (single node: nicolfo-xeon, k8s v1.34.1)
   ┌──────────────────────────────────────────────────────────────────┐
   │  ns cloudflared           : cloudflared  (prod tunnel, untouched)  │
   │  ns cloudflared-vcluster  : cloudflared-vcluster (our tunnel)      │
   │       └─ config.yml: catch-all -> https://traefik:443 (noTLSVerify)│
   │  Traefik (ClusterIP)                                               │
   │     ├── IngressRoute ec-0X-api ───► svc/ec-0X:443  (vcluster API)  │
   │     └── synced app Ingresses   ───► tenant app pods                │
   │  External-DNS  : writes one Cloudflare CNAME per synced app        │
   │  ns vcluster-ec-00 … vcluster-ec-09 : the 10 virtual clusters      │
   └──────────────────────────────────────────────────────────────────┘
```

Two hostname types, both served by the **dedicated `vcluster` tunnel** → Traefik:

| Hostname               | Serves                         | Routed by                                  |
|------------------------|--------------------------------|--------------------------------------------|
| `ec-0X.nicolfo.it`     | vcluster **API** (kubectl)     | `IngressRoute ec-0X-api` → `svc/ec-0X:443`  |
| `<vc>-<app>.nicolfo.it`| tenant **apps**                | synced `Ingress` → tenant service          |

---

## 2. The key decision: a dedicated, locally-managed tunnel

The pre-existing production tunnel (`f7f3c592`) is **token/dashboard-managed**, so
cloudflared fetches its config from Cloudflare and **ignores any local `config.yml`**.
That makes it impossible to add a `catch-all → Traefik` (needed for app
auto-publish) without editing Cloudflare's remote config via API, and risky to
repurpose (it also serves `rdp://`, `.ovh` hosts, warp-routing).

So we run a **separate, locally-managed tunnel** named **`vcluster`**
(`82051912-b874-49e9-955b-7a73552b75bc`), created with `cloudflared tunnel create`:

- Locally-managed → its `config.yml` **is** honored, and we can set `noTLSVerify`
  on the catch-all (the dashboard UI can't).
- Fully isolated → the production tunnel and all its routes are untouched.
- Runs as its own Deployment `cloudflared-vcluster` in ns `cloudflared-vcluster`.

(Earlier dead ends, for the record: editing the prod tunnel's ConfigMap — ignored;
overriding the prod connector to config-file mode — remote config still won.)

---

## 3. No-wildcard DNS model

- App hostnames are **one label deep** (`ec00-app.nicolfo.it`) → covered by free
  Universal SSL.
- Per-app **explicit** proxied CNAMEs (created by External-DNS) → no broad wildcard.
- The tunnel's single **catch-all → Traefik** is safe: a host only reaches the
  tunnel if it has a DNS record, and Traefik 404s anything it has no Ingress for.

### External-DNS gotcha (important)
The `ingress` source does **not** synthesize a target from `--default-targets`
alone — an app Ingress needs the annotation
`external-dns.alpha.kubernetes.io/target` to be considered at all. **But** when
`--default-targets` is set, it then **overrides** the final target value. Net rule:
keep `--default-targets` **equal to** the tunnel CNAME and set the same value in the
annotation. Both live in `external-dns/external-dns.yaml` and
`examples/tenant-app-ingress.yaml` (currently `82051912-…cfargotunnel.com`).

---

## 4. Current state (all live & verified)

- ✅ vCluster CLI v0.34.2 → `~/.local/bin/vcluster`
- ✅ 10 vclusters `ec-00..ec-09` (+ `demo`), ingress-sync enabled, 5Gi `local-path` PVCs
- ✅ API exposure: `IngressRoute ec-0X-api` (+ `ServersTransport`) per vcluster
- ✅ Per-vcluster kubeconfigs in `kubeconfigs/` (cluster-admin, 24h, public-TLS)
- ✅ Dedicated tunnel `vcluster` (`82051912`) + connector `cloudflared-vcluster`
- ✅ 10 DNS CNAMEs `ec-0X.nicolfo.it → 82051912-…cfargotunnel.com` (proxied)
- ✅ External-DNS auto-creating app CNAMEs (target = the `vcluster` tunnel)
- ✅ Verified: `https://ec-00.nicolfo.it` API = 200; `ec00-web.nicolfo.it` app = 200;
  `chat`/`k8s` (prod tunnel) still 200

## 5. How to operate

| Task | Command |
|---|---|
| Deploy/redeploy the vcluster connector | `./cloudflared/deploy-dedicated-connector.sh` |
| Create N vclusters | `./scripts/06-create-many.sh <prefix> <count>` |
| Expose a vcluster's API | `./scripts/07-expose-ingress.sh <name> <host>` |
| API DNS records | `CF_API_TOKEN=xxx DOMAIN=<domain> ./scripts/09-route-dns.sh ec-0X.<domain>` (proxied CNAME via the API token — works on any zone the token covers; `cloudflared tunnel route dns` is NOT used because its cert.pem is scoped to the login zone) |
| Mint a kubeconfig | `SERVER=… CLUSTER_ROLE=… PUBLIC_TLS=1 ./scripts/03-grant-access.sh <name> <ns> <out>` |
| Tenant publishes an app | apply an `Ingress` inside the vcluster — class `traefik`, host `<vc>-<app>.nicolfo.it`, **+ target annotation** (see `examples/tenant-app-ingress.yaml`) |
| Revoke a kubeconfig | `vcluster connect <name> -n <ns> -- kubectl -n kube-system delete sa admin-user` |
| Delete a vcluster | `vcluster delete <name> --namespace vcluster-<name>` (or `./scripts/uninstall.sh` for the whole stack) |

## 6. Constraints / gotchas
- **App hostnames one label deep** (`x.nicolfo.it`) for TLS (Universal SSL).
- Keep `--default-targets` and the app target annotation equal to the tunnel CNAME (§3).
- The **production tunnel `f7f3c592` is independent** — if you ever added a temporary
  catch-all to it during setup, remove it; vcluster traffic uses the `vcluster` tunnel.
- Single node — 11 control planes + workloads on `nicolfo-xeon`; watch disk/mem.
- Tunnel credentials live in secret `cloudflared-vcluster/tunnel-creds`; the source
  JSON is on the host at `~/.cloudflared/82051912-….json` (keep it safe).
