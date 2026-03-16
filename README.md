# K3S Homelab — Distributed Systems Education Cluster

> **5 nodes** via Tailscale mesh VPN — 3 master (HA embedded etcd) + 2 worker
> Management: `k3s.sh` · Diagnostics: `ck.sh` · Secrets: `init-sec.sh`

---

## 1. Topology

| Node | Role | OS | Tailscale IP | Workloads |
|------|------|----|-------------|-----------|
| `<node-1>` | master | Ubuntu | `<ip-1>` | monitoring, logging, bigdata masters, localstack, headlamp |
| `<node-2>` | master | Ubuntu | `<ip-2>` | cloudflared, **sure-stack** |
| `<node-3>` | master | Fedora | `<ip-3>` | oracle-db-0, mssql-db-1, bigdata workers |
| `<node-4>` | worker | Ubuntu | `<ip-4>` | mssql-db-0 · **may go offline** |
| `<node-5>` | worker | Ubuntu (WSL2) | `<ip-5>` | oracle-db-1, mssql-db-2, bigdata workers · **may go offline** |

### Node Labels (Required)

Workloads use `nodeSelector` for placement. Labels must be assigned before deploying:

```bash
# Monitoring & Logging
kubectl label node <node> node-role.kubernetes.io/monitoring=true
kubectl label node <node> node-role.kubernetes.io/logging=true

# BigData
kubectl label node <node> node-role.kubernetes.io/bigdata-master=true
kubectl label node <node> node-role.kubernetes.io/bigdata-worker=true

# Databases
kubectl label node <node> node-role.kubernetes.io/database-oracle=true
kubectl label node <node> node-role.kubernetes.io/database-mssql=true

# Sure App
kubectl label node <node> app-host=sure
```

---

## 2. Cluster Management (`k3s.sh`)

```bash
./k3s.sh deploy   [target|all]   # Deploy (install or upgrade)
./k3s.sh delete   [target|all]   # Force delete (pods, PVC, namespace)
./k3s.sh redeploy [target|all]   # Delete + deploy clean
./k3s.sh scale    <target> <N>   # Scale workers/replicas
./k3s.sh logs     <target>       # Tail main pod logs
./k3s.sh check    <target>       # Component health check
./k3s.sh status                  # Cluster overview (nodes, helm, pods, PVC)
./k3s.sh health                  # Global health check + fault tolerance
./k3s.sh nuke                    # DELETE EVERYTHING including PVC
```

**Targets:** `bigdata`, `oracle`, `mssql`, `localstack`, `logging`, `monitoring`, `cloudflared`, `headlamp`, `sure`

| Action | Description |
|--------|-------------|
| `deploy` | `helm install` (first time) or `helm upgrade` (existing) |
| `delete` | Force delete everything (pods, PVC, CRDs, namespace) |
| `redeploy` | `delete` + `deploy` clean |
| `scale N` | Change replicas (0 = shutdown, PVC preserved) |
| `check` | Per-component health check with detailed diagnostics |

### Per-Component Scripts

Each component has its own script in `svc-scripts/` with the same interface plus component-specific commands:

```bash
./svc-scripts/bigdata.sh scale [0|1|2|3]    # Scale workers (workers before masters)
./svc-scripts/bigdata.sh check              # 6-section BigData health check
./svc-scripts/oracle.sh check               # 4-section Oracle health check
./svc-scripts/mssql.sh check                # 4-section MSSQL health check
./svc-scripts/monitoring.sh check           # 5-section monitoring stack check
./svc-scripts/localstack.sh check           # 5-section LocalStack check (with smoke tests)
./svc-scripts/sure.sh setup                 # Rails DB migrations
./svc-scripts/sure.sh check                 # 4-section Sure health check
./svc-scripts/headlamp.sh token             # Create permanent auth token
```

### Offline Node Behavior

- Worker offline → pods go **Pending** (no reschedule due to hard anti-affinity)
- Scale to 0 → all pods terminated, **PVC preserved**
- Scale back up → pods recreate, mount existing PVC

---

## 3. Cluster Diagnostics (`ck.sh`)

```bash
./ck.sh                    # Full check — all 7 sections
./ck.sh sys                # [1/7] System & load (RAM, CPU, disk, uptime)
./ck.sh node               # [2/7] Nodes & Pods layout (grouped by node)
./ck.sh secrets            # [3/7] Secrets (by namespace, names only)
./ck.sh pvc                # [4/7] PVC / Storage (grouped by node)
./ck.sh res                # [5/7] Deployed resources (deploy, sts, ds, hpa, svc)
./ck.sh img                # [6/7] Images & usage per node
./ck.sh helm               # [7/7] Helm releases
```

