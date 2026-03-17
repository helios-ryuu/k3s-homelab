# K3S Homelab — Cụm Hệ Thống Phân Tán

> **5 node** kết nối qua Tailscale mesh VPN — 3 master (HA embedded etcd) + 2 worker
> Quản lý triển khai: ArgoCD · Chẩn đoán: `ck.sh` · Secrets: `init-sec.sh`

Xem [SETUP.md](SETUP.md) để khởi tạo cụm từ đầu.

---

## Topology

| Node | Hostname | OS | Tailscale IP | Vai trò | Workloads |
|------|----------|-----|--------------|---------|-----------|
| master-1 | `helios-imac-ubuntu` | Ubuntu | `100.102.51.39` | master | monitoring, logging, bigdata-master, localstack, sure |
| master-2 | `helios-droplet-ubuntu` | Ubuntu | `100.122.163.31` | master | cloudflared |
| master-3 | `helios` | Fedora | `100.110.86.71` | master | bigdata-worker, oracle-db-0, mssql-db-1 |
| worker-1 | `diepvi` | Ubuntu | `100.86.204.84` | worker | mssql-db-0 · **có thể offline** |
| worker-2 | `sinister` | Ubuntu | `100.73.216.110` | worker | bigdata-worker, oracle-db-1, mssql-db-2 · **có thể offline** |

---

## Truy cập dịch vụ

### Qua Cloudflare Tunnel (HTTPS, public)

| Dịch vụ | URL |
|---------|-----|
| ArgoCD | `https://argocd.helios.id.vn` |
| Grafana | `https://grafana.helios.id.vn` |
| LocalStack | `https://localstack.helios.id.vn` |
| Loki | `https://loki.helios.id.vn` |

### Qua NodePort (Tailscale, internal)

| Dịch vụ | Host | Port |
|---------|------|------|
| Grafana | `100.102.51.39` | `30300` |
| Prometheus | `100.102.51.39` | `30090` |
| Loki | `100.102.51.39` | `30100` |
| LocalStack | `100.102.51.39` | `30566` |
| Sure App | `100.102.51.39` | `30333` |
| Oracle (node-0) | `100.110.86.71` | `31521` |
| Oracle (node-1) | `100.73.216.110` | `31521` |
| MSSQL (db-0) | `100.86.204.84` | `31433` |
| MSSQL (db-1) | `100.110.86.71` | `31433` |
| MSSQL (db-2) | `100.73.216.110` | `31433` |
| HDFS WebUI | `100.102.51.39` | `9870` |
| YARN WebUI | `100.102.51.39` | `8088` |
| Spark WebUI | `100.102.51.39` | `30808` |

### Kết nối database nội bộ (trong cluster)

```
# Oracle
oracle-db-0.oracle-svc.oracle.svc.cluster.local:1521
oracle-db-1.oracle-svc.oracle.svc.cluster.local:1521
# TNS alias (tnsnames.ora): ORACLE_DB_0, ORACLE_DB_1

# MSSQL
mssql-db-0.mssql-svc.mssql.svc.cluster.local,1433
mssql-db-1.mssql-svc.mssql.svc.cluster.local,1433
mssql-db-2.mssql-svc.mssql.svc.cluster.local,1433
```

---

## Helm Charts

| Release | Namespace | Chart | Mô tả |
|---------|-----------|-------|-------|
| `bigd` | `bigdata` | local `services/bigdata/` | Hadoop 3.2.1 + Spark 3.5.8 |
| `ora` | `oracle` | local `services/oracle/` | Oracle 19c (2 instances) |
| `mssql` | `mssql` | local `services/mssql/` | MSSQL 2025 (3 instances) |
| `localstack` | `localstack` | `localstack/localstack` | LocalStack Pro (AWS emulator) |
| `log` | `logging` | local `services/logging/` | Loki 3.6.7 + Grafana Alloy |
| `mon` | `monitoring` | `prometheus-community/kube-prometheus-stack` `82.x` | Prometheus + Grafana |
| `cfd` | `cloudflared` | local `services/cloudflared/` | Cloudflare Tunnel (2 replicas) |
| — | `sure` | raw manifests `services/sure/` | Sure Finance App (Rails + PG + Redis) |
| — | `redshark` | local `services/redshark/` | RedShark API (Spring Boot) |

