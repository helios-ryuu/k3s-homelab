# Cloudflare Tunnel — Expose K3s ra Internet
> K3s namespace: `cloudflared`  |  Quản lý cluster: xem `k3s.md`

---

## Truy cập

| Subdomain | Service nội bộ | URL public |
|---|---|---|
| `grafana` | `mon-grafana.monitoring:80` | https://grafana.<your-domain> |

> Thêm service mới: Cloudflare Dashboard → Tunnels → `k3s` → **Public Hostname** → Add

---

## Deploy / Xóa

```bash
# Cài đặt lần đầu
helm install cfd cloudflared -n cloudflared --create-namespace --timeout 2m

# Cập nhật khi có thay đổi trong values.yaml
helm upgrade cfd cloudflared -n cloudflared --timeout 2m

# Xóa
helm uninstall cfd -n cloudflared
kubectl delete ns cloudflared
```

Helm chart: `cloudflared/`  
Release: `cfd` | Token: `cloudflared/values.yaml`

---

## Cách hoạt động

```
Internet → Cloudflare Edge (SSL) → Tunnel → cloudflared pod → K8s Service
```

- cloudflared tạo kết nối **outbound** → không cần public IP, không mở port
- SSL tự động (Cloudflare)
- Routing cấu hình trên Cloudflare Dashboard (không cần sửa gì trên cluster)

---

## Quản lý Tunnel

### Cloudflare Dashboard

1. Vào https://one.dash.cloudflare.com → **Networks** → **Tunnels**
2. Tunnel `k3s` → xem status, connectors, public hostnames

### Thêm service mới

1. Dashboard → Tunnels → `k3s` → tab **Public Hostname** → **Add**
2. Điền:
   - Subdomain: `<tên>` (vd: `prometheus`, `spark`)
   - Domain: `<your-domain>`
   - Type: `HTTP`
   - URL: `<service>.<namespace>.svc.cluster.local:<port>`
3. Save — không cần redeploy cloudflared

### Ví dụ thêm Prometheus

| Field | Value |
|---|---|
| Subdomain | `prometheus` |
| Domain | `<your-domain>` |
| Type | `HTTP` |
| URL | `mon-kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090` |

→ Truy cập: https://prometheus.<your-domain>

---

## Cập nhật Token

1. Cloudflare Dashboard → Tunnels → `k3s` → **Configure** → copy token mới
2. Sửa `cloudflared/values.yaml` → paste token
3. Chạy lệnh: `helm upgrade cfd cloudflared -n cloudflared --timeout 2m`

---

## Tài nguyên

| Component | RAM | CPU | Node |
|---|---|---|---|
| cloudflared | ~30-50 MB | ~10-30m | master |

---

## Troubleshooting

```bash
# Xem logs tunnel
kubectl logs -n cloudflared -l app=cloudflared

# Kiểm tra kết nối
kubectl describe pod -n cloudflared -l app=cloudflared
```

| Lỗi | Nguyên nhân | Fix |
|---|---|---|
| `ERR Failed to connect` | Token sai hoặc hết hạn | Cập nhật token + redeploy |
| `connection reset` | Firewall chặn outbound | Mở port 443 outbound |
| `502 Bad Gateway` | Service nội bộ không chạy | Kiểm tra pod target |
