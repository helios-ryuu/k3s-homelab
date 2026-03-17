# K3S Homelab — Setup Guide

Hướng dẫn từng bước để khởi tạo cụm từ đầu.

---

## 0. Prerequisites

Cài đặt các công cụ sau trên máy quản lý trước khi bắt đầu:

| Tool | Phiên bản | Cài đặt |
|------|-----------|---------|
| `kubectl` | ≥ 1.30 | `curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && chmod +x kubectl && sudo mv kubectl /usr/local/bin/` |
| `helm` | ≥ 3.14 | `curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \| bash` |
| `argocd` CLI | v3.3.4 | `curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64 && sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd && rm argocd-linux-amd64` |
| `tailscale` | latest | `curl -fsSL https://tailscale.com/install.sh \| sh` |
| `git` | any | package manager |
| `base64`, `od` | (coreutils) | pre-installed trên hầu hết Linux |

### Helm repos (cài một lần)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add localstack https://helm.localstack.cloud
helm repo update
```

---

## 1. K3s Cluster

### 1.1 Khởi tạo master đầu tiên (cluster-init)

Chạy trên `helios-imac-ubuntu`:

```bash
curl -sfL https://get.k3s.io | sh -s - server \
    --cluster-init \
    --node-ip=100.102.51.39 \
    --advertise-address=100.102.51.39 \
    --flannel-iface=tailscale0 \
    --write-kubeconfig-mode 644 \
    --tls-san=100.102.51.39

# Lấy token để join các node khác
sudo cat /var/lib/rancher/k3s/server/node-token
```

### 1.2 Join master #2 và #3

Thay `<TOKEN>` bằng token lấy ở bước trên. Chạy trên từng node:

```bash
# master-2 (helios-droplet-ubuntu) — 100.122.163.31
curl -sfL https://get.k3s.io | \
    K3S_URL=https://100.102.51.39:6443 \
    K3S_TOKEN=<TOKEN> \
    sh -s - server \
    --node-ip=100.122.163.31 \
    --advertise-address=100.122.163.31 \
    --flannel-iface=tailscale0 \
    --write-kubeconfig-mode 644 \
    --tls-san=100.122.163.31

# master-3 (helios) — 100.110.86.71
curl -sfL https://get.k3s.io | \
    K3S_URL=https://100.102.51.39:6443 \
    K3S_TOKEN=<TOKEN> \
    sh -s - server \
    --node-ip=100.110.86.71 \
    --advertise-address=100.110.86.71 \
    --flannel-iface=tailscale0 \
    --write-kubeconfig-mode 644 \
    --tls-san=100.110.86.71
```

### 1.3 Join workers

```bash
# worker-1 (diepvi) — 100.86.204.84
curl -sfL https://get.k3s.io | \
    K3S_URL=https://100.102.51.39:6443 \
    K3S_TOKEN=<TOKEN> \
    sh -s - agent \
    --node-ip=100.86.204.84 \
    --flannel-iface=tailscale0

# worker-2 (sinister) — 100.73.216.110
curl -sfL https://get.k3s.io | \
    K3S_URL=https://100.102.51.39:6443 \
    K3S_TOKEN=<TOKEN> \
    sh -s - agent \
    --node-ip=100.73.216.110 \
    --flannel-iface=tailscale0
```

### 1.4 Cấu hình kubeconfig (trên máy quản lý)

```bash
scp helios-imac-ubuntu:/etc/rancher/k3s/k3s.yaml ~/.kube/config
sed -i 's/127.0.0.1/100.102.51.39/g' ~/.kube/config

kubectl get nodes
```

Kết quả mong đợi:
```
NAME                    STATUS   ROLES                  AGE
helios-imac-ubuntu      Ready    control-plane,etcd     ...
helios-droplet-ubuntu   Ready    control-plane,etcd     ...
helios                  Ready    control-plane,etcd     ...
diepvi                  Ready    <none>                 ...
sinister                Ready    <none>                 ...
```

### 1.5 Gán Node Labels

Mỗi workload dùng `nodeSelector` — gán đúng labels trước khi sync ArgoCD.

> **master-2 (`helios-droplet-ubuntu`) không có trong danh sách** — cloudflared dùng label built-in `node-role.kubernetes.io/control-plane` (k3s tự gán cho tất cả master), không cần label thủ công.

```bash
# master-1 (helios-imac-ubuntu) — monitoring, logging, localstack, bigdata-master, sure
kubectl label node helios-imac-ubuntu \
    node-role.kubernetes.io/monitoring=true \
    node-role.kubernetes.io/logging=true \
    node-role.kubernetes.io/localstack=true \
    node-role.kubernetes.io/bigdata-master=true \
    app-host=sure

# master-3 (helios) — bigdata-worker, oracle, mssql
kubectl label node helios \
    node-role.kubernetes.io/bigdata-worker=true \
    node-role.kubernetes.io/database-oracle=true \
    node-role.kubernetes.io/database-mssql=true

# worker-1 (diepvi) — mssql only
kubectl label node diepvi \
    node-role.kubernetes.io/database-mssql=true

