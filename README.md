# K3S Homelab — Cụm Hệ Thống Phân Tán

> **5 node** kết nối qua Tailscale mesh VPN — 3 master (HA embedded etcd) + 2 worker
> Quản lý triển khai: ArgoCD · Chẩn đoán: `ck.sh` · Secrets: `init-sec.sh`

---

## 1. Topology

| Node | Vai trò | OS | Tailscale IP | Workloads |
|------|---------|----|--------------|-----------|
| `<node-1>` | master | Ubuntu | `<ip-1>` | monitoring, logging, bigdata masters, localstack, headlamp |
| `<node-2>` | master | Ubuntu | `<ip-2>` | cloudflared, sure-stack |
| `<node-3>` | master | Fedora | `<ip-3>` | oracle-db-0, mssql-db-1, bigdata workers |
| `<node-4>` | worker | Ubuntu | `<ip-4>` | mssql-db-0 · **có thể offline** |
| `<node-5>` | worker | Ubuntu (WSL2) | `<ip-5>` | oracle-db-1, mssql-db-2, bigdata workers · **có thể offline** |

### Node Labels (bắt buộc)

Workloads dùng `nodeSelector` để chọn node. Gán label trước khi triển khai:

```bash
# Monitoring & Logging
kubectl label node <node> node-role.kubernetes.io/monitoring=true
kubectl label node <node> node-role.kubernetes.io/logging=true

# BigData
kubectl label node <node> node-role.kubernetes.io/bigdata-master=true
kubectl label node <node> node-role.kubernetes.io/bigdata-worker=true

# Cơ sở dữ liệu
kubectl label node <node> node-role.kubernetes.io/database-oracle=true
kubectl label node <node> node-role.kubernetes.io/database-mssql=true

# Sure App
kubectl label node <node> app-host=sure
```

---

## 2. Quản lý cụm (ArgoCD)

Mọi triển khai được quản lý bởi **ArgoCD** theo mô hình app-of-apps. Dùng ArgoCD CLI hoặc giao diện web tại `https://argocd.helios.id.vn`.

### Các lệnh thường dùng

```bash
argocd app list                            # Xem trạng thái tất cả apps
argocd app get <app>                       # Chi tiết một app
argocd app sync <app> --grpc-web           # Đồng bộ một app
argocd app sync root --grpc-web            # Đồng bộ tất cả (qua root)
argocd app delete <app> --cascade          # Xóa app và tài nguyên
```

### Thứ tự sync (lần đầu)

```bash
argocd app sync root --grpc-web        # Tạo tất cả child apps
argocd app sync cloudflared --grpc-web # 1. Tunnel trước (mở đường vào cluster)
argocd app sync logging --grpc-web     # 2. Logging
argocd app sync monitoring --grpc-web  # 3. Monitoring
argocd app sync localstack --grpc-web  # 4. LocalStack
argocd app sync redshark --grpc-web    # 5. RedShark API
argocd app sync sure --grpc-web        # 6. Sure App
# ... còn lại theo thứ tự tùy ý
```

### Hành vi khi node offline

- Worker offline → pod chuyển **Pending** (không reschedule do hard anti-affinity)
- Scale về 0 → pod bị xóa, **PVC được giữ nguyên**
- Scale lại → pod tái tạo, mount lại PVC cũ

### Bootstrap ArgoCD (một lần duy nhất)

```bash
# Toàn bộ luồng: cài ArgoCD + đăng ký repo + apply root app
bash svc-scripts/argocd.sh bootstrap

# Hoặc từng bước:
bash svc-scripts/argocd.sh install      # Cài ArgoCD vào cluster
bash svc-scripts/argocd.sh login        # Đăng nhập ArgoCD CLI
bash svc-scripts/argocd.sh add-repo     # Đăng ký repo GitHub (deploy key)
bash svc-scripts/argocd.sh apply-root   # Apply root Application
```

---

## 3. Chẩn đoán cụm (`ck.sh`)