### Detail mode

```bash
./ck.sh node <node-name>       # kubectl describe node
./ck.sh pod loki-0             # kubectl describe pod (auto-detect namespace)
./ck.sh pvc loki-data          # kubectl describe pvc (auto-detect namespace)
./ck.sh res bigdata            # Resources for namespace bigdata only
```

### Export

```bash
./ck.sh export                 # → ck/ck-HHmmss-ddMMyy.txt
./ck.sh export -c              # → ck/ck-HHmmss-ddMMyy-compact.txt
```

---

## 4. Helm Charts

| Release | Namespace | Chart | Description | Guide |
|---------|-----------|-------|-------------|-------|
| `bigd` | `bigdata` | local `bigdata/` | Hadoop 3.2.1 + Spark 3.5.8 | [guides/bigdata.md](guides/bigdata.md) |
| `ora` | `oracle` | local `oracle/` | Oracle 19c (2 instances) | [guides/distributed-database.md](guides/distributed-database.md) |
| `mssql` | `mssql` | local `mssql/` | MSSQL 2025 (3 instances) | [guides/distributed-database.md](guides/distributed-database.md) |
| `localstack` | `localstack` | `localstack/localstack` | LocalStack Pro (AWS emulator) | [guides/localstack.md](guides/localstack.md) |
| `log` | `logging` | local `logging/` | Loki + Grafana Alloy | [guides/logging.md](guides/logging.md) |
| `mon` | `monitoring` | `kube-prometheus-stack` | Prometheus + Grafana | [guides/monitoring.md](guides/monitoring.md) |
| `cfd` | `cloudflared` | local `cloudflared/` | Cloudflare Tunnel (2 replicas) | [guides/cloudflared.md](guides/cloudflared.md) |
| — | `sure` | raw manifests | Sure Finance App (Rails + PG + Redis) | [guides/sure.md](guides/sure.md) |
| `headlamp` | `kube-system` | `headlamp/headlamp` | K8s Dashboard UI | [guides/headlamp.md](guides/headlamp.md) |

---

## 5. Secrets (`infra-secrets`)

Sensitive values stored in K8s Secret `infra-secrets` (one per namespace).
YAML charts use `secretKeyRef` — **never hardcode** values in `values.yaml`.

```bash
# Initialize/update all secrets (reads from .env or uses defaults)
./init-sec.sh

# Initialize for a specific namespace only
./init-sec.sh <namespace>
```

| Key | Used by | Description |
|-----|---------|-------------|
| `cloudflare-token` | `cloudflared` | Tunnel token |
| `localstack-token` | `localstack` | Pro license key |
| `grafana-admin-password` | `monitoring` | Grafana admin password |
| `admin-user` / `admin-password` | `monitoring` | Grafana auth (existingSecret) |
| `mssql-password` | `mssql` | SA password |
| `oracle-password` | `oracle` | SYS password |
| `sure-secret-key-base` | `sure` | Rails Secret Key Base |
| `sure-postgres-password` | `sure` | Postgres password |

```bash
# View a secret value
kubectl get secret infra-secrets -n <namespace> -o jsonpath='{.data.<key>}' | base64 -d
```

---

## 6. Service Access

| Service | URL | Port |
|---------|-----|------|
| Grafana | `https://grafana.<domain>` · `http://<ip>:30300` | NodePort 30300 |
| Prometheus | `http://<ip>:30090` | NodePort 30090 |
| Headlamp | `https://headlamp.<domain>` | ClusterIP → Tunnel |
| HDFS WebUI | `http://<ip>:9870` | hostPort |
| YARN WebUI | `http://<ip>:8088` | hostPort |
| Spark WebUI | `http://<ip>:30808` | NodePort 30808 |
| Loki | `http://<ip>:30100` | NodePort 30100 |
| Oracle | `<ip>:31521` | NodePort 31521 |
| MSSQL | `<ip>:31433` | NodePort 31433 |
| LocalStack | `http://<ip>:30566` | NodePort 30566 |
| Sure App | `http://<ip>:30333` | NodePort 30333 |

---

## 7. Adding a K3s Node

