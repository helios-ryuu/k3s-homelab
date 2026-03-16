# Cloudflare Tunnel

> Namespace: `cloudflared` | Script: `svc-scripts/cfd.sh` | Chart: local `cloudflared/`

---

## Access

| Subdomain | Backend service | Public URL |
|-----------|----------------|------------|
| `grafana` | `mon-grafana.monitoring:80` | `https://grafana.<your-domain>` |
| `headlamp` | `headlamp.kube-system:80` | `https://headlamp.<your-domain>` |

> Add new services via Cloudflare Dashboard → Tunnels → `k3s` → **Public Hostname** → Add

---

## Operations

```bash
# Via main dispatcher
./k3s.sh deploy cloudflared
./k3s.sh delete cloudflared
./k3s.sh redeploy cloudflared

# Via component script
./svc-scripts/cfd.sh deploy
./svc-scripts/cfd.sh delete
./svc-scripts/cfd.sh redeploy
./svc-scripts/cfd.sh logs               # Tail tunnel logs
```

---

## How It Works

```
Internet → Cloudflare Edge (SSL) → Tunnel → cloudflared pod → K8s Service
```

- cloudflared creates **outbound** connections — no public IP needed, no inbound ports
- SSL automatic (Cloudflare)
- Routing configured on Cloudflare Dashboard (no cluster changes needed)

---

## Tunnel Management

### Cloudflare Dashboard

1. https://one.dash.cloudflare.com → **Networks** → **Tunnels**
2. Tunnel `k3s` → view status, connectors, public hostnames

### Add a new service

1. Dashboard → Tunnels → `k3s` → **Public Hostname** → **Add**
2. Fill in:
   - Subdomain: `<name>`
   - Domain: `<your-domain>`
   - Type: `HTTP`
   - URL: `<service>.<namespace>.svc.cluster.local:<port>`
3. Save — no cloudflared redeploy needed

### Example: expose Prometheus

| Field | Value |
|-------|-------|
| Subdomain | `prometheus` |
| Domain | `<your-domain>` |
| Type | `HTTP` |
| URL | `mon-kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090` |

---

## Update Token

1. Cloudflare Dashboard → Tunnels → `k3s` → **Configure** → copy new token
2. Update `.env` with new `CLOUDFLARE_TOKEN`
3. Run `./init-sec.sh cloudflared` then `./k3s.sh redeploy cloudflared`

---

## Resource Usage

| Component | RAM | CPU | Node |
|-----------|-----|-----|------|
| cloudflared (2 replicas) | ~30-50 MB each | ~10-30m | master |

---

## Troubleshooting

```bash
# View tunnel logs
kubectl logs -n cloudflared -l app=cloudflared

# Describe pod
kubectl describe pod -n cloudflared -l app=cloudflared
```

| Error | Cause | Fix |
|-------|-------|-----|
| `ERR Failed to connect` | Bad or expired token | Update token + redeploy |
| `connection reset` | Firewall blocks outbound | Open port 443 outbound |
| `502 Bad Gateway` | Target service not running | Check backend pod |
