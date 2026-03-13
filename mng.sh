#!/bin/bash
# =================================================================
# mng.sh — Quản lý toàn bộ Helm charts + manifests trên K3s
# =================================================================
# Sử dụng:
#   bash ./mng.sh deploy   [bigdata|oracle|mssql|localstack|logging|monitoring|cloudflared|sure|all]
#   bash ./mng.sh delete   [bigdata|oracle|mssql|localstack|logging|monitoring|cloudflared|sure|all]
#   bash ./mng.sh redeploy [bigdata|oracle|mssql|localstack|logging|monitoring|cloudflared|sure|all]
#   bash ./mng.sh scale    [bigdata|oracle|mssql] [1|2]
#   bash ./mng.sh status
#   bash ./mng.sh logs     [bigdata|oracle|mssql|localstack|logging|monitoring|cloudflared|sure|alloy]
#   bash ./mng.sh health
#   bash ./mng.sh nuke     ← Xóa TOÀN BỘ (PVC + namespace)
# =================================================================
# deploy   = helm install (lần đầu) hoặc helm upgrade (đã tồn tại)
# delete   = force xóa toàn bộ (pods, PVC, CRDs, namespace)
# redeploy = force delete + deploy lại sạch
# logs     = tail logs pod chính của target
# health   = kiểm tra endpoint + node readiness + log ingestion
# =================================================================
# Worker nodes CÓ THỂ offline bất kỳ lúc nào.
# Script KHÔNG block chờ đợi — chỉ hiển thị trạng thái hiện tại.
# Pod trên node offline sẽ ở trạng thái Pending — đó là bình thường.
# =================================================================

K3S_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORCE="--force --grace-period=0 --ignore-not-found"
HELM_TIMEOUT="--timeout 2m --wait=false"

# ======================== COLORS ========================

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BLUE}>>> $*${NC}"; }
ok()    { echo -e "${GREEN}    ✔ $*${NC}"; }
warn()  { echo -e "${YELLOW}    ⚠ $*${NC}"; }
err()   { echo -e "${RED}    ✘ $*${NC}"; }

# ======================== HELPERS ========================

# Force xóa tất cả pods trong namespace (kể cả trên node offline)
force_cleanup_ns() {
    local ns="$1"
    warn "Force xóa pods trong $ns..."
    kubectl delete pods -n "$ns" --all $FORCE 2>/dev/null
    warn "Xóa PVC..."
    kubectl delete pvc -n "$ns" --all $FORCE 2>/dev/null
    warn "Xóa namespace..."
    kubectl delete ns "$ns" $FORCE 2>/dev/null
}

# Kiểm tra release đã tồn tại chưa
release_exists() {
    helm status "$1" -n "$2" &>/dev/null
}

# Hiển thị trạng thái pods sau deploy (NON-BLOCKING)
# Worker nodes có thể offline → pod Pending là bình thường
wait_for_ready() {
    local ns="$1"
    sleep 3

    info "Trạng thái pods trong $ns:"

    local running=0 pending=0 crash=0 other=0
    while read -r line; do
        [ -z "$line" ] && continue
        local name ready status
        name=$(echo "$line" | awk '{print $1}')
        ready=$(echo "$line" | awk '{print $2}')
        status=$(echo "$line" | awk '{print $3}')

        if [ "$status" = "Running" ]; then
            echo -e "      ${GREEN}✔${NC} $name  ${GREEN}$ready${NC}  $status"
            ((running++))
        elif [ "$status" = "Succeeded" ] || [ "$status" = "Completed" ]; then
            echo -e "      ${BLUE}✔${NC} $name  $ready  $status"
        elif [ "$status" = "Pending" ]; then
            echo -e "      ${YELLOW}…${NC} $name  $ready  ${YELLOW}$status${NC}  (node có thể offline)"
            ((pending++))
        elif echo "$status" | grep -q "CrashLoop\|Error\|Failed"; then
            echo -e "      ${RED}✘${NC} $name  $ready  ${RED}$status${NC}"
            ((crash++))
        else
            echo -e "      ${YELLOW}…${NC} $name  $ready  ${YELLOW}$status${NC}"
            ((other++))
        fi
    done < <(kubectl get pods -n "$ns" --no-headers 2>/dev/null)

    # Tóm tắt
    echo -ne "    → "
    [ "$running" -gt 0 ] && echo -ne "${GREEN}$running Running${NC}  "
    [ "$pending" -gt 0 ] && echo -ne "${YELLOW}$pending Pending${NC}  "
    [ "$crash" -gt 0 ]   && echo -ne "${RED}$crash CrashLoop${NC}  "
    [ "$other" -gt 0 ]   && echo -ne "${CYAN}$other Other${NC}  "
    echo ""
}

