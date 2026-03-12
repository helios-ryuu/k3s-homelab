# Logging — Loki + Grafana Alloy
> K3s namespace: `logging`  |  Quản lý cluster: xem `README.md`

---

## 0. Node Labels (Yêu cầu)
Để Loki được đặt đúng node (thường là Master/Control-plane), cần gán label:
- **Logging node**: `node-role.kubernetes.io/logging: "true"`

Gán label bằng lệnh:
```bash
kubectl label node <node-name> node-role.kubernetes.io/logging=true
```

---

## Truy cập

| Service | URL | Mô tả |
|---|---|---|
| **Loki** | http://<node-ip>:30100 | Log aggregation API |
| **Grafana → Loki** | http://<node-ip>:30300 → Explore → Loki | Query logs trong Grafana |

---

## Deploy / Xóa

```bash
# Cài đặt lần đầu
helm install log logging -n logging --create-namespace --timeout 2m

# Cập nhật
helm upgrade log logging -n logging --timeout 2m

# Xóa
helm uninstall log -n logging
kubectl delete clusterrole alloy
kubectl delete clusterrolebinding alloy
kubectl delete ns logging

# Tail logs Loki
kubectl logs -f -n logging -l app=loki --tail=100
```

Helm chart: local `logging`
Release: `log` | Config: `logging/values.yaml`

---

## Components

| Component | Node | Chức năng |
|---|---|---|
| Loki | master | Nhận, lưu trữ, query logs. Retention 7 ngày. Monolithic mode |
| Grafana Alloy | mỗi node (DaemonSet) | Thu thập container logs từ `/var/log/pods` → ship tới Loki |

> **Tại sao Alloy thay vì Promtail?**
> Grafana Alloy (kế thừa Promtail + Grafana Agent) hỗ trợ logs + metrics + traces trong 1 binary. Future-proof cho OpenTelemetry.

---

## Kiến trúc

```
┌────────────────┐    ┌────────────────┐    ┌────────────────┐
│ <master>       │    │ <worker-1>      │    │ <worker-2>      │
│ (master)        │    │ (worker)        │    │ (worker)        │
│                 │    │                 │    │                 │
│  ┌──────────┐  │    │  ┌──────────┐  │    │  ┌──────────┐  │
│  │  Alloy   │  │    │  │  Alloy   │  │    │  │  Alloy   │  │
│  └────┬─────┘  │    │  └────┬─────┘  │    │  └────┬─────┘  │
│       │        │    │       │        │    │       │        │
│  ┌────▼─────┐  │    │       │        │    │       │        │
│  │   Loki   │◄─┼────┼───────┘        │    │       │        │
│  │ :3100    │◄─┼────┼────────────────┼────┼───────┘        │
│  └────┬─────┘  │    │                 │    │                 │
│       │        │    │                 │    │                 │
│  ┌────▼─────┐  │    │                 │    │                 │
│  │ Grafana  │  │    │                 │    │                 │
│  │ :30300   │  │    │                 │    │                 │
│  └──────────┘  │    │                 │    │                 │
└────────────────┘    └────────────────┘    └────────────────┘
```

---

## Hướng dẫn sử dụng — Grafana Explore

### 1. Xem logs

1. Grafana → Menu ☰ → **Explore**
2. Data source: **Loki** (dropdown góc trái trên)
3. Chọn **Code** mode
4. Nhập LogQL query → **Shift + Enter**

### 2. LogQL cheat sheet

```logql
# Tất cả logs namespace bigdata
{namespace="bigdata"}

# Logs của 1 pod cụ thể
{namespace="oracle", pod="oracle-db-0"}

# Logs chứa từ "error" (case-insensitive)
{namespace="mssql"} |~ "(?i)error"

# Logs KHÔNG chứa "health" (lọc noise)
{namespace="monitoring"} !~ "health"

# Logs container cụ thể
{namespace="mssql", container="mssql-engine"}

# Logs từ 1 node
{node="<tên-node>"}

# Filter pipeline: parse + filter
{namespace="bigdata"} | json | level="ERROR"

# Đếm log lines/s theo namespace
sum(rate({job=~".+"} [5m])) by (namespace)

# Top 10 pods có nhiều logs nhất
topk(10, sum(rate({job=~".+"} [5m])) by (pod))
```

### 3. Live tail

1. Explore → **Loki** → nhập query
2. Click nút **Live** (góc phải trên, bên cạnh nút Run)
3. Logs stream real-time giống `kubectl logs -f`

### 4. Tạo Dashboard từ Logs

1. Menu ☰ → **Dashboards** → **New** → **New Dashboard**
2. **+ Add visualization** → chọn **Loki**
3. Visualization: **Logs** hoặc **Time series** (cho `rate(...)`)
4. Query: `sum(rate({namespace="bigdata"} [5m])) by (pod)`
5. Panel title: `BigData Log Rate`
6. Apply + Save 💾

---

## Loki API trực tiếp

```bash
# Kiểm tra Loki ready
curl -s http://<node-ip>:30100/ready

# Query labels
curl -s http://<node-ip>:30100/loki/api/v1/labels | jq

# Query label values
curl -s http://<node-ip>:30100/loki/api/v1/label/namespace/values | jq

# Query logs (last 1h)
curl -sG http://<node-ip>:30100/loki/api/v1/query_range \
  --data-urlencode 'query={namespace="bigdata"}' \
  --data-urlencode "start=$(date -d '1 hour ago' +%s)000000000" \
  --data-urlencode "end=$(date +%s)000000000" \
  --data-urlencode 'limit=10' | jq '.data.result[].values[][1]'
```

---

## Monitoring tích hợp

- **Prometheus** tự động scrape Loki metrics qua `ServiceMonitor` (cross-namespace)
- **PrometheusRules** bao gồm alert `LokiDown` (Loki unreachable > 2 phút)
- Xem metrics Loki trong Prometheus: `loki_ingester_chunk_*`, `loki_distributor_*`

---

## Tài nguyên sử dụng

| Component | RAM | CPU |
|---|---|---|
| Loki | 128-512 MB | 100-500m |
| Alloy (×3 nodes) | 64-128 MB | 50-100m |
| **Tổng** | **~320-900 MB** | **~250-800m** |