```bash
./ck.sh                    # Kiểm tra toàn bộ — 7 phần
./ck.sh sys                # [1/7] Hệ thống & tải (RAM, CPU, disk, uptime)
./ck.sh node               # [2/7] Nodes & bố cục pod (nhóm theo node)
./ck.sh secrets            # [3/7] Secrets (theo namespace, chỉ hiện tên)
./ck.sh pvc                # [4/7] PVC / Storage (nhóm theo node)
./ck.sh res                # [5/7] Tài nguyên triển khai (deploy, sts, ds, hpa, svc)
./ck.sh img                # [6/7] Images & mức sử dụng theo node
./ck.sh helm               # [7/7] Helm releases
```

### Lọc theo namespace

```bash
./ck.sh res bigdata        # Tài nguyên trong namespace bigdata
```

### Xuất báo cáo

```bash
./ck.sh export             # → ck/ck-HHmmss-ddMMyy.txt
```

---

## 4. Helm Charts

| Release | Namespace | Chart | Mô tả | Hướng dẫn |
|---------|-----------|-------|-------|-----------|
| `bigd` | `bigdata` | local `bigdata/` | Hadoop 3.2.1 + Spark 3.5.8 | [guides/bigdata.md](guides/bigdata.md) |
| `ora` | `oracle` | local `oracle/` | Oracle 19c (2 instances) | [guides/distributed-database.md](guides/distributed-database.md) |
| `mssql` | `mssql` | local `mssql/` | MSSQL 2025 (3 instances) | [guides/distributed-database.md](guides/distributed-database.md) |
| `localstack` | `localstack` | `localstack/localstack` | LocalStack Pro (giả lập AWS) | [guides/localstack.md](guides/localstack.md) |
| `log` | `logging` | local `logging/` | Loki + Grafana Alloy | [guides/logging.md](guides/logging.md) |
| `mon` | `monitoring` | `kube-prometheus-stack` | Prometheus + Grafana | [guides/monitoring.md](guides/monitoring.md) |
| `cfd` | `cloudflared` | local `cloudflared/` | Cloudflare Tunnel (2 replicas) | [guides/cloudflared.md](guides/cloudflared.md) |
| — | `sure` | raw manifests | Sure Finance App (Rails + PG + Redis) | [guides/sure.md](guides/sure.md) |
| `headlamp` | `kube-system` | `headlamp/headlamp` | K8s Dashboard UI | [guides/headlamp.md](guides/headlamp.md) |

---

## 5. Secrets (`infra-secrets`)

Giá trị nhạy cảm lưu trong K8s Secret `infra-secrets` (một bản mỗi namespace).
Các chart dùng `secretKeyRef` — **không bao giờ hardcode** trong `values.yaml`.

```bash
# Khởi tạo/cập nhật secrets tất cả namespace (đọc từ .env)
./init-sec.sh

# Khởi tạo cho một namespace cụ thể
./init-sec.sh <namespace>

# Xem giá trị một key
kubectl get secret infra-secrets -n <namespace> -o jsonpath='{.data.<key>}' | base64 -d
```

| Key | Dùng bởi | Mô tả |
|-----|----------|-------|
| `cloudflare-token` | `cloudflared` | Token Cloudflare Tunnel |
| `localstack-token` | `localstack` | License key LocalStack Pro |
| `grafana-admin-password` | `monitoring` | Mật khẩu admin Grafana |
| `admin-user` / `admin-password` | `monitoring` | Auth Grafana (existingSecret) |
| `mssql-password` | `mssql` | Mật khẩu SA |
| `oracle-password` | `oracle` | Mật khẩu SYS |
| `sure-secret-key-base` | `sure` | Rails Secret Key Base |
| `sure-postgres-password` | `sure` | Mật khẩu Postgres |

---

## 6. Truy cập dịch vụ

| Dịch vụ | URL | Cổng |
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

## 7. Thêm node K3s

### Điều kiện

1. Tailscale đã cài và join vào cùng tailnet
2. Node mới ping được master: `ping <master-ip>`
3. Cổng `6443` mở qua Tailscale

### Lấy token

```bash
# Trên master đầu tiên
sudo cat /var/lib/rancher/k3s/server/node-token
```

### Thêm Master (server)

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

### Thêm Worker (agent)