# ======================== IMAGE PRE-CHECK ========================

# Kiểm tra image có sẵn trên node (cho imagePullPolicy: Never)
# Usage: check_image_on_nodes <image> <node1> [node2] ...
check_image_on_nodes() {
    local image="$1"; shift
    local nodes=("$@")
    local all_ok=true

    info "Kiểm tra image '$image' trên các nodes..."
    for node in "${nodes[@]}"; do
        # Kiểm tra node có Ready không
        local node_status
        node_status=$(kubectl get node "$node" --no-headers 2>/dev/null | awk '{print $2}')
        if [ "$node_status" != "Ready" ]; then
            warn "$node: node $node_status (bỏ qua kiểm tra image)"
            continue
        fi

        # Tìm image trong danh sách images của node
        local found
        found=$(kubectl get node "$node" -o jsonpath='{.status.images[*].names[*]}' 2>/dev/null | tr ' ' '\n' | grep -F "$image")
        if [ -n "$found" ]; then
            ok "$node: image sẵn sàng"
        else
            err "$node: THIẾU image '$image'"
            echo -e "      ${CYAN}Gợi ý: Trên node $node chạy:${NC}"
            echo "        sudo ctr -n k8s.io images import <file>.tar"
            echo "        # hoặc: docker load -i <file>.tar"
            all_ok=false
        fi
    done

    if [ "$all_ok" = false ]; then
        err "Một hoặc nhiều node thiếu image. Deploy sẽ thất bại (imagePullPolicy: Never)."
        echo -e "      ${YELLOW}Tiếp tục deploy? Pod trên node thiếu image sẽ ErrImageNeverPull.${NC}"
        read -p "      Tiếp tục? (y/N): " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            warn "Hủy deploy."
            return 1
        fi
    fi
    return 0
}

# ======================== DEPLOY (install hoặc upgrade) ========================

deploy_bigdata() {
    info "Deploy BigData (Hadoop + Spark) → namespace: bigdata"
    if release_exists bigd bigdata; then
        ok "(Upgrade existing release)"
        helm upgrade bigd "$K3S_DIR/bigdata" -n bigdata $HELM_TIMEOUT
    else
        helm install bigd "$K3S_DIR/bigdata" -n bigdata --create-namespace $HELM_TIMEOUT
    fi
    wait_for_ready bigdata
}

deploy_oracle() {
    info "Deploy Oracle → namespace: oracle"
    # Pre-check: image oracle-database-19c:latest phải có sẵn (imagePullPolicy: Never)
    local oracle_image
    oracle_image=$(grep 'image:' "$K3S_DIR/oracle/values.yaml" | head -1 | awk '{print $2}')
    local oracle_nodes
    oracle_nodes=($(grep -A10 'targetNodes:' "$K3S_DIR/oracle/values.yaml" | grep '^ *-' | awk '{print $2}'))
    check_image_on_nodes "$oracle_image" "${oracle_nodes[@]}" || return 1

    if release_exists ora oracle; then
        ok "(Upgrade existing release)"
        helm upgrade ora "$K3S_DIR/oracle" -n oracle $HELM_TIMEOUT
    else
        helm install ora "$K3S_DIR/oracle" -n oracle --create-namespace $HELM_TIMEOUT
    fi
    wait_for_ready oracle
}

deploy_mssql() {
    info "Deploy MSSQL → namespace: mssql"
    if release_exists mssql mssql; then
        ok "(Upgrade existing release)"
        helm upgrade mssql "$K3S_DIR/mssql" -n mssql $HELM_TIMEOUT
    else
        helm install mssql "$K3S_DIR/mssql" -n mssql --create-namespace $HELM_TIMEOUT
    fi
    wait_for_ready mssql
}

