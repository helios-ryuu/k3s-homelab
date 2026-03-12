# Monitoring — Prometheus + Grafana
> K3s namespace: `monitoring`  |  Logging: xem `logging.md`  |  Quản lý cluster: xem `k3s.md`

---

## 0. Node Labels (Yêu cầu)
Để các thành phần chính của Prometheus/Grafana được đặt đúng node, cần gán label:
- **Monitoring node**: `node-role.kubernetes.io/monitoring: "true"`

Gán label bằng lệnh:
```bash
kubectl label node <node-name> node-role.kubernetes.io/monitoring=true
```

---

## Truy cập

| Service | URL | Credentials |
|---|---|---|
| **Grafana** | http://<node-ip>:30300 | admin / `Grafana@2026` |
| **Prometheus** | http://<node-ip>:30090 | — |
| **Loki** | http://<node-ip>:30100 | — (xem `logging.md`) |

---

## Deploy / Xóa

```bash
# Thêm repo (1 lần)
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts && helm repo update

# Cài đặt lần đầu
helm install mon prometheus-community/kube-prometheus-stack -f monitoring/values.yaml -n monitoring --create-namespace --timeout 2m

# Cập nhật
helm upgrade mon prometheus-community/kube-prometheus-stack -f monitoring/values.yaml -n monitoring --timeout 2m

# Xóa
helm uninstall mon -n monitoring --no-hooks
kubectl delete ns monitoring

# Tail Grafana logs
kubectl logs -f -n monitoring -l app.kubernetes.io/name=grafana --tail=100
```

Helm chart: `prometheus-community/kube-prometheus-stack`  
Release: `mon` | Config: `monitoring/values.yaml`

---

## Components

| Component | Node | Chức năng |
|---|---|---|
| Prometheus | master | Thu thập metrics mỗi 30s, lưu trữ 7 ngày |
| Grafana | master | Dashboard trực quan, 30+ dashboard sẵn có |
| Node Exporter | mỗi node | Metrics phần cứng (CPU, RAM, Disk, Network) |
| kube-state-metrics | master | Metrics K8s objects (pods, deploy, PVC) |
| Prometheus Operator | master | Quản lý cấu hình Prometheus tự động |

> **Loki integration:** Grafana auto-configured với data source Loki (`http://loki.logging.svc.cluster.local:3100`). Bạn cần deploy namespace `logging` trước khi deploy `monitoring`.
---

## Built-in Alert Rules

Các alert tự động được cấu hình trong `values.yaml` → PrometheusRules:

| Alert | Điều kiện | Severity |
|---|---|---|
| HighCPUUsage | CPU > 85% sustained 5m | warning |
| HighMemoryUsage | RAM > 85% sustained 5m | warning |
| DiskAlmostFull | Disk root > 85% sustained 5m | critical |
| NodeDown | Node exporter unreachable 2m | critical |
| PodCrashLooping | > 3 restarts/hour sustained 5m | warning |
| PodNotReady | Pod Pending/Unknown/Failed > 10m | warning |
| DeploymentReplicasMismatch | Unavailable replicas > 10m | warning |
| PVCAlmostFull | PVC > 85% sustained 5m | warning |
| LokiDown | Loki unreachable 2m | critical |

Xem alerts: Grafana → Menu ☰ → **Alerting** → **Alert rules** hoặc Prometheus → **Alerts** tab.

---

## Hướng dẫn sử dụng Grafana

### 1. Explore Metrics

1. Menu ☰ → **Explore**
2. Data source: **Prometheus**
3. Chọn **Code** mode (góc phải trên)
4. Nhập query → **Shift + Enter** để chạy
5. Góc phải trên → chọn khoảng thời gian (Last 1 hour, Last 6 hours...)

Ví dụ query đầu tiên:
```promql
# CPU usage từng node (%)
100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
```

### 2. Dashboard có sẵn

Menu ☰ → **Dashboards** → tìm kiếm:

| Dashboard | Xem gì |
|---|---|
| Node Exporter / Nodes | CPU, RAM, Disk, Network **từng node** |
| Kubernetes / Compute Resources / Cluster | Tổng quan toàn cluster |
| Kubernetes / Compute Resources / Namespace (Pods) | Chọn namespace (`bigdata`, `oracle`...) xem từng pod |
| Kubernetes / Compute Resources / Node (Pods) | Xem theo node |
| CoreDNS | DNS performance |

