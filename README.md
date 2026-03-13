# K3S Homelab - K8s cluster cho các dịch vụ nội bộ

> **5 nodes** qua Tailscale mesh VPN — 3 master (HA embedded etcd) + 2 worker  
> Quản lý: `mng.sh` · Kiểm tra: `ck.sh` · Health check: `bigdata-check.sh` `ddb-check.sh` `ls-check.sh` `mon-check.sh` `sure.md`

---

## 1. Topology

| Node | Role | OS (Ví dụ) | Tailscale IP | Workloads |
|------|------|----|-------------|-----------|
| `<node-1>` | master | Ubuntu | `<ip-1>` | monitoring, logging, bigdata masters, localstack, headlamp |
| `<node-2>` | master | Ubuntu | `<ip-2>` | cloudflared, **sure-stack** |
| `<node-3>` | master | Fedora | `<ip-3>` | oracle-db-0, mssql-db-1, bigdata workers |
| `<node-4>` | worker | Ubuntu | `<ip-4>` | mssql-db-0 · **có thể offline bất kỳ lúc nào** |
| `<node-5>` | worker | Ubuntu (WSL2) | `<ip-5>` | oracle-db-1, mssql-db-2, bigdata workers · **có thể offline bất kỳ lúc nào** |

```
■ <node-1> [master]     ── monitoring, logging, bigdata masters, localstack, headlamp
■ <node-2> [master]  ── cloudflared
■ <node-3> [master]                 ── oracle-db-0, mssql-db-1, bigdata workers
■ <node-4> [worker]                 ── mssql-db-0, sure-stack (web, worker, pg, redis)
■ <node-5> [worker]               ── oracle-db-1, mssql-db-2, bigdata workers
```


### Cấu hình Labels (Bắt buộc)

Các workloads (Database, Monitoring, Big Data) được phân bổ qua `nodeSelector`. Để Pods có thể boot up thành công, bạn phải gán các label theo role sau:

```bash
# Node cấu hình làm Management/Master (Monitoring, Logging, v.v...)
kubectl label node <node-1> node-role.kubernetes.io/monitoring="true"
kubectl label node <node-1> node-role.kubernetes.io/logging="true"
kubectl label node <node-1> node-role.kubernetes.io/localstack="true"
kubectl label node <node-1> node-role.kubernetes.io/bigdata-master="true"

# Node chạy Database & Big Data Workers (Ví dụ <node-3>, <node-4>, <node-5>)
kubectl label node <node-3> node-role.kubernetes.io/database="true"
kubectl label node <node-3> node-role.kubernetes.io/bigdata-worker="true"

# Node chạy Sure App (Ví dụ <node-4>)
kubectl label node <node-4> app-host=sure
```

---

## 2. Quản lý Cluster (`mng.sh`)

```bash
bash ./mng.sh deploy   [bigdata|oracle|mssql|localstack|logging|monitoring|cloudflared|headlamp|sure|all]
bash ./mng.sh delete   [bigdata|oracle|mssql|localstack|logging|monitoring|cloudflared|headlamp|sure|all]
bash ./mng.sh redeploy [bigdata|oracle|mssql|localstack|logging|monitoring|cloudflared|headlamp|sure|all]
bash ./mng.sh scale    [bigdata|oracle|mssql] [0|1|2|3]
bash ./mng.sh status
bash ./mng.sh logs     [bigdata|oracle|mssql|localstack|logging|monitoring|cloudflared|sure|sure-worker|alloy]
bash ./mng.sh health
bash ./mng.sh nuke                             # ⚠ Xóa TẤT CẢ (PVC + namespace)
```

| Hành động | Mô tả |
|-----------|-------|
| `deploy` | `helm install` (lần đầu) hoặc `helm upgrade` (đã tồn tại) |
| `delete` | Force xóa toàn bộ (pods, PVC, CRDs, namespace) |
| `redeploy` | `delete` + `deploy` lại sạch |
| `scale N` | Đổi replicas (0 = tắt hết, giữ PVC) |
| `nuke` | Xóa **tất cả** namespaces + PVC. Không hỏi lại. |

