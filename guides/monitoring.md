# Monitoring — Prometheus + Grafana

> Namespace: `monitoring` | ArgoCD App: `monitoring` | Chart: `prometheus-community/kube-prometheus-stack` (multi-source)

---

## Node Labels

```bash
kubectl label node <node> node-role.kubernetes.io/monitoring=true
```

---

## Access

| Service | URL |
|---------|-----|
| **Grafana** | `https://grafana.helios.id.vn` |
| **Prometheus** | `http://<node-ip>:30090` (Tailscale only) |

> Grafana credentials stored in `infra-secrets` (`admin-user`, `admin-password`).

> **Prerequisite:** Deploy `logging` before `monitoring` — Grafana auto-configures Loki as a data source on first startup.

---

## Operations

```bash
# Config changes: edit services/monitoring/values.yaml → git push → ArgoCD auto-syncs

# Manual sync trigger
argocd app sync monitoring --grpc-web
argocd app wait monitoring --health --grpc-web

# Logs
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana -f
kubectl logs -n monitoring -l app.kubernetes.io/name=prometheus -f
```

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

View: Grafana → Alerting → Alert rules, or `http://<node-ip>:30090` → Alerts tab.

---

## Grafana Usage

### Built-in Dashboards

Menu → **Dashboards** → search:

| Dashboard | Shows |
|-----------|-------|
| Node Exporter / Nodes | CPU, RAM, Disk, Network per node |
| Kubernetes / Compute Resources / Cluster | Cluster overview |
| Kubernetes / Compute Resources / Namespace (Pods) | Per-namespace pod resources |
| Kubernetes / Compute Resources / Node (Pods) | Per-node pod view |
| CoreDNS | DNS performance |

### Explore Metrics

Menu → **Explore** → Data source: **Prometheus** → **Code** mode → Enter query → **Shift + Enter**

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
| Prometheus NOT READY | May be loading WAL (1-2 min after start) |
| Targets DOWN | Check network policies or pod health |
| Grafana 401/403 | Check `grafana-admin-password` in `infra-secrets` — re-seal and push `secrets/infra-secrets-monitoring.yaml` (SETUP.md 3.8) |
| Loki no labels | Alloy not shipping logs — check `kubectl logs -n logging -l app.kubernetes.io/name=alloy` |