### Prerequisites

1. Tailscale installed and joined to the same tailnet
2. New node can ping master: `ping <master-ip>`
3. Port `6443` accessible via Tailscale

### Get token

```bash
# On the first master node
sudo cat /var/lib/rancher/k3s/server/node-token
```

### Add Master (server)

```bash
curl -sfL https://get.k3s.io | \
    K3S_URL=https://<master-ip>:6443 \
    K3S_TOKEN=<TOKEN> \
    sh -s - server \
    --node-ip=<TAILSCALE_IP> \
    --advertise-address=<TAILSCALE_IP> \
    --flannel-iface=tailscale0 \
    --write-kubeconfig-mode 644 \
    --tls-san=<TAILSCALE_IP>
```

### Add Worker (agent)

```bash
curl -sfL https://get.k3s.io | \
    K3S_URL=https://<master-ip>:6443 \
    K3S_TOKEN=<TOKEN> \
    sh -s - agent \
    --node-ip=<TAILSCALE_IP> \
    --flannel-iface=tailscale0
```

### After joining

```bash
kubectl get nodes
kubectl label node <name> node-role.kubernetes.io/worker=worker
```

---

## 8. HA Migration (Single Master → 3 Masters)

### Step 1 — Enable cluster-init on current master

```bash
sudo systemctl stop k3s
curl -sfL https://get.k3s.io | sh -s - server \
    --cluster-init \
    --node-ip=<master-ip> \
    --flannel-iface=tailscale0
sudo cat /var/lib/rancher/k3s/server/node-token
```

### Step 2 — Join master #2 and #3

Use the "Add Master" command from section 7.

### Step 3 — Convert worker to master (if needed)

```bash
/usr/local/bin/k3s-agent-uninstall.sh
# Then run "Add Master" command
```

### HA Notes

- **Minimum 3 masters** for HA (etcd Raft quorum)
- 1 master offline → cluster operational (2/3 quorum)
- 2 masters offline → **quorum lost**, read-only
- Inter-master ping should be < 100ms
- Worker offline does **not** affect control plane

---

## 9. Directory Structure

```
k3s-homelab/
├── k3s.sh                  # Main dispatcher (deploy/scale/delete/health)
├── ck.sh                   # Cluster diagnostics (7 sections + export)
├── init-sec.sh             # Secret initialization (all namespaces)
├── _lib.sh                 # Shared helpers (colors, kubectl wrappers, IP detection)
├── README.md               # This file
├── CLAUDE.md               # AI assistant instructions
├── guides/                 # Service documentation
│   ├── bigdata.md          # Hadoop + Spark guide
│   ├── distributed-database.md  # Oracle + MSSQL guide
│   ├── monitoring.md       # Prometheus + Grafana guide
│   ├── logging.md          # Loki + Alloy guide
│   ├── cloudflared.md      # Cloudflare Tunnel guide
│   ├── localstack.md       # LocalStack Pro guide
│   ├── sure.md             # Sure Finance App guide
│   └── headlamp.md         # Headlamp K8s Dashboard guide
├── svc-scripts/            # Component scripts
│   ├── bigdata.sh          # BigData (deploy/scale/check)
│   ├── oracle.sh           # Oracle (deploy/scale/check)
│   ├── mssql.sh            # MSSQL (deploy/scale/check)
│   ├── monitoring.sh       # Monitoring (deploy/check)
│   ├── logging.sh          # Logging (deploy/logs)
│   ├── localstack.sh       # LocalStack (deploy/check)
│   ├── cfd.sh              # Cloudflare Tunnel (deploy)
│   ├── sure.sh             # Sure (deploy/setup/check)
│   └── headlamp.sh         # Headlamp (deploy/token)
├── bigdata/                # Helm chart: Hadoop + Spark
├── oracle/                 # Helm chart: Oracle 19c
├── mssql/                  # Helm chart: MSSQL 2025
├── logging/                # Helm chart: Loki + Alloy
├── monitoring/             # Values: kube-prometheus-stack
├── cloudflared/            # Helm chart: Cloudflare Tunnel
├── localstack/             # Values: localstack/localstack
├── sure/                   # Raw K8s manifests
└── ck/                     # Export output (ck-*.txt)
```

---

## Helm Repos (one-time setup)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add localstack https://helm.localstack.cloud
helm repo add headlamp https://headlamp-k8s.github.io/headlamp/
helm repo update
```
