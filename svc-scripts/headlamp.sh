#!/bin/bash
# =================================================================
# headlamp.sh — Quản lý Headlamp (K8s Dashboard)
# =================================================================
# Sử dụng:
#   bash headlamp.sh deploy          Deploy / Upgrade
#   bash headlamp.sh delete          Force xóa
#   bash headlamp.sh redeploy        Delete + Deploy
# =================================================================

source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

# ======================== DEPLOY ========================

# Shared helm flags for both install and upgrade
_HEADLAMP_FLAGS=(
    --set replicaCount=1
    --set config.inCluster=true
    --set service.type=ClusterIP
    --set service.port=80
    --set 'tolerations[0].key=node-role.kubernetes.io/control-plane'
    --set 'tolerations[0].operator=Exists'
    --set 'tolerations[0].effect=NoSchedule'
    --set 'affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].weight=100'
    --set 'affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].preference.matchExpressions[0].key=node-role.kubernetes.io/control-plane'
    --set 'affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].preference.matchExpressions[0].operator=Exists'
    --set resources.requests.memory=64Mi
    --set resources.requests.cpu=50m
    --set resources.limits.memory=128Mi
    --set resources.limits.cpu=100m
)

do_deploy() {
    check_node_labels headlamp
    if ! check_secrets headlamp kube-system quiet; then
        bash "$K3S_DIR/init-sec.sh" kube-system
    fi
    check_secrets headlamp kube-system
    info "Deploy Headlamp (K8s Dashboard) → namespace: kube-system"
    if release_exists headlamp kube-system; then
        ok "(Upgrade existing release)"
        helm upgrade headlamp headlamp/headlamp -n kube-system \
            "${_HEADLAMP_FLAGS[@]}" $HELM_TIMEOUT
    else
        helm install headlamp headlamp/headlamp -n kube-system \
            "${_HEADLAMP_FLAGS[@]}" $HELM_TIMEOUT
        # RBAC: cluster-admin cho Headlamp ServiceAccount
        kubectl create clusterrolebinding headlamp-admin \
            --clusterrole=cluster-admin \
            --serviceaccount=kube-system:headlamp 2>/dev/null
        ok "ClusterRoleBinding headlamp-admin created"
    fi
    wait_for_ready kube-system
}

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

# ======================== DELETE ========================

do_delete() {
    info "Force xóa Headlamp..."
    helm uninstall headlamp -n kube-system 2>/dev/null
    kubectl delete clusterrolebinding headlamp-admin $FORCE 2>/dev/null
}

# ======================== MAIN ========================

ACTION="${1:-}"
case "$ACTION" in
    deploy)   do_deploy ;;
    delete)   do_delete ;;
    redeploy) do_delete; sleep 5; do_deploy ;;
    token)    do_token ;;
    *)
        echo -e "${YELLOW}headlamp.sh — Quản lý Headlamp (K8s Dashboard)${NC}"
        echo ""
        echo "Cú pháp: $0 <action>"
        echo ""
        echo "Actions:"
        echo -e "  ${GREEN}deploy${NC}       Deploy / Upgrade"
        echo -e "  ${RED}delete${NC}       Force xóa"
        echo -e "  ${YELLOW}redeploy${NC}     Delete + Deploy lại sạch"
        echo -e "  ${GREEN}token${NC}        Tạo / lấy permanent token"
        ;;
esac
