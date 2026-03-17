# RedShark API — Spring Boot Backend

> Namespace: `redshark` | ArgoCD App: `redshark` | Chart: local `services/redshark/`

---

## Operations

```bash
# Config changes: edit services/redshark/values.yaml → git push → ArgoCD auto-syncs

# Manual sync trigger
argocd app sync redshark --grpc-web
argocd app wait redshark --health --grpc-web

# Logs
kubectl logs -n redshark -l app=redshark-api -f
```

---

## Configuration

| Setting | Value |
|---------|-------|
| Image | `ghcr.io/helios-ryuu/redshark-api:latest` |
| Pull Policy | `Always` |
| Replicas | `0` by default — set to `1` in `values.yaml` when ready |
| Spring Profile | `k8s` |
| Port | `8080` (ClusterIP) |
| Health probe | `GET /actuator/health` |
| Secrets | `redshark-secrets` (`db-username`, `db-password`) |

---

## Enabling the Deployment

The chart ships with `replicas: 0` as a placeholder. To activate:

```yaml
# services/redshark/values.yaml
replicas: 1
```

Commit and push — ArgoCD will reconcile.

---

## Secrets

`redshark-secrets` is created by `./init-sec.sh` from `.env`:

```bash
# .env variables
REDSHARK_DB_USERNAME=<db-username>
REDSHARK_DB_PASSWORD=<db-password>

# Apply
./init-sec.sh redshark
```

The secret keys are injected as `SPRING_DATASOURCE_USERNAME` / `SPRING_DATASOURCE_PASSWORD` env vars into the container.

---

## Access

| Endpoint | URL |
|----------|-----|
| In-cluster | `http://redshark-api.redshark.svc.cluster.local:8080` |
| Cloudflare Tunnel (if configured) | `https://redshark.helios.id.vn` |

To expose via Cloudflare Tunnel, add a public hostname in the Cloudflare Dashboard:

| Subdomain | Domain | Service |
|-----------|--------|---------|
| `redshark` | `helios.id.vn` | `http://redshark-api.redshark.svc.cluster.local:8080` |

---

## Health Check

```bash
kubectl get pods -n redshark

# From inside cluster
kubectl exec -n redshark deploy/redshark-api -- curl -s http://localhost:8080/actuator/health
```

---

## Database

RedShark uses LocalStack PostgreSQL (RDS emulation):

| Profile | JDBC URL |
|---------|----------|
| `k8s` | `jdbc:postgresql://localstack.localstack.svc.cluster.local:4510/<db-name>` |
| `local` | Configured in `application-local.properties` (gitignored) |

The database must exist in LocalStack before the API starts. See `guides/localstack.md`.

---

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| Pod not starting | `replicas: 0` in values | Set `replicas: 1` and push |
| `Failed to connect to datasource` | LocalStack not running or DB missing | Ensure `localstack` app is healthy first |
| `Secret not found` | `redshark-secrets` missing | Run `./init-sec.sh redshark` |
| Readiness probe failing | App still starting (Spring Boot ~30s) | Wait — `initialDelaySeconds: 30` |
