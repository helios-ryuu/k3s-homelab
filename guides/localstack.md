# LocalStack Pro — AWS Services Emulation

> Namespace: `localstack` | ArgoCD App: `localstack` | Chart: `localstack/localstack` (multi-source)

---

## Access

| Endpoint | URL |
|----------|-----|
| Via Cloudflare Tunnel | `https://localstack.helios.id.vn` |
| In-cluster | `http://localstack.localstack.svc.cluster.local:4566` |

---

## Operations

```bash
# Config changes: edit services/localstack/values.yaml → git push → ArgoCD auto-syncs

# Manual sync trigger (acd helper — see README.md)
acd app sync localstack
acd app wait localstack --health

# Logs
kubectl logs -n localstack -l app.kubernetes.io/name=localstack -f
```

---

## Configuration

| Setting | Value |
|---------|-------|
| Image | `localstack/localstack-pro:latest` |
| Node | Control-plane (fallback if no dedicated label) |
| DinD | Enabled (for Lambda/ECS emulation) |
| Persistence | 5Gi PVC `local-path` |
| Auth Token | `LOCALSTACK_AUTH_TOKEN` via `infra-secrets` |
| Strategy | `Recreate` (required for ReadWriteOnce PVC) |

---

## Health Check

```bash
# API health
curl https://localstack.helios.id.vn/_localstack/health | python3 -m json.tool

# From inside cluster
kubectl exec -n localstack deploy/localstack -- curl -s http://localhost:4566/_localstack/health | python3 -m json.tool
```

---

## AWS CLI Usage

```bash
# From outside cluster (Cloudflare Tunnel)
aws --endpoint-url=https://localstack.helios.id.vn \
    --region us-east-1 \
    --no-sign-request \
    s3 ls

# From inside cluster
awslocal --endpoint-url=http://localstack.localstack.svc.cluster.local:4566 s3 ls
```

---

## Enabled Services

`iam` · `sts` · `s3` · `rds` · `apigateway` · `sns` · `sqs` · `secretsmanager` · `cloudwatch` · `lambda` · `ec2` · `route53` · `backup`

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| API not responding | Pod may still be starting (30-60s) |
| Edition not Pro | Check `LOCALSTACK_AUTH_TOKEN` in `infra-secrets` — re-seal and push `secrets/infra-secrets-localstack.yaml` (SETUP.md 3.8) |
| Lambda/DinD fail | Do NOT set `DOCKER_HOST` manually — chart auto-sets it |
| S3/DDB/SQS fail | Service may not be initialized yet — retry in ~1 min |