### Hành vi khi node offline

- Worker offline → pods trên node đó chuyển **Pending** (không reschedule vì anti-affinity cứng)
- Scale về 0 → tất cả pods terminated, **PVC giữ nguyên**
- Scale lên lại → pods tự tạo mới, mount PVC cũ

---

## 3. Kiểm tra Cluster (`ck.sh`)

```bash
ck.sh                       # Full check — tất cả 7 sections
ck.sh sys                   # [1/7] Hệ thống & tải (RAM, CPU, disk, uptime)
ck.sh node                  # [2/7] Nodes & Pods layout (gộp theo node)
ck.sh secrets               # [3/7] Secrets (theo namespace, chỉ hiện tên)
ck.sh pvc                   # [4/7] PVC / Storage (gộp theo node)
ck.sh res                   # [5/7] Deployed resources (deploy, sts, ds, hpa, svc)
ck.sh img                   # [6/7] Images & usage per node
ck.sh helm                  # [7/7] Helm releases
```

### Detail mode

```bash
ck.sh node <node-name>         # kubectl describe node <node-name>
ck.sh pod loki-0            # kubectl describe pod (tự detect namespace)
ck.sh pvc loki-data         # kubectl describe pvc (tự detect namespace)
ck.sh res bigdata           # Resources chỉ namespace bigdata
```

### Export

```bash
ck.sh export                # → ck/ck-HHmmss-ddMMyy.txt (full, có section headers)
ck.sh export .              # Tương tự
ck.sh export -c             # → ck/ck-HHmmss-ddMMyy-compact.txt (gộp pods/pvc, bỏ decoration, giữ 100% data)
```

### Health check chuyên biệt

| Script | Kiểm tra | Sections |
|--------|----------|----------|
| `bigdata-check.sh` | HDFS NameNode/DataNode, YARN RM/NM, Spark Master/Worker, cross-component, endpoints | 6 |
| `ddb-check.sh` | Oracle listener/instance, MSSQL sqlcmd, cross-instance connectivity | 6 |
| `ls-check.sh` | LocalStack pod, API health, services status, S3/SQS smoke test | 4 |
| `mon-check.sh` | Prometheus targets, Grafana login, Loki push/query, Alloy DaemonSet, node-exporter | 5 |

---

## 4. Helm Charts

| Release | Namespace | Chart | Mô tả | Doc |
|---------|-----------|-------|-------|-----|
| `bigd` | `bigdata` | local `bigdata/` | Hadoop 3.2.1 + Spark 3.5.8 | `big-data.md` |
| `ora` | `oracle` | local `oracle/` | Oracle 19c × 2 instances | `distributed-database.md` |
| `mssql` | `mssql` | local `mssql/` | MSSQL 2025 × 3 instances | `distributed-database.md` |
| `localstack` | `localstack` | `localstack/localstack` | LocalStack Pro (AWS emulator) | `localstack.md` |
| `log` | `logging` | local `logging/` | Loki + Grafana Alloy | `logging.md` |
| `mon` | `monitoring` | `kube-prometheus-stack` | Prometheus + Grafana | `monitoring.md` |
| `cfd` | `cloudflared` | local `cloudflared/` | Cloudflare Tunnel (2 replicas) | `cloudflared.md` |
| `sure` | `sure` | local `sure/` | Finance Management App (Rails + PG + Redis) | `sure.md` |
| `headlamp` | `kube-system` | `headlamp/headlamp` | K8s Dashboard UI | — |

---

## 5. Secrets (`infra-secrets`)

Sensitive values được lưu trong K8s Secret `infra-secrets` (mỗi namespace 1 bản).  
YAML charts dùng `secretKeyRef` — **không hardcode** giá trị trong values.yaml.

