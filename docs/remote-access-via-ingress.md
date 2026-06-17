# Giving a friend remote access to a vcluster (via ingress + Cloudflare tunnel)

This is how `kubeconfig-friend-demo.yaml` was produced and how the friend uses it.

## Traffic flow

```
friend's kubectl
   │  HTTPS  (server: https://vcluster-demo.nicolfo.it, token auth)
   ▼
Cloudflare edge        ← presents a real *.nicolfo.it cert (friend validates this)
   │  tunnel
   ▼
cloudflared ──► Traefik (websecure :443)        ← IngressRoute matches the Host
   │  HTTPS (re-encrypt, insecureSkipVerify on this internal hop only)
   ▼
svc/demo:443  →  vcluster "demo" API server     ← validates the SA token
```

The friend only ever holds a **ServiceAccount token** scoped to the vcluster
(`cluster-admin` *inside* the vcluster, nothing on the host). No client cert,
no host access.

## The three pieces

### 1. In-cluster ingress resource — `ingress/vcluster-demo-ingressroute.yaml`
A Traefik `IngressRoute` (host `vcluster-demo.nicolfo.it`, websecure entrypoint)
pointing at `svc/demo:443` with `scheme: https`, plus a `ServersTransport` with
`insecureSkipVerify: true` (the vcluster's backend cert is self-signed for its
internal name; this only affects the Traefik→vcluster hop).

```bash
kubectl apply -f ingress/vcluster-demo-ingressroute.yaml
```

### 2. Cloudflare tunnel route
Mirror the existing `k8s-xeon.nicolfo.ovh` entry, but target Traefik:

```yaml
- hostname: vcluster-demo.nicolfo.it
  service: https://traefik.ingress.svc.cluster.local:443
  originRequest:
    noTLSVerify: true
```
(Add to the tunnel's `config.yml` ConfigMap, then restart the `cloudflared` deployment.)

### 3. DNS
CNAME `vcluster-demo.nicolfo.it` → `<tunnel-id>.cfargotunnel.com` (proxied),
same as the other tunnel hostnames.

## The kubeconfig

Generated with:

```bash
SERVER=https://vcluster-demo.nicolfo.it CLUSTER_ROLE=cluster-admin TTL=86400 \
  ./scripts/03-grant-access.sh demo vcluster-demo ./kubeconfig-friend-demo.yaml
```

then the embedded vcluster CA was removed so kubectl trusts Cloudflare's public
cert via the system root store (no `insecure-skip-tls-verify` needed):

```bash
kubectl --kubeconfig kubeconfig-friend-demo.yaml \
  config unset clusters.vcluster_demo_vcluster-demo_xeon-local.certificate-authority-data
```

> Verified: the token authenticates as `system:serviceaccount:kube-system:admin-user`
> and has `cluster-admin` inside the vcluster.

## What the friend does

```bash
export KUBECONFIG=./kubeconfig-friend-demo.yaml
kubectl get ns
kubectl create deploy web --image=nginx
```

That's it — the file is self-contained. The token expires after 24h (`TTL`);
re-run the generate command to reissue. To revoke immediately, delete the SA
inside the vcluster:

```bash
vcluster connect demo -n vcluster-demo -- kubectl -n kube-system delete sa admin-user
```

## Security notes
- The kubeconfig contains a **live token** — send it over a secure channel; it is
  git-ignored in this repo.
- `cluster-admin` is scoped to the *virtual* cluster only. The host cluster
  (`xeon-local`) is never exposed to the friend.
- The public hop is TLS-verified by Cloudflare; `insecureSkipVerify`/`noTLSVerify`
  apply only to internal hops to the self-signed vcluster backend.
- `exec`, `logs`, and `port-forward` use connection upgrades — Traefik and the
  Cloudflare tunnel both support these, so they work through the chain.
