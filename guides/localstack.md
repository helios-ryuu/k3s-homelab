# LocalStack Pro — AWS Services Emulation

> Namespace: `localstack` | Script: `svc-scripts/localstack.sh` | Chart: `localstack/localstack`

---

## Operations

```bash
# Via main dispatcher
./k3s.sh deploy localstack
./k3s.sh delete localstack
./k3s.sh redeploy localstack
./k3s.sh check localstack

# Via component script
./svc-scripts/localstack.sh deploy        # Checks image, node, secrets before deploying
./svc-scripts/localstack.sh delete
./svc-scripts/localstack.sh redeploy
./svc-scripts/localstack.sh logs
./svc-scripts/localstack.sh check         # Health check (5 sections)
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

## Access

| Endpoint | URL |
|----------|-----|
| External (Tailscale) | `http://<node-ip>:30566` |
| In-cluster | `http://localstack.localstack.svc.cluster.local:4566` |

---

## Health Check Sections

`./svc-scripts/localstack.sh check` runs 5 checks:

1. **Pod Status** — LocalStack pod + DinD sidecar readiness
2. **API Health** — Version, edition (Pro vs Community), external reachability
3. **Services Status** — All enabled services and their states
4. **Lambda / DinD** — Docker daemon reachability from LocalStack container
5. **Smoke Tests** — S3 (create/delete bucket), DynamoDB (create/put/get/delete), SQS, SNS, Secrets Manager

---

## AWS CLI Usage

```bash
# From inside cluster (any pod)
awslocal --endpoint-url=http://localstack.localstack.svc.cluster.local:4566 s3 ls

# From outside cluster (Tailscale)
aws --endpoint-url=http://<node-ip>:30566 \
    --region us-east-1 \
    --no-sign-request \
    s3 ls
```

## Health Check (manual)

```bash
curl http://<node-ip>:30566/_localstack/health | python3 -m json.tool
```

---

## Enabled Services

`iam` · `sts` · `s3` · `rds` · `apigateway` · `sns` · `sqs` · `secretsmanager` · `cloudwatch` · `lambda` · `ec2` · `route53` · `backup`

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Pod missing | `./k3s.sh deploy localstack` |
| API not responding | Pod may still be starting (30-60s) |
| Edition not Pro | Check `LOCALSTACK_AUTH_TOKEN` in `infra-secrets` |
| Lambda/DinD fail | Do NOT set `DOCKER_HOST` manually — chart auto-sets it |
| S3/DDB/SQS fail | Service may not be initialized yet — retry in ~1 min |
