# Sure — Finance Management App

> Namespace: `sure` | ArgoCD App: `sure` | Manifests: `services/sure/sure-stack.yaml`

---

## Node Labels

```bash
kubectl label node <node> app-host=sure
```

---

## Operations

```bash
# Config changes: edit services/sure/sure-stack.yaml → git push → ArgoCD auto-syncs

# Manual sync trigger (acd helper — see README.md)
acd app sync sure
acd app wait sure --health

# Logs
kubectl logs -n sure -l app=sure-web -f
kubectl logs -n sure -l app=sure-worker -f   # Sidekiq background worker
```

### First-Time Setup

After initial deploy, run database migrations:

```bash
kubectl exec -it -n sure deploy/sure-web -- bundle exec rails db:prepare
```

---

## Architecture

4 Deployments, all `replicas: 1`, pinned to node with label `app-host=sure`:

| Component | Image | Port | Function |
|-----------|-------|------|----------|
| `sure-postgres` | `postgres:18-alpine` | 5432 | PostgreSQL database |
| `sure-redis` | `redis:8-alpine` | 6379 | Redis cache (AOF persistence) |
| `sure-web` | `ghcr.io/we-promise/sure:stable` | 3000 | Rails web server |
| `sure-worker` | `ghcr.io/we-promise/sure:stable` | — | Sidekiq background worker |

---

## Storage (PVC)

| PVC | Size | Mount |
|-----|------|-------|
| `sure-postgres-pvc` | 5Gi | `/var/lib/postgresql/data` |
| `sure-redis-pvc` | 2Gi | `/data` |

> StorageClass: `local-path` (K3s default)

---

## Resource Limits

| Component | CPU Req | CPU Limit | Mem Req | Mem Limit |
|-----------|---------|-----------|---------|-----------|
| Postgres | 100m | 500m | 256Mi | 512Mi |
| Redis | 50m | 200m | 64Mi | 128Mi |
| Web | 100m | 1000m | 256Mi | 512Mi |
| Worker | 100m | 500m | 256Mi | 512Mi |

---

## Access

| Endpoint | URL |
|----------|-----|
| External (Tailscale) | `http://<node-ip>:30333` |
| In-cluster | `http://sure-web-svc.sure.svc.cluster.local:80` |

---

## Health Check

```bash
./ck.sh   # section: Resources → sure namespace

kubectl get pods -n sure
kubectl exec -n sure deploy/sure-postgres -- pg_isready
kubectl exec -n sure deploy/sure-redis -- redis-cli ping
curl -s -o /dev/null -w "%{http_code}" http://<node-ip>:30333
```

---

## Troubleshooting

```bash
# Pod CrashLoopBackOff — check previous logs
kubectl logs -n sure <pod-name> --previous

# Manual DB migration
kubectl exec -it -n sure deploy/sure-web -- bundle exec rails db:migrate

# Rails console
kubectl exec -it -n sure deploy/sure-web -- rails console
```

| Issue | Fix |
|-------|-----|
| Pod Pending | Node offline — wait for node or re-label another node |
| PostgreSQL not ready | Check PVC and `kubectl logs -n sure -l app=sure-postgres` |
| Redis not responding | Check `kubectl logs -n sure -l app=sure-redis` |
| Web HTTP fail | Run `kubectl exec -it -n sure deploy/sure-web -- bundle exec rails db:prepare` if DB not migrated |
