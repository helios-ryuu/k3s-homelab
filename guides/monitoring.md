# Monitoring — Prometheus + Grafana

> Namespace: `monitoring` | Script: `svc-scripts/monitoring.sh` | Chart: `prometheus-community/kube-prometheus-stack`

---

## Node Labels

```bash
kubectl label node <node> node-role.kubernetes.io/monitoring=true
```

---

## Access

| Service | URL |
|---------|-----|
| **Grafana** | `http://<node-ip>:30300` |
| **Prometheus** | `http://<node-ip>:30090` |

> Grafana credentials are stored in `infra-secrets` (`admin-user`, `admin-password`).

---

## Operations

```bash
# Via main dispatcher
./k3s.sh deploy monitoring
./k3s.sh delete monitoring
./k3s.sh redeploy monitoring
./k3s.sh check monitoring

# Via component script
./svc-scripts/monitoring.sh deploy
./svc-scripts/monitoring.sh delete
./svc-scripts/monitoring.sh redeploy
./svc-scripts/monitoring.sh logs          # Tail Grafana logs
./svc-scripts/monitoring.sh check         # Health check (5 sections)
```

> **Prerequisite:** Deploy `logging` before `monitoring` — Grafana auto-configures Loki as a data source.

---

## Components

| Component | Node | Function |
|-----------|------|----------|
| Prometheus | master | Scrapes metrics every 30s, 7-day retention |
| Grafana | master | Visualization, 30+ built-in dashboards |
| Node Exporter | every node (DaemonSet) | Hardware metrics (CPU, RAM, Disk, Network) |
| kube-state-metrics | master | K8s object metrics (pods, deployments, PVCs) |
| Prometheus Operator | master | Auto-manages Prometheus configuration |

---

## Health Check Sections

`./svc-scripts/monitoring.sh check` runs 5 checks:

1. **Pod Status** — Prometheus, Grafana, Operator, kube-state-metrics, Node Exporter (DaemonSet), Alloy (DaemonSet), Loki
2. **Prometheus** — Readiness, scrape targets (up/down/unknown), rules count
3. **Grafana** — API health, datasources count
4. **Loki** — Readiness, labels count, query test (recent streams)
5. **Node Coverage** — Node Exporter and Alloy per-node coverage on all Ready nodes

---

## Built-in Alert Rules

| Alert | Condition | Severity |
|-------|-----------|----------|
| HighCPUUsage | CPU > 85% for 5m | warning |
| HighMemoryUsage | RAM > 85% for 5m | warning |
| DiskAlmostFull | Disk root > 85% for 5m | critical |
| NodeDown | Node exporter unreachable 2m | critical |
| PodCrashLooping | > 3 restarts/hour for 5m | warning |
| PodNotReady | Pending/Unknown/Failed > 10m | warning |
| DeploymentReplicasMismatch | Unavailable replicas > 10m | warning |
| PVCAlmostFull | PVC > 85% for 5m | warning |
| LokiDown | Loki unreachable 2m | critical |

View alerts: Grafana → Alerting → Alert rules, or Prometheus → Alerts tab.

---

## Grafana Usage

### Explore Metrics

1. Menu → **Explore** → Data source: **Prometheus** → **Code** mode
2. Enter query → **Shift + Enter**

### Built-in Dashboards

Menu → **Dashboards** → search:

| Dashboard | Shows |
|-----------|-------|
| Node Exporter / Nodes | CPU, RAM, Disk, Network per node |
| Kubernetes / Compute Resources / Cluster | Cluster overview |
| Kubernetes / Compute Resources / Namespace (Pods) | Per-namespace pod resources |
| Kubernetes / Compute Resources / Node (Pods) | Per-node pod view |
| CoreDNS | DNS performance |

### Create Custom Dashboard

1. Menu → Dashboards → New → New Dashboard
2. Add visualization → Prometheus
3. Query, title, Apply, Save

### Alert Rules

1. Menu → Alerting → Alert rules → + New alert rule
2. Configure query, threshold, evaluation interval
3. Contact Points: Email, Webhook, Telegram, Slack

---

## PromQL Cheat Sheet

### Infrastructure

```promql
# CPU usage %
100 - (avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# RAM usage %
(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100

# Disk usage %
(1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100

# Network receive/transmit (bytes/s)
rate(node_network_receive_bytes_total[5m])
rate(node_network_transmit_bytes_total[5m])

# Load average 1m
node_load1
```

### Kubernetes

```promql
# Running pods by namespace
count by(namespace)(kube_pod_status_phase{phase="Running"})

# Pod restart count
kube_pod_container_status_restarts_total > 0

# PVC usage %
kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes * 100

# Container CPU/memory
rate(container_cpu_usage_seconds_total{container!=""}[5m])
container_memory_usage_bytes{container!=""} / 1024 / 1024

# Unavailable replicas
kube_deployment_status_replicas_unavailable > 0
```

### Prometheus self-monitoring

```promql
up                                           # Scrape targets
process_resident_memory_bytes{job="prometheus"} # Memory usage
```

---

## Direct Prometheus Access

`http://<node-ip>:30090`:
- **Status → Targets**: all scrape endpoints (green = OK, red = error)
- **Graph**: run PromQL queries
- **Status → Runtime**: version, uptime

---

## Missing Exporters

| Application | Exporter needed |
|-------------|----------------|
| Oracle internals | `oracledb_exporter` |
| MSSQL internals | `sql_exporter` |
| Hadoop/Spark jobs | JMX exporter |

---

## Resource Usage

| Component | RAM | CPU |
|-----------|-----|-----|
| Prometheus | 256-512 MB | 100-500m |
| Grafana | 128-256 MB | 100-200m |
| Node Exporter (per node) | 30-50 MB | 50m |
| kube-state-metrics | 50-100 MB | 50m |

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Pod MISSING | `./k3s.sh deploy monitoring` |
| Prometheus NOT READY | May be loading WAL (1-2 min) |
| Targets DOWN | Check network policies or pod health |
| Grafana 401/403 | Check `grafana-admin-password` in `infra-secrets` |
| Loki no labels | Alloy not shipping logs — check `./svc-scripts/logging.sh logs alloy` |
