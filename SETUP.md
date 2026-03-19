# K3S Homelab — Setup Guide

## 0. Prerequisites

Cài đặt các công cụ sau trên máy quản lý trước khi bắt đầu:

| Tool | Phiên bản | Cài đặt |
|------|-----------|---------|
| `kubectl` | ≥ 1.30 | `curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && chmod +x kubectl && sudo mv kubectl /usr/local/bin/` |
| `helm` | ≥ 3.14 | `curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \| bash` |
| `kubeseal` | ≥ 0.36 | `KUBESEAL_VER=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest \| grep tag_name \| cut -d '"' -f4 \| sed 's/v//') && curl -sL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VER}/kubeseal-${KUBESEAL_VER}-linux-amd64.tar.gz" \| tar xz && sudo install -m 755 kubeseal /usr/local/bin/kubeseal` |
| `tailscale` | latest | `curl -fsSL https://tailscale.com/install.sh \| sh` |
| `git` | any | package manager |
| `base64`, `od` | (coreutils) | pre-installed trên hầu hết Linux |

### Helm repos (cài một lần)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add localstack https://helm.localstack.cloud
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
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

```bash
# master-1 (helios-imac-ubuntu) — monitoring, logging, localstack, bigdata-master, sure
kubectl label node helios-imac-ubuntu \
    node-role.kubernetes.io/monitoring=true \
    node-role.kubernetes.io/logging=true \
    node-role.kubernetes.io/localstack=true \
    node-role.kubernetes.io/bigdata-master=true \
    app-host=sure

# master-3 (helios) — bigdata-worker, oracle
kubectl label node helios \
    node-role.kubernetes.io/bigdata-worker=true \
    node-role.kubernetes.io/database-oracle=true

# worker-2 (sinister) — bigdata-worker, oracle
kubectl label node sinister \
    node-role.kubernetes.io/bigdata-worker=true \
    node-role.kubernetes.io/database-oracle=true
```

> **Kiểm tra:** `kubectl get nodes --show-labels`

---

## 2. Secrets (`.env`)

Secrets được quản lý qua **Sealed Secrets** (Bitnami) — encrypted YAML committed vào git, ArgoCD tự decrypt. File `.env` là nguồn gốc để tạo sealed secrets, **không được commit**.

### 2.1 Tạo `.env`

```bash
cat > .env << 'EOF'
# Cloudflare Tunnel
CLOUDFLARE_TOKEN=<tunnel-token-từ-cloudflare-dashboard>

# LocalStack Pro
LOCALSTACK_TOKEN=<localstack-pro-license-key>

# Grafana
GRAFANA_ADMIN_PASSWORD=<mật-khẩu-grafana>

# Oracle
ORACLE_PASSWORD=<mật-khẩu-sys-oracle>

# Sure Finance
SURE_POSTGRES_PASSWORD=<mật-khẩu-postgres-sure>

# RedShark API (LocalStack PostgreSQL)
REDSHARK_DB_USERNAME=<db-username-redshark>
REDSHARK_DB_PASSWORD=<db-password-redshark>
EOF

# Tạo và lưu sure-secret-key-base ngay vào .env (phải ổn định qua mọi lần rebuild)
echo "SURE_SECRET_KEY_BASE=$(head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n')" >> .env
```

### 2.2 Tham chiếu key mapping

**`infra-secrets`** — trong các namespace: `cloudflared`, `localstack`, `monitoring`, `oracle`, `sure`, `kube-system`

| Key | Từ `.env` | Dùng bởi |
|-----|-----------|----------|
| `cloudflare-token` | `CLOUDFLARE_TOKEN` | cloudflared |
| `localstack-token` | `LOCALSTACK_TOKEN` | localstack |
| `grafana-admin-password` | `GRAFANA_ADMIN_PASSWORD` | monitoring |
| `admin-user` / `admin-password` | hardcoded `admin` / `GRAFANA_ADMIN_PASSWORD` | monitoring (existingSecret) |
| `oracle-password` | `ORACLE_PASSWORD` | oracle |
| `sure-postgres-password` | `SURE_POSTGRES_PASSWORD` | sure |
| `sure-secret-key-base` | `SURE_SECRET_KEY_BASE` | sure (Rails, tạo một lần trong `.env`) |

