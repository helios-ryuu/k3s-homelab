#!/bin/bash
# =================================================================
# headlamp.sh — Headlamp Special Operations (K8s Dashboard)
# =================================================================
# Sử dụng:
#   bash headlamp.sh token           Tạo / lấy permanent auth token
# =================================================================
# Deploy/delete/redeploy: managed by ArgoCD
#   argocd app sync headlamp
#   argocd app delete headlamp --cascade
# =================================================================

source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

# ======================== TOKEN ========================

do_token() {
    info "Tạo permanent token cho Headlamp SA..."
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: headlamp-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: headlamp
type: kubernetes.io/service-account-token
EOF
    # Wait for token to be populated
    for i in $(seq 1 10); do
        TOKEN=$(kubectl get secret headlamp-token -n kube-system \
            -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)
        [ -n "$TOKEN" ] && break
        sleep 1
    done
    if [ -z "$TOKEN" ]; then
        err "Token chưa được populate. Thử lại sau."
        exit 1
    fi
    ok "Headlamp permanent token:"
    echo ""
    echo "$TOKEN"
    echo ""
}

# ======================== MAIN ========================

ACTION="${1:-}"
case "$ACTION" in
    token)    do_token ;;
    *)
        echo -e "${YELLOW}headlamp.sh — Headlamp Special Operations (K8s Dashboard)${NC}"
        echo ""
        echo "Cú pháp: $0 <action>"
        echo ""
        echo "Actions:"
        echo -e "  ${GREEN}token${NC}        Tạo / lấy permanent auth token"
        echo ""
        echo "Deploy/delete/redeploy → ArgoCD:"
        echo "  argocd app sync headlamp"
        echo "  argocd app delete headlamp --cascade"
        ;;
esac
