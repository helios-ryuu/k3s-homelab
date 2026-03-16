#!/bin/bash
# =================================================================
# cfd.sh — Quản lý Cloudflare Tunnel
# =================================================================
# Sử dụng:
#   bash cfd.sh deploy          Deploy / Upgrade
#   bash cfd.sh delete          Force xóa
#   bash cfd.sh redeploy        Delete + Deploy
#   bash cfd.sh logs            Tail logs
# =================================================================

source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

NS="cloudflared"

# ======================== DEPLOY ========================

do_deploy() {
    check_node_labels cloudflared
    if ! check_secrets cloudflared "$NS" quiet; then
        bash "$K3S_DIR/init-sec.sh" "$NS"
    fi
    check_secrets cloudflared "$NS"
    info "Deploy Cloudflare Tunnel → namespace: $NS"
    if release_exists cfd $NS; then
        ok "(Upgrade existing release)"
        helm upgrade cfd "$K3S_DIR/services/cloudflared" -n $NS $HELM_TIMEOUT
    else
        helm install cfd "$K3S_DIR/services/cloudflared" -n $NS --create-namespace $HELM_TIMEOUT
    fi
    wait_for_ready $NS
}

# ======================== DELETE ========================

do_delete() {
    info "Force xóa Cloudflare Tunnel..."
    helm uninstall cfd -n $NS 2>/dev/null
    force_cleanup_ns $NS
}

# ======================== LOGS ========================

do_logs() {
    kubectl logs -f -n $NS -l app=cloudflared --tail=100
}

# ======================== MAIN ========================

ACTION="${1:-}"
case "$ACTION" in
    deploy)   do_deploy ;;
    delete)   do_delete ;;
    redeploy) do_delete; sleep 5; do_deploy ;;
    logs)     do_logs ;;
    *)
        echo -e "${YELLOW}cfd.sh — Quản lý Cloudflare Tunnel${NC}"
        echo ""
        echo "Cú pháp: $0 <action>"
        echo ""
        echo "Actions:"
        echo -e "  ${GREEN}deploy${NC}       Deploy / Upgrade"
        echo -e "  ${RED}delete${NC}       Force xóa"
        echo -e "  ${YELLOW}redeploy${NC}     Delete + Deploy lại sạch"
        echo -e "  ${CYAN}logs${NC}         Tail logs"
        ;;
esac
