/#!/bin/bash
# =================================================================
# k3s.sh — K3s Helm Manager (Orchestrator)
# =================================================================
# Sử dụng:
#   bash k3s.sh deploy   [target|all]   Deploy (install hoặc upgrade)
#   bash k3s.sh delete   [target|all]   Force xóa
#   bash k3s.sh redeploy [target|all]   Delete + Deploy lại sạch
#   bash k3s.sh status                  Xem trạng thái
#   bash k3s.sh health                  Health check + fault tolerance
#   bash k3s.sh nuke                    XÓA TẤT CẢ + PVC
# =================================================================
# Targets: bigdata, oracle, mssql, localstack, logging, monitoring,
#          cloudflared, headlamp, sure
# =================================================================
# Worker nodes CÓ THỂ offline bất kỳ lúc nào.
# Script KHÔNG block chờ đợi — chỉ hiển thị trạng thái hiện tại.
# =================================================================

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# ======================== DISPATCH ========================
# Chuyển tiếp lệnh tới component script tương ứng

dispatch() {
    local action="$1"
    local target="$2"
    local extra="$3"

    case "$target" in
        bigdata)     bash "$K3S_DIR/svc-scripts/bigdata.sh" "$action" $extra ;;
        oracle)      bash "$K3S_DIR/svc-scripts/oracle.sh" "$action" $extra ;;
        mssql)       bash "$K3S_DIR/svc-scripts/mssql.sh" "$action" $extra ;;
        localstack)  bash "$K3S_DIR/svc-scripts/localstack.sh" "$action" $extra ;;
        logging)     bash "$K3S_DIR/svc-scripts/logging.sh" "$action" $extra ;;
        monitoring)  bash "$K3S_DIR/svc-scripts/monitoring.sh" "$action" $extra ;;
        cloudflared) bash "$K3S_DIR/svc-scripts/cfd.sh" "$action" $extra ;;
        headlamp)    bash "$K3S_DIR/svc-scripts/headlamp.sh" "$action" $extra ;;
        sure)        bash "$K3S_DIR/svc-scripts/sure.sh" "$action" $extra ;;
        *)
            err "Target không hợp lệ: $target"
            echo "    Targets: bigdata, oracle, mssql, localstack, logging, monitoring, cloudflared, headlamp, sure"
            exit 1
            ;;
    esac
}

# ======================== DEPLOY ALL ========================

deploy_all() {
    # Logging trước monitoring (Grafana cần Loki data source)
    bash "$K3S_DIR/svc-scripts/logging.sh" deploy
    bash "$K3S_DIR/svc-scripts/monitoring.sh" deploy
    bash "$K3S_DIR/svc-scripts/bigdata.sh" deploy
    info "Đợi 30s cho Hadoop khởi động..."
    sleep 30
    bash "$K3S_DIR/svc-scripts/oracle.sh" deploy
    bash "$K3S_DIR/svc-scripts/mssql.sh" deploy
    bash "$K3S_DIR/svc-scripts/localstack.sh" deploy
    bash "$K3S_DIR/svc-scripts/cfd.sh" deploy
    bash "$K3S_DIR/svc-scripts/sure.sh" deploy
}

# ======================== DELETE ALL ========================

delete_all() {
    bash "$K3S_DIR/svc-scripts/cfd.sh" delete
    bash "$K3S_DIR/svc-scripts/headlamp.sh" delete
    bash "$K3S_DIR/svc-scripts/sure.sh" delete
    bash "$K3S_DIR/svc-scripts/bigdata.sh" delete
    bash "$K3S_DIR/svc-scripts/oracle.sh" delete
    bash "$K3S_DIR/svc-scripts/mssql.sh" delete
    bash "$K3S_DIR/svc-scripts/localstack.sh" delete
    bash "$K3S_DIR/svc-scripts/monitoring.sh" delete
    bash "$K3S_DIR/svc-scripts/logging.sh" delete
}

# ======================== REDEPLOY ALL ========================

