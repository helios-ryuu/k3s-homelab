# Logging — Loki + Grafana Alloy

> Namespace: `logging` | ArgoCD App: `logging` | Chart: local `services/logging/`

---

## Node Labels

```bash
kubectl label node <node> node-role.kubernetes.io/logging=true
```

---

## Access

| Service | URL |
|---------|-----|
| **Loki API** | `https://loki.helios.id.vn` |
| **Grafana → Explore → Loki** | `https://grafana.helios.id.vn` |

> **Deploy logging before monitoring** — Grafana auto-configures Loki as a data source on first startup.

---

## Operations

```bash
# Config changes: edit services/logging/values.yaml or templates → git push → ArgoCD auto-syncs

# Manual sync trigger (acd helper — see README.md)
acd app sync logging
acd app wait logging --health

# Logs
kubectl logs -n logging -l app=loki -f
kubectl logs -n logging -l app.kubernetes.io/name=alloy -f   # per-node DaemonSet
```

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
│  └──────────┘  │    │                 │    │                 │
└────────────────┘    └────────────────┘    └────────────────┘
```

---

## Grafana Explore — LogQL

1. `https://grafana.helios.id.vn` → Menu → **Explore** → Data source: **Loki** → **Code** mode
2. Enter LogQL query → **Shift + Enter**

### LogQL Cheat Sheet

```logql
# All logs from a namespace
{namespace="bigdata"}

# Specific pod
{namespace="oracle", pod="oracle-db-0"}

# Case-insensitive text search
{namespace="oracle"} |~ "(?i)error"

# Exclude noise
{namespace="monitoring"} !~ "health"

# Specific container
{namespace="oracle", container="oracle-engine"}

# Logs from a node
{node="<node-name>"}

# Parse JSON + filter
{namespace="bigdata"} | json | level="ERROR"

# Log rate by namespace
sum(rate({job=~".+"} [5m])) by (namespace)

# Top 10 pods by log volume
topk(10, sum(rate({job=~".+"} [5m])) by (pod))
```

### Live tail

Explore → Loki → enter query → click **Live** (top-right) → streams real-time like `kubectl logs -f`

---

## Loki API

```bash
# Readiness
curl -s https://loki.helios.id.vn/ready

# List labels
curl -s https://loki.helios.id.vn/loki/api/v1/labels | jq

# Label values
curl -s https://loki.helios.id.vn/loki/api/v1/label/namespace/values | jq

# Query logs (last 1h)
curl -sG https://loki.helios.id.vn/loki/api/v1/query_range \
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