```bash
# Tạo/update cho tất cả namespaces
for ns in cloudflared localstack monitoring mssql oracle sure; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic infra-secrets \
    --from-literal=cloudflare-token='<CLOUDFLARE_TUNNEL_TOKEN>' \
    --from-literal=localstack-token='<LOCALSTACK_AUTH_TOKEN>' \
    --from-literal=grafana-admin-password='<GRAFANA_PASSWORD>' \
    --from-literal=admin-user='admin' \
    --from-literal=admin-password='<GRAFANA_PASSWORD>' \
    --from-literal=mssql-password='<MSSQL_SA_PASSWORD>' \
    --from-literal=oracle-password='<ORACLE_SYS_PASSWORD>' \
    --from-literal=sure-secret-key-base='$(head -c 64 /dev/urandom | od -An -tx1 | tr -d " \n")' \
    --from-literal=sure-postgres-password='<SURE_DB_PASSWORD>' \
    -n "$ns" --dry-run=client -o yaml | kubectl apply -f -
done
```

| Key | Dùng bởi | Mô tả |
|-----|----------|-------|
| `cloudflare-token` | `cloudflared` | Tunnel token (Cloudflare Dashboard → Zero Trust → Tunnels) |
| `localstack-token` | `localstack` | Pro license key (`LOCALSTACK_AUTH_TOKEN`) |
| `grafana-admin-password` | `monitoring` | Grafana admin password (legacy key, giữ cho backward compat) |
| `admin-user` | `monitoring` | Grafana admin username (`admin.existingSecret.userKey`) |
| `admin-password` | `monitoring` | Grafana admin password (`admin.existingSecret.passwordKey`) |
| `mssql-password` | `mssql` | SA password (`MSSQL_SA_PASSWORD`) |
| `oracle-password` | `oracle` | SYS password (`ORACLE_PWD`) |
| `sure-secret-key-base` | `sure` | Rails Secret Key Base |
| `sure-postgres-password` | `sure` | Postgres Password cho Sure App |

```bash
# Xem giá trị secret
kubectl get secret infra-secrets -n <namespace> -o jsonpath='{.data.<key>}' | base64 -d
```

---

## 6. Truy cập Services

| Service | URL (Tailscale) | Port |
|---------|----------------|------|
| Grafana | `https://grafana.<your-domain>` · `http://<node-ip>:30300` | NodePort `30300` |
| Prometheus | `http://<node-ip>:30090` | NodePort `30090` |
| Headlamp | `https://headlamp.<your-domain>` | ClusterIP → Cloudflare Tunnel |
| HDFS WebUI | `http://<node-ip>:9870` | hostPort |
| YARN WebUI | `http://<node-ip>:8088` | hostPort |
| Spark WebUI | `http://<node-ip>:30808` | NodePort `30808` |
| Loki | `http://<node-ip>:30100` | NodePort `30100` |
| Oracle | `<node-Tailscale-IP>:31521` | NodePort `31521` |
| MSSQL | `<node-Tailscale-IP>:31433` | NodePort `31433` |
| LocalStack | `http://<node-ip>:30566` | NodePort `30566` |
| Sure App | `http://<node-ip>:30333` | NodePort `30333` |

> Oracle/MSSQL: kết nối qua IP của **node đang chạy pod**

---

## 7. Cài đặt K3s Node mới

### Yêu cầu

1. **Tailscale** đã cài và login cùng Tailnet:
   ```bash
   curl -fsSL https://tailscale.com/install.sh | sh
   sudo tailscale up
   ```
2. Node mới ping được master: `ping <master-ip>`
3. Port `6443` accessible qua Tailscale

### Lấy token

Trên **master node đầu tiên** (`<node-1>`):

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

### Thêm Master (server)