redeploy_all() {
    delete_all
    sleep 5
    deploy_all
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

# ======================== HEALTH ========================

check_health() {
    local MASTER_IP=$(get_master_ip)

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
        label_list=$(echo "$labels" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('\n'.join(d.get('data',[])[:5]))
" 2>/dev/null)
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
    firing=$(curl -sf --max-time 5 "http://$MASTER_IP:30090/api/v1/alerts" 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(sum(1 for a in d.get('data',{}).get('alerts',[]) if a.get('state')=='firing'))
" 2>/dev/null)
    if [ "${firing:-0}" -gt 0 ] 2>/dev/null; then
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
        local pod_data total running pending
        pod_data=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null)
        total=$(echo "$pod_data" | grep -c '.')
        running=$(echo "$pod_data" | grep -c "Running")
        pending=$(echo "$pod_data" | grep -c "Pending")
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
EXTRA="${3:-}"

case "$ACTION" in
    deploy)
        if [ "$TARGET" = "all" ]; then
            deploy_all
        else
            dispatch deploy "$TARGET"
        fi
        ;;

    delete)
        if [ "$TARGET" = "all" ]; then
            delete_all
        else
            dispatch delete "$TARGET"
        fi
        ;;

    redeploy)
        if [ "$TARGET" = "all" ]; then
            redeploy_all
        else
            dispatch redeploy "$TARGET"
        fi
        ;;

    scale)
        dispatch scale "$TARGET" "$EXTRA"
        ;;

    logs)
        if [ "$TARGET" = "all" ]; then
            err "Cần chỉ định target cụ thể cho logs"
            echo "    Cú pháp: $0 logs <target>"
            exit 1
        fi
        dispatch logs "$TARGET" "$EXTRA"
        ;;

    check)
        if [ "$TARGET" = "all" ]; then
            err "Cần chỉ định target cụ thể cho check"
            echo "    Cú pháp: $0 check <target>"
            echo "    Targets có check: bigdata, oracle, mssql, localstack, monitoring, sure"
            exit 1
        fi
        dispatch check "$TARGET"
        ;;

    status)
        show_status
        ;;

    health)
        check_health
        ;;

    nuke)
        echo -e "${RED}!!! CẢNH BÁO: Xóa TOÀN BỘ workloads (bao gồm PVC) !!!${NC}"
        read -p "Xác nhận? (y/N): " confirm
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            delete_all
            echo ""
            ok "ĐÃ XÓA TOÀN BỘ!"
        else
            warn "Hủy."
        fi
        ;;

    *)
        echo -e "${YELLOW}==================================================================="
        echo -e "  K3s Helm Manager"
        echo -e "  BigData · Oracle · MSSQL · LocalStack · Logging · Monitoring"
        echo -e "  Cloudflared · Headlamp · Sure"
        echo -e "===================================================================${NC}"
        echo ""
        echo -e "Cú pháp: ${CYAN}$0 <action> [target] [args]${NC}"
        echo ""
        echo "Actions:"
        echo -e "  ${GREEN}deploy${NC}   [target|all]   Deploy (install lần đầu, upgrade nếu đã có)"
        echo -e "  ${RED}delete${NC}   [target|all]   Force xóa toàn bộ (pods, PVC, namespace)"
        echo -e "  ${YELLOW}redeploy${NC} [target|all]   Force delete + deploy lại sạch"
        echo -e "  ${BLUE}scale${NC}    <target> <N>   Scale workers/replicas"
        echo -e "  ${CYAN}logs${NC}     <target>       Tail logs pod chính"
        echo -e "  ${CYAN}check${NC}    <target>       Health check component"
        echo -e "  ${CYAN}status${NC}                  Xem trạng thái"
        echo -e "  ${CYAN}health${NC}                  Health check + fault tolerance"
        echo -e "  ${RED}nuke${NC}                    XÓA TẤT CẢ + PVC"
        echo ""
        echo "Targets: bigdata, oracle, mssql, localstack, logging, monitoring, cloudflared, headlamp, sure"
        echo ""
        echo "Hoặc gọi trực tiếp từng component:"
        echo "  bash bigdata.sh deploy       bash oracle.sh check"
        echo "  bash localstack.sh check     bash monitoring.sh check"
        echo ""
        echo -e "${CYAN}Lưu ý: Worker nodes có thể offline.${NC}"
        echo -e "${CYAN}Pod trên node offline sẽ Pending — đó là bình thường.${NC}"
        ;;
esac
