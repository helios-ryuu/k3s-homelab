#!/bin/bash
# =================================================================
# logging.sh — Logging Special Operations (Loki + Alloy)
# =================================================================
# Sử dụng:
#   bash logging.sh logs [loki|alloy]  Tail logs (default: loki)
# =================================================================
# Deploy/delete/redeploy: managed by ArgoCD
#   argocd app sync logging
#   argocd app delete logging --cascade
# =================================================================

source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

NS="logging"

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
    logs)     do_logs "$2" ;;
    *)
        echo -e "${YELLOW}logging.sh — Logging Special Operations (Loki + Alloy)${NC}"
        echo ""
        echo "Cú pháp: $0 <action> [args]"
        echo ""
        echo "Actions:"
        echo -e "  ${CYAN}logs${NC} [loki|alloy]   Tail logs (default: loki)"
        echo ""
        echo "Deploy/delete/redeploy → ArgoCD:"
        echo "  argocd app sync logging"
        echo "  argocd app delete logging --cascade"
        ;;
esac