```bash
curl -sfL https://get.k3s.io | \
    K3S_URL=https://<master-ip>:6443 \
    K3S_TOKEN=<TOKEN> \
    sh -s - server \
    --node-ip=<TAILSCALE_IP_CỦA_NODE_MỚI> \
    --advertise-address=<TAILSCALE_IP_CỦA_NODE_MỚI> \
    --flannel-iface=tailscale0 \
    --write-kubeconfig-mode 644 \
    --tls-san=<TAILSCALE_IP_CỦA_NODE_MỚI>
```

### Thêm Worker (agent)

```bash
curl -sfL https://get.k3s.io | \
    K3S_URL=https://<master-ip>:6443 \
    K3S_TOKEN=<TOKEN> \
    sh -s - agent \
    --node-ip=<TAILSCALE_IP_CỦA_NODE_MỚI> \
    --flannel-iface=tailscale0
```

### Sau khi join

```bash
kubectl get nodes                     # Xác nhận node đã join
kubectl label node <tên> node-role.kubernetes.io/worker=worker   # Label nếu cần
```

---

## 8. Migration: Chuyển sang HA (3 Master)

> Áp dụng khi cluster đang chạy single-master và muốn chuyển sang HA embedded etcd.

### Bước 1 — Bật cluster-init trên master hiện tại

```bash
# SSH vào master hiện tại
sudo systemctl stop k3s
curl -sfL https://get.k3s.io | sh -s - server \
    --cluster-init \
    --node-ip=<master-ip> \
    --flannel-iface=tailscale0
```

Lấy token sau khi khởi động lại:

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

### Bước 2 — Join master #2 và #3

Dùng lệnh **"Thêm Master"** ở mục 7 với token vừa lấy.

### Bước 3 — Chuyển worker thành master (nếu cần)

```bash
# SSH vào worker node
/usr/local/bin/k3s-agent-uninstall.sh   # Gỡ agent
# Rồi chạy lệnh "Thêm Master" ở mục 7
```

### Bước 4 — Kiểm tra

```bash
kubectl get nodes
# Tất cả master: STATUS=Ready, ROLES=control-plane,master
```

### Lưu ý HA

- **Tối thiểu 3 master** cho HA (etcd Raft consensus cần đa số)
- 1 master offline → cluster vẫn hoạt động (2/3 quorum)
- 2 master offline → cluster **mất quorum**, read-only
- Ping giữa masters nên < 100ms (etcd heartbeat timeout)
- Worker node offline **không** ảnh hưởng control plane

---

## 9. Cấu trúc thư mục

```
k3s-homelab/
├── mng.sh                  # Quản lý deploy/scale/delete/health
├── ck.sh                   # Cluster check (7 sections + export)
├── bigdata-check.sh        # Health check Hadoop + Spark
├── ddb-check.sh            # Health check Oracle + MSSQL
├── ls-check.sh             # Health check LocalStack
├── mon-check.sh            # Health check Monitoring stack
├── README.md               # ← Tài liệu này
├── big-data.md             # Lab: BigData (Hadoop + Spark)
├── distributed-database.md # Lab: CSDL Phân tán (Oracle + MSSQL)
├── localstack.md           # Doc: LocalStack
├── logging.md              # Doc: Logging
├── monitoring.md           # Doc: Monitoring
├── cloudflared.md          # Doc: Cloudflare Tunnel
├── sure.md                 # Doc: Sure App
├── bigdata/                # Helm chart: Hadoop 3.2.1 + Spark 3.5.8
├── oracle/                 # Helm chart: Oracle 19c
├── mssql/                  # Helm chart: MSSQL 2025
├── localstack/             # Values: localstack/localstack chart
├── logging/                # Helm chart: Loki + Alloy
├── monitoring/             # Values: kube-prometheus-stack
├── cloudflared/            # Helm chart: Cloudflare Tunnel
├── sure/                   # Manifests: Sure App stack
└── ck/                     # Export output (ck-*.txt)
```
