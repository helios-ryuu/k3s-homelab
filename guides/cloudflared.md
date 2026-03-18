# Cloudflare Tunnel

> Namespace: `cloudflared` | ArgoCD App: `cloudflared` | Chart: local `services/cloudflared/`

---

## Exposed Services

| Subdomain | Backend service | Public URL |
|-----------|----------------|------------|
| `argocd` | `argocd-server.argocd:80` | `https://argocd.helios.id.vn` |
| `grafana` | `monitoring-grafana.monitoring:80` | `https://grafana.helios.id.vn` |
| `loki` | `loki.logging:3100` | `https://loki.helios.id.vn` |
| `localstack` | `localstack.localstack:4566` | `https://localstack.helios.id.vn` |
| `headlamp` | `headlamp.kube-system:80` | `https://headlamp.helios.id.vn` |

> Add new services via Cloudflare Dashboard → Zero Trust → Networks → Tunnels → `k3s` → **Public Hostname** → Add

---

## Operations

```bash
# Config changes: edit services/cloudflared/values.yaml → git push → ArgoCD auto-syncs

# Manual sync trigger (acd helper — see README.md)
acd app sync cloudflared
acd app wait cloudflared --health

# Logs
kubectl logs -n cloudflared -l app=cloudflared -f
```

### Update Tunnel Token

1. Cloudflare Dashboard → Tunnels → `k3s` → **Configure** → copy new token
2. Update `.env` with new `CLOUDFLARE_TOKEN`
3. Re-seal and commit (see SETUP.md step 3.8): `kubeseal ... > secrets/infra-secrets-cloudflared.yaml && git push`
4. `kubectl rollout restart deployment/cloudflared -n cloudflared`

---

## How It Works

```
Internet → Cloudflare Edge (SSL) → Tunnel → cloudflared pod → K8s Service
```

- cloudflared creates **outbound** connections — no public IP needed, no inbound ports
- SSL terminated at Cloudflare edge
- Routing configured entirely on Cloudflare Dashboard — no cluster changes needed for new routes

---

## Add a New Service

1. Cloudflare Dashboard → Zero Trust → Networks → Tunnels → `k3s` → **Public Hostname** → **Add**
2. Fill in:
   - Subdomain: `<name>`
   - Domain: `helios.id.vn`
   - Type: `HTTP`
   - URL: `<service>.<namespace>.svc.cluster.local:<port>`
3. Save — no cloudflared redeploy needed

---

## Troubleshooting

```bash
kubectl logs -n cloudflared -l app=cloudflared
kubectl describe pod -n cloudflared -l app=cloudflared
```

| Error | Cause | Fix |
|-------|-------|-----|
| `ERR Failed to connect` | Bad or expired token | Update token + rollout restart |
| `connection reset` | Firewall blocks outbound 443 | Open port 443 outbound |
| `502 Bad Gateway` | Target service not running | Check backend pod |