deploy_localstack() {
    info "Deploy LocalStack Pro → namespace: localstack"

    # --- Pre-check: xác nhận localstack-pro image tồn tại trên Docker Hub ---
    local ls_image
    ls_image=$(grep 'repository:' "$K3S_DIR/localstack/values.yaml" | head -1 | awk '{print $2}')
    local ls_tag
    ls_tag=$(grep '  tag:' "$K3S_DIR/localstack/values.yaml" | head -1 | awk '{print $2}' | tr -d '"')
    info "Kiểm tra image ${ls_image}:${ls_tag} trên registry..."
    if docker manifest inspect "${ls_image}:${ls_tag}" &>/dev/null; then
        ok "Image ${ls_image}:${ls_tag} tồn tại (pullPolicy: Always → sẽ pull khi deploy)"
    else
        err "Image ${ls_image}:${ls_tag} KHÔNG tồn tại hoặc không truy cập được registry"
        echo -e "      ${CYAN}Kiểm tra thủ công: docker manifest inspect ${ls_image}:${ls_tag}${NC}"
        read -p "      Tiếp tục deploy? (y/N): " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            warn "Hủy deploy LocalStack."
            return 1
        fi
    fi

    # --- Pre-check: node localstack/master phải Ready ---
    local target_node
    target_node=$(kubectl get nodes -l node-role.kubernetes.io/localstack -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "$target_node" ]; then
        target_node=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    fi

    if [ -z "$target_node" ]; then
        err "Không tìm thấy node phù hợp (localstack role hoặc control-plane)."
        return 1
    fi

    local node_status
    node_status=$(kubectl get node "$target_node" --no-headers 2>/dev/null | awk '{print $2}')
    if [ "$node_status" != "Ready" ]; then
        warn "Node $target_node không Ready (status: ${node_status:-NotFound})"
        warn "LocalStack pin trên $target_node — pod sẽ Pending cho đến khi node online"
        read -p "      Tiếp tục? (y/N): " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            warn "Hủy deploy LocalStack."
            return 1
        fi
    else
        ok "Node $target_node: Ready"
    fi

    if release_exists localstack localstack; then
        ok "(Upgrade existing release)"
        helm upgrade localstack localstack/localstack \
            -f "$K3S_DIR/localstack/values.yaml" -n localstack $HELM_TIMEOUT
    else
        helm install localstack localstack/localstack \
            -f "$K3S_DIR/localstack/values.yaml" \
            -n localstack --create-namespace $HELM_TIMEOUT
    fi
    wait_for_ready localstack
    local ls_node_ip
    ls_node_ip=$(kubectl get nodes -l node-role.kubernetes.io/localstack -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || \
                 kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || \
                 echo "127.0.0.1")
    ok "LocalStack API (ngoài):  http://${ls_node_ip}:30566"
    ok "LocalStack API (cluster): http://localstack.localstack.svc.cluster.local:4566"
}

deploy_logging() {
    info "Deploy Logging (Loki + Alloy) → namespace: logging"
    if release_exists log logging; then
        ok "(Upgrade existing release)"
        helm upgrade log "$K3S_DIR/logging" -n logging $HELM_TIMEOUT
    else
        helm install log "$K3S_DIR/logging" -n logging --create-namespace $HELM_TIMEOUT
    fi
    wait_for_ready logging
}

deploy_monitoring() {
    info "Deploy Monitoring (Prometheus + Grafana) → namespace: monitoring"
    if release_exists mon monitoring; then
        ok "(Upgrade existing release)"
        helm upgrade mon prometheus-community/kube-prometheus-stack \
            -f "$K3S_DIR/monitoring/values.yaml" -n monitoring $HELM_TIMEOUT
    else
        helm install mon prometheus-community/kube-prometheus-stack \
            -f "$K3S_DIR/monitoring/values.yaml" \
            -n monitoring --create-namespace $HELM_TIMEOUT
    fi
    wait_for_ready monitoring
}

deploy_cloudflared() {
    info "Deploy Cloudflare Tunnel → namespace: cloudflared"
    if release_exists cfd cloudflared; then
        ok "(Upgrade existing release)"
        helm upgrade cfd "$K3S_DIR/cloudflared" -n cloudflared $HELM_TIMEOUT
    else
        helm install cfd "$K3S_DIR/cloudflared" -n cloudflared --create-namespace $HELM_TIMEOUT
    fi
    wait_for_ready cloudflared
}

