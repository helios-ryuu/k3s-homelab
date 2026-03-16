#!/bin/bash
# =================================================================
# mssql.sh — Quản lý MSSQL Server
# =================================================================
# Sử dụng:
#   bash mssql.sh deploy          Deploy / Upgrade
#   bash mssql.sh delete          Force xóa
#   bash mssql.sh redeploy        Delete + Deploy
#   bash mssql.sh scale <N>       Scale replicas
#   bash mssql.sh logs            Tail logs
#   bash mssql.sh check           Health check MSSQL
# =================================================================

source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

MSSQL_NS="mssql"
MSSQL_PWD="MSSQLServer@2026"
SQLCMD="/opt/mssql-tools18/bin/sqlcmd"

# ======================== DEPLOY ========================

do_deploy() {
    check_node_labels mssql
    if ! check_secrets mssql "$MSSQL_NS" quiet; then
        bash "$K3S_DIR/init-sec.sh" "$MSSQL_NS"
    fi
    check_secrets mssql "$MSSQL_NS"

    # Count labeled nodes → set replicas dynamically
    local node_count
    node_count=$(kubectl get nodes -l node-role.kubernetes.io/database-mssql=true --no-headers 2>/dev/null | grep -c .)
    info "Deploy MSSQL → namespace: $MSSQL_NS  (replicas: $node_count nodes)"

    # Reset nodeSelector and replicas in values.yaml
    sed -i '/^nodeSelector:/,/^[^ ]/d' "$K3S_DIR/services/mssql/values.yaml"
    printf "nodeSelector:\n  node-role.kubernetes.io/database-mssql: \"true\"\n" >> "$K3S_DIR/services/mssql/values.yaml"
    sed -i "s/^replicas: .*/replicas: $node_count/" "$K3S_DIR/services/mssql/values.yaml"

    if release_exists mssql $MSSQL_NS; then
        ok "(Upgrade existing release)"
        helm upgrade mssql "$K3S_DIR/services/mssql" -n $MSSQL_NS $HELM_TIMEOUT
    else
        helm install mssql "$K3S_DIR/services/mssql" -n $MSSQL_NS --create-namespace $HELM_TIMEOUT
    fi
    wait_for_ready $MSSQL_NS
}

# ======================== DELETE ========================

do_delete() {
    if [[ "$1" == "node" && -n "$2" ]]; then
        local del_node="$2"
        info "Xóa MSSQL trên node $del_node..."
        pod_name=$(kubectl get pod -n $MSSQL_NS -o json | jq -r ".items[] | select(.spec.nodeName==\"$del_node\") | .metadata.name")
        if [ -n "$pod_name" ]; then
            kubectl patch pod "$pod_name" -n $MSSQL_NS -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
            kubectl delete pod "$pod_name" -n $MSSQL_NS $FORCE
            pvc_name=$(kubectl get pvc -n $MSSQL_NS -o json | jq -r ".items[] | select(.metadata.name | test(\"$pod_name\")) | .metadata.name")
            if [ -n "$pvc_name" ]; then
                kubectl patch pvc "$pvc_name" -n $MSSQL_NS -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
                kubectl delete pvc "$pvc_name" -n $MSSQL_NS $FORCE
            fi
            ok "Đã xóa pod và PVC trên node $del_node"
        else
            warn "Không tìm thấy pod MSSQL trên node $del_node"
        fi
    else
        info "Force xóa MSSQL..."
        helm uninstall mssql -n $MSSQL_NS 2>/dev/null || true
        force_cleanup_ns $MSSQL_NS
    fi
}

# ======================== SCALE ========================

do_scale() {
    local replicas="$1"
    if [ -z "$replicas" ]; then
        err "Thiếu số replicas"
        echo "    Cú pháp: $0 scale <N>"
        exit 1
    fi
    info "Scale MSSQL → $replicas"
    helm upgrade mssql "$K3S_DIR/services/mssql" -n $MSSQL_NS --set replicas="$replicas" $HELM_TIMEOUT
    wait_for_ready $MSSQL_NS
}

# ======================== LOGS ========================

do_logs() {
    kubectl logs -f -n $MSSQL_NS -l app=mssql -c mssql-engine --tail=100
}

# ======================== CHECK ========================

