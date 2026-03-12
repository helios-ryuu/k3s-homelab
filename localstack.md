# LocalStack Pro — AWS Services giả lập
> K3s namespace: `localstack`  |  Node: `<your-localstack-node>` |  Quản lý cluster: xem `k3s.md`

---

## 0. Node Labels (Yêu cầu)
LocalStack yêu cầu node được gắn label để pinned deployment:
- **LocalStack node**: `node-role.kubernetes.io/localstack: "true"`

Gán label bằng lệnh:
```bash
kubectl label node <node-name> node-role.kubernetes.io/localstack=true
```

---

## Deploy

```bash
# Cài repo (1 lần)
helm repo add localstack https://localstack.github.io/helm-charts && helm repo update

# Deploy / Cài đặt lần đầu
helm install localstack localstack/localstack -f localstack/values.yaml -n localstack --create-namespace --timeout 2m

# Cập nhật
helm upgrade localstack localstack/localstack -f localstack/values.yaml -n localstack --timeout 2m

# Xóa
helm uninstall localstack -n localstack
kubectl delete deployment localstack -n default
kubectl delete svc localstack -n default
kubectl delete ns localstack
```

## Helm Chart

- Dùng community chart `localstack/localstack` với image override `localstack/localstack-pro`
- Config tại `localstack/values.yaml`
- Namespace: `localstack`
- `pullPolicy: Always` — luôn pull bản mới nhất khi deploy

## Cấu hình

| Thông số | Giá trị |
|---|---|
| Image | `localstack/localstack-pro:latest` |
| Node | `<your-localstack-node>` (pinned) |
| DinD | enabled (cho Lambda/ECS emulation) |
| Persistence | 5Gi PVC `local-path` |
| Auth Token | `LOCALSTACK_AUTH_TOKEN` env |
| Strategy | `Recreate` (bắt buộc với PVC ReadWriteOnce) |

## Truy cập

| Service | URL |
|---|---|
| LocalStack API (ngoài) | `http://<node-ip>:34566` |
| Từ trong cluster | `http://localstack.localstack.svc.cluster.local:4566` |

> NodePort `34566` cố định — không đổi sau redeploy.

## AWS CLI (awslocal)

```bash
# Trong cluster (từ pod bất kỳ)
awslocal --endpoint-url=http://localstack.localstack.svc.cluster.local:4566 s3 ls

# Từ ngoài cluster (Tailscale)
aws --endpoint-url=http://<node-ip>:34566 \
    --region us-east-1 \
    --no-sign-request \
    s3 ls
```

## Health Check

```bash
curl http://<node-ip>:34566/_localstack/health | python3 -m json.tool
```

## Services được bật

`iam` · `sts` · `s3` · `rds` · `apigateway` · `sns` · `sqs` · `secretsmanager` · `cloudwatch` · `lambda` · `ec2` · `route53` · `backup`