deploy_sure() {
    info "Deploy Sure (Web + Worker + Postgres + Redis) → namespace: sure"

    # Pre-check: namespace + secret phải tồn tại
    if ! kubectl get ns sure &>/dev/null; then
        warn "Namespace 'sure' chưa tồn tại, đang tạo..."
        kubectl create namespace sure
    fi
    if ! kubectl get secret infra-secrets -n sure &>/dev/null; then
        err "Secret 'infra-secrets' chưa tồn tại trong namespace 'sure'."
        echo -e "      ${CYAN}Tạo secret trước:${NC}"
        echo "        kubectl create secret generic infra-secrets \\"
        echo "          --from-literal=sure-secret-key-base='<key>' \\"
        echo "          --from-literal=sure-postgres-password='<pass>' \\"
        echo "          -n sure"
        return 1
    fi

    # Pre-check: node có label app-host=sure phải Ready
    local target_node
    target_node=$(kubectl get nodes -l app-host=sure -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "$target_node" ]; then
        err "Không tìm thấy node nào có label 'app-host=sure'."
        echo -e "      ${CYAN}Gán label: kubectl label node <node-name> app-host=sure${NC}"
        return 1
    fi

    local node_status
    node_status=$(kubectl get node "$target_node" --no-headers 2>/dev/null | awk '{print $2}')
    if [ "$node_status" != "Ready" ]; then
        warn "Node $target_node không Ready (status: ${node_status:-NotFound})"
        warn "Sure pin trên $target_node — pods sẽ Pending cho đến khi node online"
        read -p "      Tiếp tục? (y/N): " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            warn "Hủy deploy Sure."
            return 1
        fi
    else
        ok "Node $target_node: Ready"
    fi

    kubectl apply -f "$K3S_DIR/sure/sure-stack.yaml"
    wait_for_ready sure

    local sure_ip
    sure_ip=$(kubectl get node "$target_node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "<node-ip>")
    ok "Sure Web: http://${sure_ip}:30300"
}

deploy_headlamp() {
    info "Deploy Headlamp (K8s Dashboard) → namespace: kube-system"
    if release_exists headlamp kube-system; then
        ok "(Upgrade existing release)"
        helm upgrade headlamp headlamp/headlamp -n kube-system \
            --set replicaCount=1 \
            --set config.inCluster=true \
            --set service.type=ClusterIP \
            --set service.port=80 \
            --set 'tolerations[0].key=node-role.kubernetes.io/control-plane' \
            --set 'tolerations[0].operator=Exists' \
            --set 'tolerations[0].effect=NoSchedule' \
            --set 'affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].weight=100' \
            --set 'affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].preference.matchExpressions[0].key=node-role.kubernetes.io/control-plane' \
            --set 'affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].preference.matchExpressions[0].operator=Exists' \
            --set resources.requests.memory=64Mi \
            --set resources.requests.cpu=50m \
            --set resources.limits.memory=128Mi \
            --set resources.limits.cpu=100m \
            $HELM_TIMEOUT
    else
        helm install headlamp headlamp/headlamp -n kube-system \
            --set replicaCount=1 \
            --set config.inCluster=true \
            --set service.type=ClusterIP \
            --set service.port=80 \
            --set 'tolerations[0].key=node-role.kubernetes.io/control-plane' \
            --set 'tolerations[0].operator=Exists' \
            --set 'tolerations[0].effect=NoSchedule' \
            --set 'affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].weight=100' \
            --set 'affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].preference.matchExpressions[0].key=node-role.kubernetes.io/control-plane' \
            --set 'affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].preference.matchExpressions[0].operator=Exists' \
            --set resources.requests.memory=64Mi \
            --set resources.requests.cpu=50m \
            --set resources.limits.memory=128Mi \
            --set resources.limits.cpu=100m \
            $HELM_TIMEOUT
        # RBAC: cluster-admin cho Headlamp ServiceAccount
        kubectl create clusterrolebinding headlamp-admin \
            --clusterrole=cluster-admin \
            --serviceaccount=kube-system:headlamp 2>/dev/null
        ok "ClusterRoleBinding headlamp-admin created"
    fi
    wait_for_ready kube-system
}

# ======================== DELETE (force) ========================

delete_bigdata() {
    info "Force xóa BigData..."
    helm uninstall bigd -n bigdata 2>/dev/null
    force_cleanup_ns bigdata
}

delete_oracle() {
    info "Force xóa Oracle..."
    helm uninstall ora -n oracle 2>/dev/null
    force_cleanup_ns oracle
}

delete_mssql() {
    info "Force xóa MSSQL..."
    helm uninstall mssql -n mssql 2>/dev/null
    force_cleanup_ns mssql
}

delete_localstack() {
    info "Force xóa LocalStack..."
    helm uninstall localstack -n localstack 2>/dev/null
    kubectl delete deployment localstack -n default $FORCE 2>/dev/null
    kubectl delete svc localstack -n default $FORCE 2>/dev/null
    force_cleanup_ns localstack
}

delete_logging() {
    info "Force xóa Logging..."
    helm uninstall log -n logging 2>/dev/null
    # Cleanup cluster-scoped resources
    kubectl delete clusterrole alloy $FORCE 2>/dev/null
    kubectl delete clusterrolebinding alloy $FORCE 2>/dev/null
    force_cleanup_ns logging
}

delete_monitoring() {
    info "Force xóa Monitoring..."
    helm uninstall mon -n monitoring --no-hooks 2>/dev/null
    # CRDs của prometheus-operator
    kubectl delete crd alertmanagerconfigs.monitoring.coreos.com \
        alertmanagers.monitoring.coreos.com \
        podmonitors.monitoring.coreos.com \
        probes.monitoring.coreos.com \
        prometheusagents.monitoring.coreos.com \
        prometheuses.monitoring.coreos.com \
        prometheusrules.monitoring.coreos.com \
        scrapeconfigs.monitoring.coreos.com \
        servicemonitors.monitoring.coreos.com \
        thanosrulers.monitoring.coreos.com $FORCE 2>/dev/null
    force_cleanup_ns monitoring
}

delete_cloudflared() {
    info "Force xóa Cloudflare Tunnel..."
    helm uninstall cfd -n cloudflared 2>/dev/null
    force_cleanup_ns cloudflared
}

delete_sure() {
    info "Force xóa Sure..."
    kubectl delete -f "$K3S_DIR/sure/sure-stack.yaml" $FORCE 2>/dev/null
    force_cleanup_ns sure
}

delete_headlamp() {
    info "Force xóa Headlamp..."
    helm uninstall headlamp -n kube-system 2>/dev/null
    kubectl delete clusterrolebinding headlamp-admin $FORCE 2>/dev/null
}

# ======================== SCALE ========================

scale_component() {
    local component="$1"
    local replicas="$2"

    case "$component" in
        bigdata)
            # Scale BigData: workers (StatefulSets) + masters (Deployments)
            # KHÔNG dùng helm upgrade → tránh thay đổi dfs.replication → namenode crash
            if [ "$replicas" -eq 0 ]; then
                # === SCALE TO 0: tắt workers trước, rồi tắt masters ===
                # Nếu chỉ tắt workers mà giữ masters → namenode crash restart loop
                info "Scale BigData → 0 (tắt toàn bộ workers + masters)"
                kubectl scale statefulset hadoop-datanode   -n bigdata --replicas=0
                kubectl scale statefulset hadoop-nodemanager -n bigdata --replicas=0
                kubectl scale statefulset spark-worker       -n bigdata --replicas=0
                # Đợi workers terminate xong rồi tắt masters
                kubectl wait --for=delete pod -l app=datanode    -n bigdata --timeout=60s 2>/dev/null || true
                kubectl wait --for=delete pod -l app=nodemanager -n bigdata --timeout=60s 2>/dev/null || true
                kubectl scale deploy hadoop-namenode         -n bigdata --replicas=0
                kubectl scale deploy hadoop-resourcemanager  -n bigdata --replicas=0
                kubectl scale deploy spark-master            -n bigdata --replicas=0
                info "BigData đã tắt hoàn toàn"
            else
                # === SCALE TO N: khôi phục masters trước, rồi workers ===
                info "Scale BigData workers → $replicas (khôi phục masters nếu cần)"
                # Đảm bảo masters chạy replicas=1 trước
                kubectl scale deploy hadoop-namenode         -n bigdata --replicas=1
                kubectl scale deploy hadoop-resourcemanager  -n bigdata --replicas=1
                kubectl scale deploy spark-master            -n bigdata --replicas=1
                # Đợi NameNode sẵn sàng trước khi scale workers
                info "Đợi NameNode sẵn sàng..."
                kubectl rollout status deploy/hadoop-namenode -n bigdata --timeout=120s 2>/dev/null || true
                # Scale workers
                kubectl scale statefulset hadoop-datanode   -n bigdata --replicas="$replicas"
                kubectl scale statefulset hadoop-nodemanager -n bigdata --replicas="$replicas"
                kubectl scale statefulset spark-worker       -n bigdata --replicas="$replicas"
                wait_for_ready bigdata
            fi
            ;;
        oracle)
            info "Scale Oracle → $replicas"
            helm upgrade ora "$K3S_DIR/oracle" -n oracle --set replicas="$replicas" $HELM_TIMEOUT
            wait_for_ready oracle
            ;;
        mssql)
            info "Scale MSSQL → $replicas"
            helm upgrade mssql "$K3S_DIR/mssql" -n mssql --set replicas="$replicas" $HELM_TIMEOUT
            wait_for_ready mssql
            ;;
        *)
            err "Không hỗ trợ scale cho '$component'"
            echo "    Chỉ hỗ trợ: bigdata, oracle, mssql"
            exit 1
            ;;
    esac
}

