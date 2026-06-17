# Automatic DNS for tenant apps (External-DNS + Cloudflare tunnel)

Goal: a tenant creates an `Ingress` inside their vcluster and the app becomes
reachable from the internet **with no manual Cloudflare work** — and **without**
any broad `*.nicolfo.it` wildcard.

## How it works

```
tenant creates Ingress in ec-00      (host: ec00-app.nicolfo.it, class: traefik)
   │  vcluster syncs it to host ns vcluster-ec-00  (label vcluster.loft.sh/managed-by=ec-00)
   ▼
External-DNS (host cluster) sees the synced Ingress
   │  creates a proxied CNAME:  ec00-app.nicolfo.it -> <tunnel-id>.cfargotunnel.com
   ▼
Cloudflare tunnel catch-all rule -> Traefik -> routes by Host -> tenant pod ✅
```

Two pieces, set up once:

1. **External-DNS** — `external-dns/external-dns.yaml`, deployed by
   `scripts/08-deploy-external-dns.sh`. It is scoped so it only ever manages
   vcluster-synced Ingresses (`--label-filter vcluster.loft.sh/managed-by`) in the
   `nicolfo.it` zone, and only deletes records it created (TXT registry). Your
   existing `chat.nicolfo.it` etc. are never touched.
2. **One tunnel catch-all rule** — baked into the dedicated `vcluster` tunnel's
   `config.yml` (`cloudflared/deploy-dedicated-connector.sh`). Reachability stays
   gated by the per-app DNS records, so this is **not** a wildcard exposure.

## Step 1 — create the Cloudflare API token

1. Cloudflare dashboard → top-right profile → **My Profile** → **API Tokens**
   (direct: https://dash.cloudflare.com/profile/api-tokens).
2. **Create Token** → use the **"Edit zone DNS"** template (or Create Custom Token).
3. Configure:
   - **Permissions:** `Zone` → `DNS` → `Edit`.
     (Add `Zone` → `Zone` → `Read` too — External-DNS lists zones to find `nicolfo.it`.)
   - **Zone Resources:** `Include` → `Specific zone` → **`nicolfo.it`**.
     (Scoping to the one zone is least-privilege; don't grant "All zones".)
   - **TTL / Client IP filtering:** optional, can leave default.
4. **Continue to summary** → **Create Token** → copy the token value
   (shown once). It looks like a ~40-char string.
5. (Optional) verify it:
   ```bash
   curl -s -H "Authorization: Bearer <TOKEN>" \
     https://api.cloudflare.com/client/v4/user/tokens/verify | grep -o '"status":"active"'
   ```

> Security: this token can edit DNS for `nicolfo.it` only. Store it safely; it is
> kept in-cluster as the `cloudflare-api-token` Secret, not in this repo.

## Step 2 — deploy External-DNS

```bash
CF_API_TOKEN=<your-token> ./scripts/08-deploy-external-dns.sh
# or run without the env var to be prompted (input hidden)
kubectl -n external-dns logs -f deploy/external-dns
```

## Step 3 — the catch-all lives in the dedicated tunnel

The `catch-all → Traefik` (with `noTLSVerify`) is part of the **dedicated
`vcluster` tunnel's** `config.yml`, deployed by
`./cloudflared/deploy-dedicated-connector.sh` (see `docs/architecture.md`). No edit
to the production tunnel is needed — that's the whole point of using a separate,
locally-managed tunnel. So once that connector is running and `--default-targets`
points at the `vcluster` tunnel, app records auto-route with no extra step.

## Using it (tenant side)

Inside any vcluster, create a normal Ingress with a **one-level** host
(so Cloudflare Universal SSL covers it) and class `traefik`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp
spec:
  ingressClassName: traefik
  rules:
    - host: ec00-myapp.nicolfo.it      # one label deep, e.g. <vc>-<app>.nicolfo.it
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: { name: myapp, port: { number: 80 } }
```

Within ~1 minute the CNAME appears in Cloudflare and the app is live at
`https://ec00-myapp.nicolfo.it`. Delete the Ingress and External-DNS removes the
record (policy `sync`).

## Notes
- **Hostname depth:** keep app hosts one label deep (`x.nicolfo.it`). Deeper names
  like `app.ec-00.nicolfo.it` need Cloudflare Advanced Certificate Manager for TLS.
- **Collisions:** all vclusters share host Traefik; a `<vc>-<app>` naming
  convention keeps hostnames unique per tenant.
- **Owner safety:** `--txt-owner-id=external-dns-xeon` + `--txt-prefix=edns-` mean
  External-DNS only manages records it created; it won't delete pre-existing ones.
