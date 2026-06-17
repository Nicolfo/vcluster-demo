# Harbor registry (cluster `sa4`)

A standalone [Harbor](https://goharbor.io/) container/OCI registry, deployed to a
**different cluster** than the vcluster stack — kube-context **`sa4`** — and
published at **https://registry.ff26.it**.

Unlike the `platform/` apps (which ride the Cloudflare tunnel + host External-DNS),
this one uses `sa4`'s own ingress + TLS plumbing:

| Concern      | How                                                                 |
|--------------|---------------------------------------------------------------------|
| Cluster      | kube-context `sa4` (`--kube-context sa4`)                            |
| Ingress      | class `traefik`                                                     |
| TLS / HTTPS  | cert-manager ClusterIssuer **`letsencrypt`** (HTTP-01), secret `harbor-tls` |
| DNS          | `registry.ff26.it` → sa4 Traefik (`51.89.21.199`) — **pre-registered** |
| Storage      | sa4 default StorageClass `local-path`; PVCs kept on uninstall       |
| Chart        | `harbor/harbor` **1.19.1** (Harbor 2.15.1), repo `https://helm.goharbor.io` |

> **Chart version:** the artifacthub link pointed at chart `1.3.2` (appVersion
> 1.10.2, 2020), whose Ingress is `extensions/v1beta1` — removed in k8s v1.22, so
> it cannot install on sa4 (v1.34). We pin the current `1.19.1`, which emits a
> `networking.k8s.io/v1` Ingress with a real `ingressClassName: traefik`.

## Install

```bash
# defaults: context sa4, host registry.ff26.it, ns harbor, admin pw Harbor12345
./registry/install.sh

# set a real admin password (recommended)
HARBOR_ADMIN_PASSWORD='choose-something' ./registry/install.sh
```

`install.sh` adds the Harbor Helm repo, renders `values.yaml` (filling
`${HARBOR_HOST}` / `${HARBOR_ADMIN_PASSWORD}` via `envsubst`), and runs
`helm upgrade --install` into namespace `harbor` on `sa4`.

## Verify

```bash
kubectl --context sa4 -n harbor get pods
kubectl --context sa4 -n harbor get ingress,certificate     # certificate -> Ready=True
curl -sI https://registry.ff26.it/ | head -1                # 200 once the cert is issued

# log in and push (admin / <HARBOR_ADMIN_PASSWORD>); 'library' project exists by default
docker login registry.ff26.it
docker tag alpine:latest registry.ff26.it/library/alpine:latest
docker push registry.ff26.it/library/alpine:latest
```

The Let's Encrypt certificate takes a minute or two after first install (watch
`kubectl --context sa4 -n harbor get certificate harbor-tls -w`).

## Uninstall

```bash
helm --kube-context sa4 -n harbor uninstall harbor
# PVCs are retained (resourcePolicy: keep); drop them explicitly if desired:
# kubectl --context sa4 -n harbor delete pvc --all
```