# ======================== STATUS ========================

show_status() {
    # Node overview
    echo -e "${YELLOW}=== NODES ===${NC}"
    kubectl get nodes --no-headers 2>/dev/null | while read -r line; do
        local name status role
        name=$(echo "$line" | awk '{print $1}')
        status=$(echo "$line" | awk '{print $2}')
        role=$(echo "$line" | awk '{print $3}')
        if [ "$status" = "Ready" ]; then
            echo -e "  ${GREEN}●${NC} $name  ${GREEN}Ready${NC}  $role"
        else
            echo -e "  ${RED}●${NC} $name  ${RED}$status${NC}  $role"
        fi
    done
    echo ""

    echo -e "${YELLOW}=== HELM RELEASES ===${NC}"
    helm list -A
    echo ""

    echo -e "${YELLOW}=== PODS (all namespaces, excluding kube-system) ===${NC}"
    kubectl get pods -A -o wide --field-selector=metadata.namespace!=kube-system 2>/dev/null | awk '
    NR==1{print "\033[1;33m" $0 "\033[0m"}
    NR>1{
        line=$0
        if ($4 ~ /Running/) sub("Running", "\033[0;32mRunning\033[0m", line)
        else if ($4 ~ /Pending/) sub("Pending", "\033[1;33mPending\033[0m", line)
        else if ($4 ~ /Completed|Succeeded/) sub($4, "\033[0;34m" $4 "\033[0m", line)
        else sub($4, "\033[0;31m" $4 "\033[0m", line)
        print line
    }'
    echo ""

    echo -e "${YELLOW}=== PVC (all namespaces) ===${NC}"
    kubectl get pvc -A 2>/dev/null
}