**`redshark-secrets`** — chỉ trong namespace `redshark`

| Key | Từ `.env` | Dùng bởi |
|-----|-----------|----------|
| `db-username` | `REDSHARK_DB_USERNAME` | redshark API |
| `db-password` | `REDSHARK_DB_PASSWORD` | redshark API |

> **Generate sealed secrets** được thực hiện ở **bước 3.6**, sau khi Sealed Secrets controller đã chạy.

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

### 3.3 Đăng nhập ArgoCD (trong pod)

`argocd-server` pod đã có CLI built-in — exec vào pod thay vì cài binary local.

```bash
ARGOCD_PASSWORD=$(kubectl get secret argocd-initial-admin-secret -n argocd \
    -o jsonpath='{.data.password}' | base64 -d)

# Login một lần — session lưu trong pod filesystem, dùng được cho mọi lệnh argocd sau
kubectl exec -n argocd deployment/argocd-server -- \
    argocd login localhost:8080 \
    --username admin \
    --password "$ARGOCD_PASSWORD" \
    --plaintext

# Helper cho các bước sau
acd() { kubectl exec -n argocd deployment/argocd-server -- argocd "$@"; }

# Kiểm tra kết nối
acd app list
```

> Nếu pod restart: chạy lại 2 lệnh login + `acd()` ở trên.
> Đổi mật khẩu qua UI (`https://argocd.helios.id.vn`) sau khi cloudflared lên.

### 3.4 Đăng ký repo

```bash
# ArgoCD tự nhận repo từ K8s Secret có label này (không cần argocd repo add)
kubectl create secret generic argocd-repo-k3s-homelab \
    -n argocd \
    --from-literal=type=git \
    --from-literal=url=git@github.com:helios-ryuu/k3s-homelab.git \
    --from-file=sshPrivateKey=/tmp/argocd-deploy-key

kubectl label secret argocd-repo-k3s-homelab \
    -n argocd argocd.argoproj.io/secret-type=repository

rm /tmp/argocd-deploy-key  # xóa private key sau khi nạp vào K8s
```

> Helm repos (headlamp, sealed-secrets) không cần đăng ký — ArgoCD v2+ tự fetch từ `repoURL` trong Application manifest.

### 3.5 Apply root Application

```bash
kubectl apply -n argocd -f argocd-apps/root.yaml
```

Trao quyền quản lý toàn bộ apps cho ArgoCD. ArgoCD sync theo thứ tự wave:
- **Wave -2**: `sealed-secrets` controller → `kube-system`
- **Wave -1**: `secrets` (SealedSecret objects) → decrypt thành K8s Secrets
- **Wave 0**: tất cả apps còn lại

### 3.6 Generate và commit Sealed Secrets

Đợi sealed-secrets controller sẵn sàng:

```bash
# Đợi sealed-secrets controller lên (auto-sync wave -2 tự trigger)
kubectl rollout status deployment sealed-secrets-controller -n kube-system --timeout=180s
```

Load `.env` và generate SealedSecret files:

```bash
source .env

# infra-secrets — 7 namespaces
for NS in cloudflared localstack monitoring oracle sure kube-system; do
    kubectl create secret generic infra-secrets \
        --from-literal=cloudflare-token="$CLOUDFLARE_TOKEN" \
        --from-literal=localstack-token="$LOCALSTACK_TOKEN" \
        --from-literal=grafana-admin-password="$GRAFANA_ADMIN_PASSWORD" \
        --from-literal=admin-user="admin" \
        --from-literal=admin-password="$GRAFANA_ADMIN_PASSWORD" \
        --from-literal=oracle-password="$ORACLE_PASSWORD" \
        --from-literal=sure-secret-key-base="$SURE_SECRET_KEY_BASE" \
        --from-literal=sure-postgres-password="$SURE_POSTGRES_PASSWORD" \
        -n "$NS" --dry-run=client -o yaml \
    | kubeseal \
        --controller-name=sealed-secrets-controller \
        --controller-namespace=kube-system \
        --format yaml --namespace "$NS" \
    > "secrets/infra-secrets-${NS}.yaml"
done

# redshark-secrets
kubectl create secret generic redshark-secrets \
    --from-literal=db-username="$REDSHARK_DB_USERNAME" \
    --from-literal=db-password="$REDSHARK_DB_PASSWORD" \
    -n redshark --dry-run=client -o yaml \
| kubeseal \
    --controller-name=sealed-secrets-controller \
    --controller-namespace=kube-system \
    --format yaml --namespace redshark \
> secrets/redshark-secrets-redshark.yaml
```