### 3. Tạo Dashboard riêng

1. Menu ☰ → **Dashboards** → **New** → **New Dashboard**
2. **+ Add visualization** → chọn **Prometheus**
3. Nhập query:
   ```promql
   sum(rate(node_cpu_seconds_total{mode!="idle"}[5m])) by (instance)
   ```
4. Đặt **Panel title**: `CPU Usage per Node`
5. Click **Apply**
6. Thêm panel: click **+ Add** → **Visualization**
7. Lưu: icon 💾 trên cùng

### 4. Annotations (đánh dấu sự kiện)

- Click vào bất kỳ điểm nào trên graph → **Add annotation**
- Hoặc **Ctrl + Click kéo** để đánh dấu khoảng thời gian
- Dùng để ghi nhận: deploy mới, maintenance, incident...

### 5. Alert Rules (cảnh báo)

1. Menu ☰ → **Alerting** → **Alert rules** → **+ New alert rule**
2. Đặt tên: `High RAM Usage`
3. Query A → Prometheus:
   ```promql
   (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100
   ```
4. Expression B (Reduce): **Last**
5. Expression C (Threshold): `> 80` (cảnh báo khi RAM > 80%)
6. Folder: tạo `k3s-alerts`, evaluation group `k3s-alerts`, interval `1m`
7. **Save rule and exit**

### 6. Contact Points (kênh nhận cảnh báo)

1. Menu ☰ → **Alerting** → **Contact points** → **+ Add contact point**
2. Chọn Integration: **Email**, **Webhook**, **Telegram**, **Slack**...
3. Cấu hình URL/token → **Test** → **Save**
4. Quay lại Alert rule → Section 4 chọn Contact point vừa tạo

---

## PromQL cheat sheet

### Infrastructure (từng node)

```promql
# CPU usage %
100 - (avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# RAM usage %
(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100

# Disk usage %
(1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100

# Network receive (bytes/s)
rate(node_network_receive_bytes_total[5m])

# Network transmit (bytes/s)
rate(node_network_transmit_bytes_total[5m])

# Load average 1m
node_load1
```

### Kubernetes

```promql
# Số pod đang Running theo namespace
count by(namespace)(kube_pod_status_phase{phase="Running"})

# Pod restart count (> 0)
kube_pod_container_status_restarts_total > 0

# PVC usage %
kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes * 100

# Container CPU usage
rate(container_cpu_usage_seconds_total{container!=""}[5m])

# Container memory usage (MB)
container_memory_usage_bytes{container!=""} / 1024 / 1024

# Deployment replicas not ready
kube_deployment_status_replicas_unavailable > 0
```

### Prometheus self-monitoring

```promql
# Scrape targets up/down
up

# Prometheus memory usage
process_resident_memory_bytes{job="prometheus"}
```

---

## Xem Prometheus trực tiếp

Truy cập: **http://<node-ip>:30090**

- **Status → Targets**: xem tất cả endpoints đang scrape (xanh = OK, đỏ = lỗi)
- **Graph**: chạy PromQL query trực tiếp
- **Status → Runtime & Build Information**: phiên bản, uptime

---

## Không monitor được (cần thêm exporter)

| Ứng dụng | Exporter cần thêm |
|---|---|
| Oracle internals | `oracledb_exporter` |
| MSSQL internals | `sql_exporter` |
| Hadoop/Spark jobs | JMX exporter |

---

## Tài nguyên sử dụng

| Component | RAM | CPU |
|---|---|---|
| Prometheus | 256-512 MB | 100-500m |
| Grafana | 128-256 MB | 100-200m |
| Node Exporter (×3) | 30-50 MB | 50m |
| kube-state-metrics | 50-100 MB | 50m |
| Loki | 128-512 MB | 100-500m |
| Alloy (×3 nodes) | 64-128 MB | 50-100m |
| **Tổng (Monitoring + Logging)** | **~820 MB - 1.9 GB** | **~550m - 1.6** |
