# Manual DNS records — vcluster API endpoints

These 10 records make the **kubeconfigs** work (`https://ec-0X.nicolfo.it`). They
are **manual & one-time** because the API endpoints are Traefik *IngressRoute*
CRDs, which External-DNS's `ingress` source does not watch. (Tenant *app* records
are created automatically by External-DNS — these are only the API endpoints.)

> Why explicit records are required: the zone already has a `*.nicolfo.it` wildcard
> A record (→ 147.135.215.81). Without an explicit record, `ec-0X.nicolfo.it` is
> caught by that wildcard and never reaches the tunnel — which is why the
> kubeconfig fails. An explicit record overrides the wildcard.

## Create in Cloudflare (DNS → Records)

For **each** of `ec-00` … `ec-09`, add:

| Field   | Value                                                      |
|---------|------------------------------------------------------------|
| Type    | `CNAME`                                                    |
| Name    | `ec-0X` (i.e. `ec-00`, `ec-01`, … `ec-09`)                 |
| Target  | `82051912-b874-49e9-955b-7a73552b75bc.cfargotunnel.com`    |
| Proxy   | **Proxied** (orange cloud) ✅                               |
| TTL     | Auto                                                       |

Full names: `ec-00.nicolfo.it`, `ec-01.nicolfo.it`, … `ec-09.nicolfo.it`.

## Or via the Cloudflare API (one loop)

```bash
ZONE_ID=<your nicolfo.it zone id>
CF_API_TOKEN=<token with Zone:DNS:Edit>
TUNNEL=82051912-b874-49e9-955b-7a73552b75bc.cfargotunnel.com
for i in $(seq -w 0 9); do
  curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
    -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
    -d "{\"type\":\"CNAME\",\"name\":\"ec-$i\",\"content\":\"$TUNNEL\",\"proxied\":true}" \
    | grep -o '"success":[a-z]*'
done
```

## Verify
```bash
dig +short ec-00.nicolfo.it          # should show Cloudflare IPs (104.x / 172.67.x), not 147.135.215.81
KUBECONFIG=kubeconfigs/kubeconfig-ec-00.yaml kubectl get ns
```
