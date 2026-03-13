# Sure — Finance Management App
> K3s namespace: `sure`  |  Node: `helios-imac-ubuntu` (label `app-host=sure`)  |  Quản lý cluster: xem `README.md`

---

## 0. Node Labels (Yêu cầu)
Sure yêu cầu node được gắn label để pinned deployment:
- **Sure node**: `app-host: sure`

Gán label bằng lệnh:
```bash
kubectl label node <node-name> app-host=sure
```

---

## 1. Secrets (Yêu cầu)
Trước khi deploy, cần tạo Secret `infra-secrets` trong namespace `sure`:

```bash
# Sinh SECRET_KEY_BASE (64 ký tự hex ngẫu nhiên)
head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n' && echo

# Tạo secret
kubectl create namespace sure --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic infra-secrets \
  --from-literal=sure-secret-key-base='<chuỗi_64_ký_tự>' \
  --from-literal=sure-postgres-password='<mật_khẩu_DB>' \
  -n sure --dry-run=client -o yaml | kubectl apply -f -
```

---

## 2. Deploy

```bash
# Deploy (kubectl apply)
kubectl apply -f sure/sure-stack.yaml

# Hoặc dùng mng.sh
bash ./mng.sh deploy sure

# Xóa
bash ./mng.sh delete sure

# Redeploy (xóa sạch + deploy lại)
bash ./mng.sh redeploy sure
```

## 3. Kiến trúc

Sure stack gồm 4 Deployments riêng biệt, tất cả `replicas: 1` và neo cứng trên node có label `app-host=sure`:

| Component | Image | Port | Mô tả |
|---|---|---|---|
| `sure-postgres` | `postgres:18-alpine` | 5432 | PostgreSQL database |
| `sure-redis` | `redis:8-alpine` | 6379 | Redis cache (AOF persistence) |
| `sure-web` | `ghcr.io/we-promise/sure:stable` | 3000 | Rails web server |
| `sure-worker` | `ghcr.io/we-promise/sure:stable` | — | Sidekiq background worker |

## 4. Storage (PVC)

| PVC | Dung lượng | Mount path |
|---|---|---|
| `sure-postgres-pvc` | 5Gi | `/var/lib/postgresql/data` |
| `sure-redis-pvc` | 2Gi | `/data` |

> StorageClass: `local-path` (K3s mặc định)

## 5. Resource Limits

| Component | CPU Request | CPU Limit | Mem Request | Mem Limit |
|---|---|---|---|---|
| Postgres | 100m | 500m | 256Mi | 512Mi |
| Redis | 50m | 200m | 64Mi | 128Mi |
| Web | 100m | 1000m | 256Mi | 512Mi |
| Worker | 100m | 500m | 256Mi | 512Mi |

## 6. Truy cập

| Service | URL |
|---|---|
| Sure Web (ngoài) | `http://<node-ip>:30300` |
| Từ trong cluster | `http://sure-web-svc.sure.svc.cluster.local:80` |

> NodePort `30300` cố định — không đổi sau redeploy.

## 7. Monitoring

```bash
# Xem trạng thái pods
kubectl get pods -n sure -o wide

# Tail logs web
kubectl logs -f -n sure -l app=sure-web --tail=100

# Tail logs worker (sidekiq)
kubectl logs -f -n sure -l app=sure-worker --tail=100

# Xem secrets
kubectl get secrets -n sure
```

## 8. Troubleshooting

```bash
# Pod bị CrashLoopBackOff → kiểm tra logs
kubectl logs -n sure <pod-name> --previous

# DB chưa migrate → exec vào web pod
kubectl exec -it -n sure deploy/sure-web -- bundle exec rails db:migrate

# Kiểm tra kết nối DB từ web pod
kubectl exec -it -n sure deploy/sure-web -- rails console
```