Commit và push:

```bash
git add secrets/
git commit -m "secrets: add sealed secrets"
git push
```

ArgoCD tự sync app `secrets` → controller decrypt → K8s Secrets tồn tại trong từng namespace. Kiểm tra:

```bash
kubectl get sealedsecret -A
kubectl get secret infra-secrets -n monitoring
kubectl get secret redshark-secrets -n redshark
```

**Backup controller key ngay** (cần để rebuild cluster mà không re-seal):

```bash
kubectl get secret -n kube-system \
    -l sealedsecrets.bitnami.com/sealed-secrets-key \
    -o yaml > sealed-secrets-key-backup.yaml
# Lưu cùng với .env — KHÔNG commit lên git
```

### 3.7 Sync cloudflared

Sync cloudflared để tunnel lên, các lệnh tiếp theo dùng được domain:

```bash
acd app sync cloudflared
acd app wait cloudflared --health
```

Kiểm tra tunnel đã sống: `curl -sf https://argocd.helios.id.vn/healthz`

### 3.8 Cập nhật secrets

Khi cần thay đổi giá trị (ví dụ rotate token):

```bash
vi .env   # Sửa giá trị cần thay
source .env

# Re-seal namespace cụ thể, ví dụ cloudflared:
kubectl create secret generic infra-secrets \
    --from-literal=cloudflare-token="$CLOUDFLARE_TOKEN" \
    --from-literal=localstack-token="$LOCALSTACK_TOKEN" \
    --from-literal=grafana-admin-password="$GRAFANA_ADMIN_PASSWORD" \
    --from-literal=admin-user="admin" \
    --from-literal=admin-password="$GRAFANA_ADMIN_PASSWORD" \
    --from-literal=oracle-password="$ORACLE_PASSWORD" \
    --from-literal=sure-secret-key-base="$SURE_SECRET_KEY_BASE" \
    --from-literal=sure-postgres-password="$SURE_POSTGRES_PASSWORD" \
    -n cloudflared --dry-run=client -o yaml \
| kubeseal \
    --controller-name=sealed-secrets-controller \
    --controller-namespace=kube-system \
    --format yaml --namespace cloudflared \
> secrets/infra-secrets-cloudflared.yaml

git add secrets/ && git commit -m "secrets: rotate <key-name>" && git push
# ArgoCD sync tự động — pods restart nếu cần
```

### 3.9 Rebuild cluster (restore sealed secrets)

Khi rebuild từ đầu mà đã có `sealed-secrets-key-backup.yaml`:

```bash
# 1. Restore controller key TRƯỚC khi apply ArgoCD
kubectl create namespace kube-system 2>/dev/null || true
kubectl apply -f sealed-secrets-key-backup.yaml

# 2. Tiếp tục bootstrap bình thường từ bước 3.1
# Controller sẽ tìm key cũ — không cần chạy lại kubeseal
```

> Nếu mất `sealed-secrets-key-backup.yaml`: chạy lại toàn bộ bước 3.6 để re-seal từ `.env`.

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
# Nếu pod bị restart hoặc mở terminal mới, login lại:
ARGOCD_PASSWORD=$(kubectl get secret argocd-initial-admin-secret -n argocd \
    -o jsonpath='{.data.password}' | base64 -d)
kubectl exec -n argocd deployment/argocd-server -- \
    argocd login localhost:8080 --username admin --password "$ARGOCD_PASSWORD" --plaintext
acd() { kubectl exec -n argocd deployment/argocd-server -- argocd "$@"; }

# Logging — Loki + Alloy
acd app sync logging  && acd app wait logging  --health

# Monitoring — Prometheus + Grafana
acd app sync monitoring && acd app wait monitoring --health

# LocalStack
acd app sync localstack && acd app wait localstack --health

# Database
acd app sync oracle

# BigData
acd app sync bigdata

# Apps
acd app sync headlamp
acd app sync sure

# Xem trạng thái tất cả
acd app list
```

> Nếu một app chưa xuất hiện: `acd app sync root`
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
