#!/bin/bash
# =================================================================
# logging.sh — Quản lý Logging (Loki + Alloy)
# =================================================================
# Sử dụng:
#   bash logging.sh deploy          Deploy / Upgrade
#   bash logging.sh delete          Force xóa
#   bash logging.sh redeploy        Delete + Deploy
#   bash logging.sh logs [loki|alloy]  Tail logs
# =================================================================

source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

NS="logging"

# ======================== DEPLOY ========================

do_deploy() {
    check_node_labels logging
    if ! check_secrets logging "$NS" quiet; then
        bash "$K3S_DIR/init-sec.sh" "$NS"
    fi
    check_secrets logging "$NS"
    info "Deploy Logging (Loki + Alloy) → namespace: $NS"
    if release_exists log $NS; then
        ok "(Upgrade existing release)"
        helm upgrade log "$K3S_DIR/services/logging" -n $NS $HELM_TIMEOUT
    else
        helm install log "$K3S_DIR/services/logging" -n $NS --create-namespace $HELM_TIMEOUT
    fi
    wait_for_ready $NS
}

# ======================== DELETE ========================

do_delete() {
    info "Force xóa Logging..."
    helm uninstall log -n $NS 2>/dev/null
    # Cleanup cluster-scoped resources
    kubectl delete clusterrole alloy $FORCE 2>/dev/null
    kubectl delete clusterrolebinding alloy $FORCE 2>/dev/null
    force_cleanup_ns $NS
}

# ======================== LOGS ========================

do_logs() {
    local target="${1:-loki}"
    case "$target" in
        loki)  kubectl logs -f -n $NS -l app=loki --tail=100 ;;
        alloy) kubectl logs -f -n $NS -l app=alloy --tail=100 --max-log-requests=10 ;;
        *)
            err "Target không hợp lệ: $target"
            echo "    Targets: loki, alloy"
            exit 1
            ;;
    esac
}

# ======================== MAIN ========================

ACTION="${1:-}"
case "$ACTION" in
    deploy)   do_deploy ;;
    delete)   do_delete ;;
    redeploy) do_delete; sleep 5; do_deploy ;;
    logs)     do_logs "$2" ;;
    *)
        echo -e "${YELLOW}logging.sh — Quản lý Logging (Loki + Alloy)${NC}"
        echo ""
        echo "Cú pháp: $0 <action> [args]"
        echo ""
        echo "Actions:"
        echo -e "  ${GREEN}deploy${NC}             Deploy / Upgrade"
        echo -e "  ${RED}delete${NC}             Force xóa"
        echo -e "  ${YELLOW}redeploy${NC}           Delete + Deploy lại sạch"
        echo -e "  ${CYAN}logs${NC} [loki|alloy]   Tail logs (default: loki)"
        ;;
esac