do_check() {
    check_reset
    # ==============================================================
    hdr "1/4  POD STATUS"
    # ==============================================================

    declare -a MSSQL_PODS_RUNNING=()
    mapfile -t MSSQL_ALL_PODS < <(kubectl get pods -n "$MSSQL_NS" -l app=mssql --no-headers 2>/dev/null | awk '{print $1}' | sort)

    if [ ${#MSSQL_ALL_PODS[@]} -eq 0 ]; then
        chk_fail "Không có MSSQL pod nào (namespace $MSSQL_NS chưa deploy hoặc đã xóa)"
    fi

    for pod in "${MSSQL_ALL_PODS[@]}"; do
        local idx="${pod##mssql-db-}"
        status=$(get_pod_status "$MSSQL_NS" "$pod")
        ready=$(get_pod_ready "$MSSQL_NS" "$pod")
        node=$(get_pod_node "$MSSQL_NS" "$pod")

        if [ "$status" = "Running" ]; then
            chk_ok "MSSQL $pod — $ready  Running  ($node)"
            MSSQL_PODS_RUNNING+=("$idx")
        elif [ "$status" = "Pending" ]; then
            chk_warn "MSSQL $pod — Pending (node có thể offline)"
        else
            chk_fail "MSSQL $pod — $status"
        fi
    done

    # ==============================================================
    hdr "2/4  MSSQL HEALTH"
    # ==============================================================

    if [ ${#MSSQL_PODS_RUNNING[@]} -eq 0 ]; then
        chk_warn "Không có MSSQL pod Running — bỏ qua health check"
    else
        for i in "${MSSQL_PODS_RUNNING[@]}"; do
            pod="mssql-db-$i"
            node=$(get_pod_node "$MSSQL_NS" "$pod")

            chk_info "  MSSQL-$i ($node): Server identity"
            srv_out=$(kubectl exec -n "$MSSQL_NS" "$pod" -c mssql-engine -- \
                $SQLCMD -S localhost -U sa -P "$MSSQL_PWD" -No \
                -h -1 -W -Q "SELECT @@SERVERNAME" 2>&1)
            if [ $? -eq 0 ] && ! echo "$srv_out" | grep -q "Sqlcmd: Error"; then
                srv_name=$(echo "$srv_out" | head -1 | xargs)
                chk_ok "MSSQL-$i: Server = $srv_name"
            else
                chk_fail "MSSQL-$i: sqlcmd không kết nối được"
            fi

            chk_info "  MSSQL-$i ($node): Database MSSQLDB"
            db_out=$(kubectl exec -n "$MSSQL_NS" "$pod" -c mssql-engine -- \
                $SQLCMD -S localhost -U sa -P "$MSSQL_PWD" -No \
                -h -1 -W -Q "SELECT name FROM sys.databases WHERE name='MSSQLDB'" 2>&1)
            if echo "$db_out" | grep -q "MSSQLDB"; then
                chk_ok "MSSQL-$i: Database MSSQLDB tồn tại"
            else
                chk_warn "MSSQL-$i: Database MSSQLDB chưa được tạo (init sidecar có thể đang chạy)"
            fi
        done
    fi

    # ==============================================================
    hdr "3/4  MSSQL CONNECTIVITY (cross-instance)"
    # ==============================================================

    if [ ${#MSSQL_PODS_RUNNING[@]} -lt 2 ]; then
        chk_warn "Cần ít nhất 2 MSSQL pod Running để test cross-instance — bỏ qua"
    else
        src_i=${MSSQL_PODS_RUNNING[0]}
        dst_i=${MSSQL_PODS_RUNNING[1]}

        chk_info "  MSSQL-$src_i → MSSQL-$dst_i: cross-instance query"
        remote_dns="mssql-db-${dst_i}.mssql-svc.${MSSQL_NS}.svc.cluster.local"
        cross_out=$(kubectl exec -n "$MSSQL_NS" "mssql-db-$src_i" -c mssql-engine -- \
            $SQLCMD -S "$remote_dns" -U sa -P "$MSSQL_PWD" -No \
            -h -1 -W -Q "SELECT @@SERVERNAME" 2>&1)
        if [ $? -eq 0 ] && ! echo "$cross_out" | grep -q "Sqlcmd: Error"; then
            remote_srv=$(echo "$cross_out" | head -1 | xargs)
            chk_ok "MSSQL-$src_i → MSSQL-$dst_i: kết nối thành công (server: $remote_srv)"
        else
            chk_fail "MSSQL-$src_i → MSSQL-$dst_i: kết nối thất bại"
        fi

        chk_info "  MSSQL-$dst_i → MSSQL-$src_i: cross-instance query"
        remote_dns="mssql-db-${src_i}.mssql-svc.${MSSQL_NS}.svc.cluster.local"
        cross_out=$(kubectl exec -n "$MSSQL_NS" "mssql-db-$dst_i" -c mssql-engine -- \
            $SQLCMD -S "$remote_dns" -U sa -P "$MSSQL_PWD" -No \
            -h -1 -W -Q "SELECT @@SERVERNAME" 2>&1)
        if [ $? -eq 0 ] && ! echo "$cross_out" | grep -q "Sqlcmd: Error"; then
            remote_srv=$(echo "$cross_out" | head -1 | xargs)
            chk_ok "MSSQL-$dst_i → MSSQL-$src_i: kết nối thành công (server: $remote_srv)"
        else
            chk_fail "MSSQL-$dst_i → MSSQL-$src_i: kết nối thất bại"
        fi

        if [ ${#MSSQL_PODS_RUNNING[@]} -ge 3 ]; then
            third_i=${MSSQL_PODS_RUNNING[2]}
            chk_info "  MSSQL-$src_i → MSSQL-$third_i: cross-instance query"
            remote_dns="mssql-db-${third_i}.mssql-svc.${MSSQL_NS}.svc.cluster.local"
            cross_out=$(kubectl exec -n "$MSSQL_NS" "mssql-db-$src_i" -c mssql-engine -- \
                $SQLCMD -S "$remote_dns" -U sa -P "$MSSQL_PWD" -No \
                -h -1 -W -Q "SELECT @@SERVERNAME" 2>&1)
            if [ $? -eq 0 ] && ! echo "$cross_out" | grep -q "Sqlcmd: Error"; then
                remote_srv=$(echo "$cross_out" | head -1 | xargs)
                chk_ok "MSSQL-$src_i → MSSQL-$third_i: kết nối thành công (server: $remote_srv)"
            else
                chk_fail "MSSQL-$src_i → MSSQL-$third_i: kết nối thất bại"
            fi
        fi
    fi

    # ==============================================================
    hdr "4/4  EXTERNAL ACCESS (Tailscale NodePort)"
    # ==============================================================

    chk_info "  MSSQL NodePort 31433"
    for i in "${MSSQL_PODS_RUNNING[@]}"; do
        pod="mssql-db-$i"
        node=$(get_pod_node "$MSSQL_NS" "$pod")
        ts_ip=$(kubectl get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
        if [ -n "$ts_ip" ]; then
            if timeout 3 bash -c "echo >/dev/tcp/$ts_ip/31433" 2>/dev/null; then
                chk_ok "MSSQL-$i: $ts_ip:31433 reachable"
            else
                chk_warn "MSSQL-$i: $ts_ip:31433 không phản hồi (MSSQL có thể đang khởi động)"
            fi
        fi
    done

    check_summary

    if [ "$FAIL" -gt 0 ]; then
        echo ""
        echo -e "  ${CYAN}Gợi ý sửa lỗi:${NC}"
        echo "    - Pod MISSING: chạy 'bash mssql.sh deploy'"
        echo "    - Pod Pending: Worker node offline, chờ node online hoặc scale down"
        echo "    - MSSQL sqlcmd lỗi: Kiểm tra init sidecar logs 'kubectl logs -n mssql mssql-db-X -c mssql-init'"
        echo "    - Cross-instance thất bại: Kiểm tra DNS headless service + network policy"
    fi
}

# ======================== MAIN ========================

ACTION="${1:-}"
case "$ACTION" in
    deploy)   do_deploy ;;
    delete)   do_delete ;;
    redeploy) do_delete; sleep 5; do_deploy ;;
    scale)    do_scale "$2" ;;
    logs)     do_logs ;;
    check)    do_check ;;
    *)
        echo -e "${YELLOW}mssql.sh — Quản lý MSSQL Server${NC}"
        echo ""
        echo "Cú pháp: $0 <action> [args]"
        echo ""
        echo "Actions:"
        echo -e "  ${GREEN}deploy${NC}       Deploy / Upgrade"
        echo -e "  ${RED}delete${NC}       Force xóa"
        echo -e "  ${YELLOW}redeploy${NC}     Delete + Deploy lại sạch"
        echo -e "  ${BLUE}scale${NC} <N>    Scale replicas"
        echo -e "  ${CYAN}logs${NC}         Tail logs"
        echo -e "  ${CYAN}check${NC}        Health check MSSQL"
        ;;
esac