```bash
curl -sfL https://get.k3s.io | \
    K3S_URL=https://<master-ip>:6443 \
    K3S_TOKEN=<TOKEN> \
    sh -s - agent \
    --node-ip=<TAILSCALE_IP> \
    --flannel-iface=tailscale0
```

### Sau khi join

```bash
kubectl get nodes
kubectl label node <name> node-role.kubernetes.io/worker=worker
```

---

## 8. Chuyển đổi HA (1 Master → 3 Masters)

### Bước 1 — Bật cluster-init trên master hiện tại

```bash
sudo systemctl stop k3s
curl -sfL https://get.k3s.io | sh -s - server \
    --cluster-init \
    --node-ip=<master-ip> \
    --flannel-iface=tailscale0
sudo cat /var/lib/rancher/k3s/server/node-token
```

### Bước 2 — Join master #2 và #3

Dùng lệnh "Thêm Master" ở mục 7.

### Bước 3 — Chuyển worker thành master (nếu cần)

```bash
/usr/local/bin/k3s-agent-uninstall.sh
# Sau đó chạy lệnh "Thêm Master"
```

### Lưu ý HA

- **Tối thiểu 3 master** để đảm bảo HA (etcd Raft quorum)
- 1 master offline → cụm vẫn hoạt động (quorum 2/3)
- 2 master offline → **mất quorum**, chỉ đọc
- Ping giữa các master nên < 100ms
- Worker offline **không ảnh hưởng** control plane

---

## 9. Cấu trúc thư mục

```
k3s-homelab/
├── ck.sh                   # Chẩn đoán cụm (7 phần + xuất báo cáo)
├── init-sec.sh             # Khởi tạo infra-secrets (tất cả namespace)
├── _lib.sh                 # Thư viện dùng chung (màu sắc, kubectl wrappers)
├── README.md               # File này
├── argocd-apps/            # ArgoCD Application manifests (app-of-apps)
│   ├── root.yaml           # Root Application — theo dõi argocd-apps/
│   ├── cloudflared.yaml    # Cloudflare Tunnel
│   ├── monitoring.yaml     # kube-prometheus-stack (multi-source)
│   ├── logging.yaml        # Loki + Alloy
│   ├── localstack.yaml     # LocalStack Pro (multi-source)
│   ├── headlamp.yaml       # Headlamp K8s Dashboard (multi-source)
│   ├── sure.yaml           # Sure Finance App (raw manifests)
│   ├── bigdata.yaml        # Hadoop + Spark
│   ├── oracle.yaml         # Oracle 19c
│   ├── mssql.yaml          # MSSQL 2025
│   └── redshark.yaml       # RedShark API
├── services/               # Helm charts và values
│   ├── bigdata/            # Chart cục bộ: Hadoop + Spark
│   ├── oracle/             # Chart cục bộ: Oracle 19c
│   ├── mssql/              # Chart cục bộ: MSSQL 2025
│   ├── logging/            # Chart cục bộ: Loki + Alloy
│   ├── monitoring/         # Values only: kube-prometheus-stack
│   ├── cloudflared/        # Chart cục bộ: Cloudflare Tunnel
│   ├── localstack/         # Values only: localstack/localstack
│   ├── headlamp/           # Values only: headlamp/headlamp
│   ├── sure/               # Raw K8s manifests
│   └── redshark/           # Chart cục bộ: RedShark API
├── svc-scripts/            # Scripts vận hành
│   └── argocd.sh           # Bootstrap ArgoCD (cài đặt, đăng nhập, đăng ký repo)
├── guides/                 # Tài liệu chi tiết từng dịch vụ
│   ├── bigdata.md
│   ├── distributed-database.md
│   ├── monitoring.md
│   ├── logging.md
│   ├── cloudflared.md
│   ├── localstack.md
│   ├── sure.md
│   └── headlamp.md
└── ck/                     # Thư mục xuất báo cáo (ck-*.txt)
```

---

## Helm Repos (cài một lần)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add localstack https://helm.localstack.cloud
helm repo add headlamp https://headlamp-k8s.github.io/headlamp/
helm repo update
```