---

## Quản lý cụm

### Chẩn đoán (`ck.sh`)

```bash
./ck.sh                    # Kiểm tra toàn bộ — 6 phần
./ck.sh sys                # [1/6] Hệ thống & tải (RAM, CPU, disk, uptime)
./ck.sh node               # [2/6] Nodes & bố cục pod (nhóm theo node)
./ck.sh secrets            # [3/6] Secrets (theo namespace, chỉ hiện tên)
./ck.sh pvc                # [4/6] PVC / Storage (nhóm theo node)
./ck.sh res                # [5/6] Tài nguyên triển khai (deploy, sts, ds, hpa, svc)
./ck.sh res <namespace>    # Lọc theo namespace (vd: ./ck.sh res bigdata)
./ck.sh img                # [6/6] Images & mức sử dụng theo node
./ck.sh helm               # Helm releases
./ck.sh export             # Xuất báo cáo → ck/ck-HHmmss-ddMMyy.txt
```

### Quy trình thay đổi cấu hình

Mọi thay đổi đều qua Git → ArgoCD:

```
Sửa file trong services/ hoặc argocd-apps/
        ↓
git add <file> && git commit -m "..." && git push
        ↓
ArgoCD phát hiện OutOfSync
        ↓
argocd app sync <app> --grpc-web
```

**Ví dụ: thay đổi replica cloudflared**

```bash
vi services/cloudflared/values.yaml   # replicas: 2 → 3
git add services/cloudflared/values.yaml
git commit -m "feat(cloudflared): scale to 3 replicas"
git push
argocd app sync cloudflared --grpc-web
argocd app wait cloudflared --health --grpc-web
```

### Cập nhật Secrets

```bash
vi .env                        # Sửa giá trị
./init-sec.sh                  # Apply lại tất cả namespace
# ./init-sec.sh monitoring     # Hoặc chỉ một namespace

# Restart pod để nhận giá trị mới
kubectl rollout restart deployment/<name> -n <namespace>
```

### Xử lý app OutOfSync / lỗi

```bash
argocd app get <app> --grpc-web              # Xem lý do
argocd app get <app> --hard-refresh --grpc-web  # Force refresh cache
argocd app diff <app> --grpc-web             # Xem diff trước khi sync
argocd app sync <app> --grpc-web             # Sync thường
argocd app sync <app> --force --grpc-web     # Force replace (drift nặng)

# Debug pod
kubectl describe pod <pod> -n <namespace>
kubectl logs <pod> -n <namespace> --previous
```

### Xóa và triển khai lại app

```bash
argocd app delete <app> --cascade --grpc-web   # Xóa app + resources (PVC giữ lại)
argocd app sync root --grpc-web                # Root recreate child app
argocd app sync <app> --grpc-web               # Sync lại
```

---

## BigData — Scale thủ công

HDFS yêu cầu scale theo thứ tự để tránh mất dữ liệu:

```bash
# Scale DOWN (worker → nodemanager → resourcemanager → namenode)
kubectl scale sts hadoop-datanode   -n bigdata --replicas=0
kubectl scale sts spark-worker      -n bigdata --replicas=0
kubectl scale deploy hadoop-nodemgr -n bigdata --replicas=0
kubectl scale deploy hadoop-rmgr    -n bigdata --replicas=0
kubectl scale sts hadoop-namenode   -n bigdata --replicas=0

# Scale UP (namenode trước)
kubectl scale sts hadoop-namenode   -n bigdata --replicas=1
kubectl scale deploy hadoop-rmgr    -n bigdata --replicas=1
kubectl scale deploy hadoop-nodemgr -n bigdata --replicas=1
kubectl scale sts hadoop-datanode   -n bigdata --replicas=3
kubectl scale sts spark-worker      -n bigdata --replicas=2
```