# ======================== LOGS ========================

show_logs() {
    local target="$1"
    case "$target" in
        bigdata)     kubectl logs -f -n bigdata -l app=namenode --tail=100 ;;
        oracle)      kubectl logs -f -n oracle -l app=oracle --tail=100 ;;
        mssql)       kubectl logs -f -n mssql -l app=mssql -c mssql-engine --tail=100 ;;
        localstack)  kubectl logs -f -n localstack -l app.kubernetes.io/name=localstack --tail=100 ;;
        logging)     kubectl logs -f -n logging -l app=loki --tail=100 ;;
        alloy)       kubectl logs -f -n logging -l app=alloy --tail=100 --max-log-requests=10 ;;
        monitoring)  kubectl logs -f -n monitoring -l app.kubernetes.io/name=grafana --tail=100 ;;
        cloudflared) kubectl logs -f -n cloudflared -l app=cloudflared --tail=100 ;;
        sure)        kubectl logs -f -n sure -l app=sure-web --tail=100 ;;
        sure-worker) kubectl logs -f -n sure -l app=sure-worker --tail=100 ;;
        *)
            err "Target không hợp lệ cho logs: $target"
            echo "    Targets: bigdata, oracle, mssql, localstack, logging, alloy, monitoring, cloudflared, sure, sure-worker"
            exit 1
            ;;
    esac
}

# ======================== HEALTH ========================

