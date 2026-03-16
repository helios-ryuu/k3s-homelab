# Logging — Loki + Grafana Alloy

> Namespace: `logging` | Script: `svc-scripts/logging.sh` | Chart: local `logging/`

---

## Node Labels

```bash
kubectl label node <node> node-role.kubernetes.io/logging=true
```

---

## Access

| Service | URL |
|---------|-----|
| **Loki** | `http://<node-ip>:30100` |
| **Grafana → Loki** | `http://<node-ip>:30300` → Explore → Loki |

---

## Operations

```bash
# Via main dispatcher
./k3s.sh deploy logging
./k3s.sh delete logging
./k3s.sh redeploy logging

# Via component script
./svc-scripts/logging.sh deploy
./svc-scripts/logging.sh delete
./svc-scripts/logging.sh redeploy
./svc-scripts/logging.sh logs             # Tail Loki logs (default)
./svc-scripts/logging.sh logs alloy       # Tail Alloy logs
```

> **Deploy logging before monitoring** — Grafana auto-configures Loki as a data source.

---

## Components

| Component | Node | Function |
|-----------|------|----------|
| Loki | master (pinned) | Log aggregation, storage, query. 7-day retention. Monolithic mode |
| Grafana Alloy | every node (DaemonSet) | Collects container logs from `/var/log/pods` → ships to Loki |

> **Why Alloy instead of Promtail?** Grafana Alloy (successor to Promtail + Grafana Agent) supports logs + metrics + traces in one binary. Future-proof for OpenTelemetry.

---

## Architecture

```
┌────────────────┐    ┌────────────────┐    ┌────────────────┐
│    master       │    │   worker-1      │    │   worker-2      │
│                 │    │                 │    │                 │
│  ┌──────────┐  │    │  ┌──────────┐  │    │  ┌──────────┐  │
│  │  Alloy   │  │    │  │  Alloy   │  │    │  │  Alloy   │  │
│  └────┬─────┘  │    │  └────┬─────┘  │    │  └────┬─────┘  │
│       │        │    │       │        │    │       │        │
│  ┌────▼─────┐  │    │       │        │    │       │        │
│  │   Loki   │◄─┼────┼───────┘        │    │       │        │
│  │  :3100   │◄─┼────┼────────────────┼────┼───────┘        │
│  └────┬─────┘  │    │                 │    │                 │
│       │        │    │                 │    │                 │
│  ┌────▼─────┐  │    │                 │    │                 │
│  │ Grafana  │  │    │                 │    │                 │
│  │ :30300   │  │    │                 │    │                 │
│  └──────────┘  │    │                 │    │                 │
└────────────────┘    └────────────────┘    └────────────────┘
```

---

## Grafana Explore — LogQL

### View logs

1. Grafana → Menu → **Explore** → Data source: **Loki** → **Code** mode
2. Enter LogQL query → **Shift + Enter**

### LogQL Cheat Sheet

```logql
# All logs from a namespace
{namespace="bigdata"}

# Specific pod
{namespace="oracle", pod="oracle-db-0"}

# Case-insensitive text search
{namespace="mssql"} |~ "(?i)error"

# Exclude noise
{namespace="monitoring"} !~ "health"

# Specific container
{namespace="mssql", container="mssql-engine"}

# Logs from a node
{node="<node-name>"}

# Parse + filter
{namespace="bigdata"} | json | level="ERROR"

# Log rate by namespace
sum(rate({job=~".+"} [5m])) by (namespace)

# Top 10 pods by log volume
topk(10, sum(rate({job=~".+"} [5m])) by (pod))
```

### Live tail

Explore → Loki → enter query → click **Live** (top-right, next to Run) → streams real-time like `kubectl logs -f`

### Dashboard from Logs

1. Menu → Dashboards → New → Add visualization → **Loki**
2. Visualization: **Logs** or **Time series** (for `rate(...)`)
3. Query: `sum(rate({namespace="bigdata"} [5m])) by (pod)`

---

## Loki API

```bash
# Check readiness
curl -s http://<node-ip>:30100/ready

# List labels
curl -s http://<node-ip>:30100/loki/api/v1/labels | jq

# Label values
curl -s http://<node-ip>:30100/loki/api/v1/label/namespace/values | jq

# Query logs (last 1h)
curl -sG http://<node-ip>:30100/loki/api/v1/query_range \
  --data-urlencode 'query={namespace="bigdata"}' \
  --data-urlencode "start=$(date -d '1 hour ago' +%s)000000000" \
  --data-urlencode "end=$(date +%s)000000000" \
  --data-urlencode 'limit=10' | jq '.data.result[].values[][1]'
```

---

## Monitoring Integration

- Prometheus auto-scrapes Loki metrics via `ServiceMonitor` (cross-namespace)
- `PrometheusRules` includes `LokiDown` alert (Loki unreachable > 2 min)
- Loki metrics in Prometheus: `loki_ingester_chunk_*`, `loki_distributor_*`

---

## Resource Usage

| Component | RAM | CPU |
|-----------|-----|-----|
| Loki | 128-512 MB | 100-500m |
| Alloy (per node) | 64-128 MB | 50-100m |