> Sau khi scale, ArgoCD sẽ thấy OutOfSync. **Không sync** khi đang scale-down.

**Interactive PySpark:**
```bash
kubectl exec -it -n bigdata deploy/spark-master -- /opt/spark/bin/pyspark
```

---

## Hành vi khi node offline

| Tình huống | Kết quả |
|-----------|---------|
| Worker offline | Pod → Pending (hard anti-affinity, không reschedule) |
| Scale về 0 | Pod bị xóa, **PVC giữ nguyên** |
| Scale lại | Pod tái tạo, mount lại PVC cũ |
| 1/3 master offline | Cụm vẫn hoạt động (quorum 2/3) |
| 2/3 master offline | **Mất quorum**, chỉ đọc |

---

## CI/CD — GitHub Actions (NT118.Q22)

```
Push lên NT118.Q22
        ↓
GitHub Actions build Docker image → push registry
        ↓
Actions cập nhật image.tag trong services/redshark/values.yaml
        ↓
ArgoCD phát hiện OutOfSync → sync redshark
        ↓
Cluster rolling update
```

**Secret cần thiết trong repo NT118.Q22:**

| Secret | Mô tả |
|--------|-------|
| `K3S_HOMELAB_PAT` | Fine-grained PAT trên repo `k3s-homelab` với quyền **Contents: Read and Write** |

Tạo PAT: GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens.

---

## Cấu trúc thư mục

```
k3s-homelab/
├── ck.sh                   # Chẩn đoán cụm
├── init-sec.sh             # Khởi tạo infra-secrets (đọc từ .env)
├── _lib.sh                 # Thư viện dùng chung (màu sắc, helpers)
├── .env                    # Secrets — gitignored, tạo thủ công
├── README.md               # Kiến trúc và hướng dẫn sử dụng
├── SETUP.md                # Hướng dẫn khởi tạo cụm từ đầu
├── argocd/
│   └── kustomization.yaml  # Kustomize overlay: upstream install + control-plane affinity + insecure
├── argocd-apps/            # ArgoCD Application manifests (app-of-apps)
│   ├── root.yaml           # Root Application — theo dõi argocd-apps/
│   ├── services.yaml       # ApplicationSet — cloudflared, logging, mssql, oracle, bigdata, redshark, sure
│   ├── monitoring.yaml     # kube-prometheus-stack (multi-source)
│   └── localstack.yaml     # LocalStack Pro (multi-source)
├── services/               # Helm charts và values
│   ├── bigdata/            # Chart: Hadoop + Spark
│   ├── oracle/             # Chart: Oracle 19c
│   ├── mssql/              # Chart: MSSQL 2025
│   ├── logging/            # Chart: Loki + Alloy
│   ├── monitoring/         # Values only: kube-prometheus-stack
│   ├── cloudflared/        # Chart: Cloudflare Tunnel
│   ├── localstack/         # Values only: localstack/localstack
│   ├── sure/               # Raw K8s manifests
│   └── redshark/           # Chart: RedShark API
├── guides/                 # Tài liệu chi tiết từng dịch vụ
│   ├── bigdata.md
│   ├── distributed-database.md
│   ├── monitoring.md
│   ├── logging.md
│   ├── cloudflared.md
│   ├── localstack.md
│   └── sure.md
└── ck/                     # Thư mục xuất báo cáo (gitignored)
```

---

## HA Notes

- **Tối thiểu 3 master** để đảm bảo HA (etcd Raft quorum)
- 1 master offline → cụm vẫn hoạt động (quorum 2/3)
- 2 master offline → **mất quorum**, chỉ đọc
- Latency giữa các master nên < 100ms
- Worker offline **không ảnh hưởng** control plane
- Token lấy tại: `sudo cat /var/lib/rancher/k3s/server/node-token` (trên bất kỳ master)