check_health() {
    # --- Node readiness ---
    info "Node Readiness"
    kubectl get nodes --no-headers 2>/dev/null | while read -r line; do
        local name status role
        name=$(echo "$line" | awk '{print $1}')
        status=$(echo "$line" | awk '{print $2}')
        role=$(echo "$line" | awk '{print $3}')
        if [ "$status" = "Ready" ]; then
            ok "$name ($role) — Ready"
        else
            err "$name ($role) — $status"
        fi
    done
    echo ""

    # --- Service endpoints ---
    info "Service Endpoints"
    echo ""

    # Dynamic MASTER_IP resolution
    local MASTER_IP
    MASTER_IP=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || \
                kubectl get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || \
                echo "127.0.0.1")

    # Prometheus
    echo -ne "  ${CYAN}Prometheus${NC} (http://$MASTER_IP:30090)  → "
    if curl -sf --max-time 5 "http://$MASTER_IP:30090/api/v1/status/runtimeinfo" >/dev/null 2>&1; then
        echo -e "${GREEN}UP${NC}"
    else
        echo -e "${RED}DOWN${NC}"
    fi

    # Grafana
    echo -ne "  ${CYAN}Grafana${NC}    (http://$MASTER_IP:30300)  → "
    if curl -sf --max-time 5 "http://$MASTER_IP:30300/api/health" >/dev/null 2>&1; then
        echo -e "${GREEN}UP${NC}"
    else
        echo -e "${RED}DOWN${NC}"
    fi

    # Loki
    echo -ne "  ${CYAN}Loki${NC}       (http://$MASTER_IP:30100)  → "
    if curl -sf --max-time 5 "http://$MASTER_IP:30100/ready" >/dev/null 2>&1; then
        echo -e "${GREEN}UP${NC}"
    else
        echo -e "${RED}DOWN${NC}"
    fi

    echo ""

    # --- Log ingestion check ---
    info "Log Ingestion (Loki labels)"
    local labels
    labels=$(curl -sf --max-time 5 "http://$MASTER_IP:30100/loki/api/v1/labels" 2>/dev/null)
    if [ -n "$labels" ]; then
        local label_list
        label_list=$(echo "$labels" | grep -oP '"data":\[\K[^\]]+' | tr ',' '\n' | tr -d '"' | head -5)
        if [ -n "$label_list" ] && [ "$label_list" != "" ]; then
            ok "Labels found: $(echo "$label_list" | tr '\n' ', ' | sed 's/,$//')"
        else
            warn "Loki is up but no labels found — Alloy may not be shipping logs"
        fi
    else
        err "Cannot reach Loki labels endpoint"
    fi

    echo ""

    # --- Alert rules status ---
    info "PrometheusRule Alerts"
    local firing
    firing=$(curl -sf --max-time 5 "http://$MASTER_IP:30090/api/v1/alerts" 2>/dev/null | \
        grep -o '"state":"firing"' | wc -l)
    if [ "$firing" -gt 0 ] 2>/dev/null; then
        warn "$firing alert(s) currently FIRING"
    else
        ok "No alerts firing"
    fi

    echo ""

    # --- Alloy DaemonSet status ---
    info "Alloy (log collector) DaemonSet"
    local ds_status
    ds_status=$(kubectl get ds alloy -n logging --no-headers 2>/dev/null)
    if [ -n "$ds_status" ]; then
        local desired ready
        desired=$(echo "$ds_status" | awk '{print $2}')
        ready=$(echo "$ds_status" | awk '{print $4}')
        if [ "$desired" = "$ready" ]; then
            ok "Alloy: $ready/$desired nodes ready"
        else
            warn "Alloy: $ready/$desired nodes ready (some nodes may be offline)"
        fi
    else
        err "Alloy DaemonSet not found in namespace logging"
    fi

    echo ""

    # --- Fault tolerance summary ---
    info "Fault Tolerance (oracle, mssql, bigdata, sure)"
    for ns in oracle mssql bigdata sure; do
        local total running pending
        total=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l)
        running=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -c "Running")
        pending=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -c "Pending")
        if [ "$total" -eq 0 ]; then
            echo -e "  ${CYAN}$ns${NC} — not deployed"
        elif [ "$pending" -gt 0 ]; then
            warn "$ns: $running/$total Running, $pending Pending (node offline)"
        else
            ok "$ns: $running/$total Running"
        fi
    done
}

# ======================== MAIN ========================

ACTION="${1:-}"
TARGET="${2:-all}"
REPLICAS="${3:-}"

