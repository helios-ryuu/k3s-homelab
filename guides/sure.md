# Sure — Finance Management App

> Namespace: `sure` | Script: `svc-scripts/sure.sh` | Manifests: `sure/sure-stack.yaml`

---

## Node Labels

```bash
kubectl label node <node> app-host=sure
```

---

## Operations

```bash
# Via main dispatcher
./k3s.sh deploy sure
./k3s.sh delete sure
./k3s.sh redeploy sure
./k3s.sh check sure

# Via component script
./svc-scripts/sure.sh deploy              # Checks node readiness before deploy
./svc-scripts/sure.sh delete
./svc-scripts/sure.sh redeploy
./svc-scripts/sure.sh logs                # Tail web logs (default)
./svc-scripts/sure.sh logs worker         # Tail Sidekiq worker logs
./svc-scripts/sure.sh setup              # Run Rails DB migrations
./svc-scripts/sure.sh check              # Health check (4 sections)
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

## Health Check Sections

`./svc-scripts/sure.sh check` runs 4 checks:

1. **Pod Status** — sure-postgres, sure-redis, sure-web, sure-worker
2. **Database Health** — `pg_isready` on PostgreSQL pod
3. **Redis Health** — `redis-cli ping` on Redis pod
4. **Web Endpoint** — HTTP status on `http://<node-ip>:30333`

---

## First-Time Setup

After initial deploy, run database migrations:

```bash
./svc-scripts/sure.sh setup
```

This runs `bundle exec rails db:prepare` inside the web pod.

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
| Pod MISSING | `./k3s.sh deploy sure` |
| Pod Pending | Node offline — wait for node |
| PostgreSQL not ready | Check PVC and `kubectl logs -n sure -l app=sure-postgres` |
| Redis not responding | Check `kubectl logs -n sure -l app=sure-redis` |
| Web HTTP fail | Run `./svc-scripts/sure.sh setup` if DB not migrated |