# worker-2 (sinister) — bigdata-worker, oracle, mssql
kubectl label node sinister \
    node-role.kubernetes.io/bigdata-worker=true \
    node-role.kubernetes.io/database-oracle=true \
    node-role.kubernetes.io/database-mssql=true
```

> **Kiểm tra:** `kubectl get nodes --show-labels`

---

## 2. Secrets (`.env`)

Secrets **không được lưu trong Git**. Tạo file `.env` tại thư mục gốc repo:

```bash
cat > .env << 'EOF'
# Cloudflare Tunnel
CLOUDFLARE_TOKEN=<tunnel-token-từ-cloudflare-dashboard>

# LocalStack Pro
LOCALSTACK_TOKEN=<localstack-pro-license-key>

# Grafana
GRAFANA_ADMIN_PASSWORD=<mật-khẩu-grafana>

# MSSQL
MSSQL_PASSWORD=<mật-khẩu-sa-mssql>

# Oracle
ORACLE_PASSWORD=<mật-khẩu-sys-oracle>

# Sure Finance
SURE_POSTGRES_PASSWORD=<mật-khẩu-postgres-sure>

# RedShark API (LocalStack PostgreSQL)
REDSHARK_DB_USERNAME=<db-username-redshark>
REDSHARK_DB_PASSWORD=<db-password-redshark>
EOF
```

> `SURE_SECRET_KEY_BASE` được tự động tạo ngẫu nhiên bởi `init-sec.sh` và giữ nguyên qua các lần chạy.

### Khởi tạo secrets vào cluster

```bash
./init-sec.sh
```

Script tạo hai loại secret:

**`infra-secrets`** — trong các namespace: `cloudflared`, `localstack`, `monitoring`, `mssql`, `oracle`, `sure`, `kube-system`

| Key | Từ `.env` | Dùng bởi |
|-----|-----------|----------|
| `cloudflare-token` | `CLOUDFLARE_TOKEN` | cloudflared |
| `localstack-token` | `LOCALSTACK_TOKEN` | localstack |
| `grafana-admin-password` | `GRAFANA_ADMIN_PASSWORD` | monitoring |
| `admin-user` / `admin-password` | `GRAFANA_ADMIN_PASSWORD` | monitoring (existingSecret) |
| `mssql-password` | `MSSQL_PASSWORD` | mssql |
| `oracle-password` | `ORACLE_PASSWORD` | oracle |
| `sure-postgres-password` | `SURE_POSTGRES_PASSWORD` | sure |
| `sure-secret-key-base` | auto-generated | sure (Rails, preserved qua các lần chạy) |

**`redshark-secrets`** — chỉ trong namespace `redshark`

| Key | Từ `.env` | Dùng bởi |
|-----|-----------|----------|
| `db-username` | `REDSHARK_DB_USERNAME` | redshark API |
| `db-password` | `REDSHARK_DB_PASSWORD` | redshark API |

```bash
# Kiểm tra
kubectl get secret infra-secrets -n monitoring \
    -o jsonpath='{.data.grafana-admin-password}' | base64 -d
```

---

## 3. Bootstrap ArgoCD

### 3.1 Cài đặt ArgoCD

Cấu hình được định nghĩa trong `argocd/kustomization.yaml` — wraps upstream install manifest với các patches:
- Restrict tất cả workloads lên **control-plane nodes** (any master, không pin hostname cụ thể — nếu một master offline pods reschedule sang master khác)
- `argocd-server` chạy `--insecure` (TLS do Cloudflare Tunnel xử lý)

```bash
kubectl create namespace argocd 2>/dev/null || true
kubectl apply -n argocd --server-side -k argocd/

# Đợi server sẵn sàng
kubectl rollout status deployment argocd-server -n argocd --timeout=120s
```

### 3.2 Hai bước thủ công trước khi đăng nhập

Thực hiện song song trong khi đợi ArgoCD khởi động:

**a) GitHub — Tạo deploy key cho k3s-homelab repo**

```bash
ssh-keygen -t ed25519 -C 'argocd-deploy-key' -f /tmp/argocd-deploy-key -N ''
cat /tmp/argocd-deploy-key.pub
```

Vào `github.com/helios-ryuu/k3s-homelab` → Settings → Deploy keys → Add deploy key → dán public key → **Read-only** → Add key.

**b) Cloudflare — Thêm tunnel route cho ArgoCD**

> Zero Trust → Networks → Tunnels → `k3s` → Public Hostname → Add

| Subdomain | Domain | Service |
|-----------|--------|---------|
| `argocd` | `helios.id.vn` | `http://argocd-server.argocd.svc.cluster.local:80` |

### 3.3 Đăng nhập ArgoCD CLI

Tunnel chưa hoạt động ở bước này (cloudflared chưa được deploy). Vì đang chạy kubectl **trực tiếp trên node k3s**, có thể kết nối thẳng vào ClusterIP — không cần port-forward:

```bash
ARGOCD_PASSWORD=$(kubectl get secret argocd-initial-admin-secret -n argocd \
    -o jsonpath='{.data.password}' | base64 -d)

ARGOCD_IP=$(kubectl get svc argocd-server -n argocd -o jsonpath='{.spec.clusterIP}')

argocd login $ARGOCD_IP:80 \
    --username admin \
    --password "$ARGOCD_PASSWORD" \
    --insecure --grpc-web

# Đổi mật khẩu ngay sau khi đăng nhập
argocd account update-password
```

### 3.4 Đăng ký repo

```bash
argocd repo add git@github.com:helios-ryuu/k3s-homelab.git \
    --ssh-private-key-path /tmp/argocd-deploy-key \
    --name k3s-homelab \
    --grpc-web
```

### 3.5 Apply root Application

```bash
kubectl apply -n argocd -f argocd-apps/root.yaml
```

Trao quyền quản lý toàn bộ apps cho ArgoCD. Từ đây ArgoCD tự động sync khi có thay đổi trong Git.

### 3.6 Sync cloudflared và đóng port-forward

Sync cloudflared qua port-forward trước, sau đó tunnel sẽ lên và các lệnh tiếp theo dùng được domain:

```bash
argocd app sync cloudflared --grpc-web
argocd app wait cloudflared --health --grpc-web
```

Kiểm tra tunnel đã sống: `curl -sf https://argocd.helios.id.vn/healthz`

---

## 4. First Sync

Apps có `automated.selfHeal: true` nên sẽ tự sync sau khi root được apply. Tuy nhiên lần đầu cần sync thủ công theo thứ tự — cloudflared phải lên trước để tunnel hoạt động cho các bước tiếp theo.

### 4.1 Thêm Cloudflare tunnel routes cho các dịch vụ còn lại

Sau khi cloudflared healthy, thêm routes trên **Cloudflare Dashboard**:

> Zero Trust → Networks → Tunnels → `k3s` → Public Hostname → Add

| Subdomain | Domain | Service |
|-----------|--------|---------|
| `grafana` | `helios.id.vn` | `http://monitoring-grafana.monitoring.svc.cluster.local:80` |
| `localstack` | `helios.id.vn` | `http://localstack.localstack.svc.cluster.local:4566` |
| `loki` | `helios.id.vn` | `http://loki.logging.svc.cluster.local:3100` |
| `headlamp` | `helios.id.vn` | `http://headlamp.kube-system.svc.cluster.local:80` |

### 4.2 Sync các app còn lại

```bash
# Logging — Loki + Alloy
argocd app sync logging --grpc-web
argocd app wait logging --health --grpc-web

# Monitoring — Prometheus + Grafana
argocd app sync monitoring --grpc-web
argocd app wait monitoring --health --grpc-web

# LocalStack
argocd app sync localstack --grpc-web
argocd app wait localstack --health --grpc-web

# Databases (thứ tự tùy ý)
argocd app sync oracle --grpc-web
argocd app sync mssql --grpc-web

# BigData
argocd app sync bigdata --grpc-web

# Apps
argocd app sync headlamp --grpc-web
argocd app sync sure --grpc-web

# Xem trạng thái tất cả
argocd app list --grpc-web
```

> Nếu một app chưa xuất hiện: `argocd app sync root --grpc-web`
>
> Sau đây, push lên `main` là đủ — ArgoCD phát hiện và sync tự động.

---

## 5. CI/CD — GitHub Actions (NT118.Q22)

Thêm secret vào repo NT118.Q22 để GitHub Actions có thể cập nhật image tag trong repo này:

> github.com/helios-ryuu/NT118.Q22 → Settings → Secrets and variables → Actions → New repository secret

| Secret | Giá trị |
|--------|---------|
| `K3S_HOMELAB_PAT` | Fine-grained PAT với quyền **Contents: Read and Write** trên repo `k3s-homelab` |

Tạo PAT: GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens → chọn repo `k3s-homelab` → Contents: Read and Write.

---

## 6. Thêm node mới

### Điều kiện

1. Tailscale đã join cùng tailnet: `sudo tailscale up`
2. Node ping được master: `ping 100.102.51.39`
3. Cổng `6443` mở qua Tailscale

### Thêm Master

```bash
curl -sfL https://get.k3s.io | \
    K3S_URL=https://100.102.51.39:6443 \
    K3S_TOKEN=<TOKEN> \
    sh -s - server \
    --node-ip=<TAILSCALE_IP> \
    --advertise-address=<TAILSCALE_IP> \
    --flannel-iface=tailscale0 \
    --write-kubeconfig-mode 644 \
    --tls-san=<TAILSCALE_IP>
```

### Thêm Worker

```bash
curl -sfL https://get.k3s.io | \
    K3S_URL=https://100.102.51.39:6443 \
    K3S_TOKEN=<TOKEN> \
    sh -s - agent \
    --node-ip=<TAILSCALE_IP> \
    --flannel-iface=tailscale0
```

### Sau khi join

```bash
kubectl get nodes
kubectl label node <hostname> <labels...>   # Gán labels phù hợp (xem mục 1.5)
```