case "$ACTION" in
    deploy)
        case "$TARGET" in
            bigdata)     deploy_bigdata ;;
            oracle)      deploy_oracle ;;
            mssql)       deploy_mssql ;;
            localstack)  deploy_localstack ;;
            logging)     deploy_logging ;;
            monitoring)  deploy_monitoring ;;
            cloudflared) deploy_cloudflared ;;
            headlamp)    deploy_headlamp ;;
            sure)        deploy_sure ;;
            all)
                # Logging trước monitoring (Grafana cần Loki data source)
                deploy_logging
                deploy_monitoring
                deploy_bigdata
                info "Đợi 30s cho Hadoop khởi động..."
                sleep 30
                deploy_oracle
                deploy_mssql
                deploy_localstack
                deploy_cloudflared
                deploy_sure
                ;;
            *) err "Target không hợp lệ: $TARGET" && exit 1 ;;
        esac
        ;;

    delete)
        case "$TARGET" in
            bigdata)     delete_bigdata ;;
            oracle)      delete_oracle ;;
            mssql)       delete_mssql ;;
            localstack)  delete_localstack ;;
            logging)     delete_logging ;;
            monitoring)  delete_monitoring ;;
            cloudflared) delete_cloudflared ;;
            headlamp)    delete_headlamp ;;
            sure)        delete_sure ;;
            all)
                delete_cloudflared
                delete_headlamp
                delete_sure
                delete_bigdata
                delete_oracle
                delete_mssql
                delete_localstack
                delete_monitoring
                delete_logging
                ;;
            *) err "Target không hợp lệ: $TARGET" && exit 1 ;;
        esac
        ;;

    redeploy)
        case "$TARGET" in
            bigdata)     delete_bigdata;     sleep 5; deploy_bigdata ;;
            oracle)      delete_oracle;      sleep 5; deploy_oracle ;;
            mssql)       delete_mssql;       sleep 5; deploy_mssql ;;
            localstack)  delete_localstack;  sleep 5; deploy_localstack ;;
            logging)     delete_logging;     sleep 5; deploy_logging ;;
            monitoring)  delete_monitoring;  sleep 5; deploy_monitoring ;;
            cloudflared) delete_cloudflared; sleep 5; deploy_cloudflared ;;
            headlamp)    delete_headlamp;    sleep 5; deploy_headlamp ;;
            sure)        delete_sure;        sleep 5; deploy_sure ;;
            all)
                delete_cloudflared; delete_sure; delete_bigdata; delete_oracle; delete_mssql
                delete_localstack; delete_monitoring; delete_logging
                sleep 5
                deploy_logging; deploy_monitoring
                deploy_bigdata; sleep 30
                deploy_oracle; deploy_mssql; deploy_localstack
                deploy_cloudflared; deploy_sure
                ;;
            *) err "Target không hợp lệ: $TARGET" && exit 1 ;;
        esac
        ;;

    scale)
        if [ -z "$REPLICAS" ]; then
            err "Thiếu số replicas"
            echo "    Cú pháp: $0 scale [bigdata|oracle|mssql] [1|2|3]"
            exit 1
        fi
        scale_component "$TARGET" "$REPLICAS"
        ;;

    status)
        show_status
        ;;

    logs)
        if [ "$TARGET" = "all" ]; then
            err "Cần chỉ định target cụ thể cho logs"
            echo "    Cú pháp: $0 logs [bigdata|oracle|mssql|localstack|logging|alloy|monitoring|cloudflared|sure|sure-worker]"
            exit 1
        fi
        show_logs "$TARGET"
        ;;

    health)
        check_health
        ;;

    nuke)
        echo -e "${RED}!!! CẢNH BÁO: Xóa TOÀN BỘ workloads (bao gồm PVC) !!!${NC}"
        read -p "Xác nhận? (y/N): " confirm
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            delete_cloudflared
            delete_headlamp
            delete_sure
            delete_bigdata
            delete_oracle
            delete_mssql
            delete_localstack
            delete_monitoring
            delete_logging
            echo ""
            ok "ĐÃ XÓA TOÀN BỘ!"
        else
            warn "Hủy."
        fi
        ;;

    *)
        echo -e "${YELLOW}==================================================================="
        echo -e "  K3s Helm Manager"
        echo -e "  BigData · Oracle · MSSQL · Logging · Monitoring · Cloudflared · Headlamp · Sure"
        echo -e "===================================================================${NC}"
        echo ""
        echo -e "Cú pháp: ${CYAN}$0 <action> [target] [replicas]${NC}"
        echo ""
        echo "Actions:"
        echo -e "  ${GREEN}deploy${NC}   [target|all]   Deploy (install lần đầu, upgrade nếu đã có)"
        echo -e "  ${RED}delete${NC}   [target|all]   Force xóa toàn bộ (pods, PVC, namespace)"
        echo -e "  ${YELLOW}redeploy${NC} [target|all]   Force delete + deploy lại sạch"
        echo -e "  ${BLUE}scale${NC}    [bigdata|oracle|mssql] [N]   Scale workers/replicas"
        echo -e "  ${CYAN}status${NC}                              Xem trạng thái"
        echo -e "  ${CYAN}logs${NC}     [target]                    Tail logs pod chính"
        echo -e "  ${CYAN}health${NC}                              Health check + fault tolerance"
        echo -e "  ${RED}nuke${NC}                                XÓA TẤT CẢ + PVC"
        echo ""
        echo "Targets: bigdata, oracle, mssql, localstack, logging, monitoring, cloudflared, headlamp, sure, all"
        echo "         (logs cũng hỗ trợ: alloy, sure-worker)"
        echo ""
        echo "Ví dụ:"
        echo "  $0 deploy logging          # Deploy Loki + Alloy"
        echo "  $0 deploy monitoring       # Prometheus + Grafana"
        echo "  $0 deploy sure             # Deploy Sure (Web + Worker + DB + Redis)"
        echo "  $0 deploy all              # Deploy toàn bộ stack"
        echo "  $0 scale bigdata 2         # Scale 2 workers (tự khôi phục masters)"
        echo "  $0 scale bigdata 0         # Tắt toàn bộ bigdata (masters + workers)"
        echo "  $0 logs alloy              # Tail Alloy logs (all nodes)"
        echo "  $0 logs sure               # Tail Sure web logs"
        echo "  $0 health                  # Check endpoints + fault tolerance"
        echo "  $0 redeploy logging        # Xóa sạch + deploy lại"
        echo "  $0 nuke                    # Xóa sạch mọi thứ"
        echo ""
        echo -e "${CYAN}Lưu ý: Worker nodes có thể offline.${NC}"
        echo -e "${CYAN}Pod trên node offline sẽ Pending — đó là bình thường.${NC}"
        ;;
esac
