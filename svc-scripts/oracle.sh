#!/bin/bash
# =================================================================
# oracle.sh — Quản lý Oracle Database
# =================================================================
# Sử dụng:
#   bash oracle.sh deploy          Deploy / Upgrade
#   bash oracle.sh delete          Force xóa
#   bash oracle.sh redeploy        Delete + Deploy
#   bash oracle.sh scale <N>       Scale replicas
#   bash oracle.sh logs            Tail logs
#   bash oracle.sh check           Health check Oracle
# =================================================================

source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

ORA_NS="oracle"
ORA_PWD="Oracle@2026"
ORA_SID="ORCLCDB"
SQLPLUS="/opt/oracle/product/19c/dbhome_1/bin/sqlplus"
LSNRCTL="/opt/oracle/product/19c/dbhome_1/bin/lsnrctl"
TNSPING="/opt/oracle/product/19c/dbhome_1/bin/tnsping"

# ======================== DEPLOY ========================

do_deploy() {
    check_node_labels oracle
    if ! check_secrets oracle "$ORA_NS" quiet; then
        bash "$K3S_DIR/init-sec.sh" "$ORA_NS"
    fi
    check_secrets oracle "$ORA_NS"

    # Count labeled nodes → set replicas dynamically
    local node_count
    node_count=$(kubectl get nodes -l node-role.kubernetes.io/database-oracle=true --no-headers 2>/dev/null | grep -c .)
    info "Deploy Oracle → namespace: $ORA_NS  (replicas: $node_count nodes)"

    # Reset nodeSelector and replicas in values.yaml
    sed -i '/^nodeSelector:/,/^[^ ]/d' "$K3S_DIR/services/oracle/values.yaml"
    printf "nodeSelector:\n  node-role.kubernetes.io/database-oracle: \"true\"\n" >> "$K3S_DIR/services/oracle/values.yaml"
    sed -i "s/^replicas: .*/replicas: $node_count/" "$K3S_DIR/services/oracle/values.yaml"

    # Verify oracle image exists on all labeled nodes (imagePullPolicy: Never)
    local oracle_image
    oracle_image=$(grep 'image:' "$K3S_DIR/services/oracle/values.yaml" | head -1 | awk '{print $2}')
    local -a oracle_nodes
    mapfile -t oracle_nodes < <(kubectl get nodes -l node-role.kubernetes.io/database-oracle=true --no-headers 2>/dev/null | awk '{print $1}')
    check_image_on_nodes "$oracle_image" "${oracle_nodes[@]}" || return 1

    if release_exists ora $ORA_NS; then
        ok "(Upgrade existing release)"
        helm upgrade ora "$K3S_DIR/services/oracle" -n $ORA_NS $HELM_TIMEOUT
    else
        helm install ora "$K3S_DIR/services/oracle" -n $ORA_NS --create-namespace $HELM_TIMEOUT
    fi
    wait_for_ready $ORA_NS
}

# ======================== DELETE ========================

do_delete() {
    if [[ "$1" == "node" && -n "$2" ]]; then
        local del_node="$2"
        info "Xóa Oracle trên node $del_node..."
        pod_name=$(kubectl get pod -n $ORA_NS -o json | jq -r ".items[] | select(.spec.nodeName==\"$del_node\") | .metadata.name")
        if [ -n "$pod_name" ]; then
            kubectl patch pod "$pod_name" -n $ORA_NS -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
            kubectl delete pod "$pod_name" -n $ORA_NS $FORCE
            pvc_name=$(kubectl get pvc -n $ORA_NS -o json | jq -r ".items[] | select(.metadata.name | test(\"$pod_name\")) | .metadata.name")
            if [ -n "$pvc_name" ]; then
                kubectl patch pvc "$pvc_name" -n $ORA_NS -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
                kubectl delete pvc "$pvc_name" -n $ORA_NS $FORCE
            fi
            ok "Đã xóa pod và PVC trên node $del_node"
        else
            warn "Không tìm thấy pod Oracle trên node $del_node"
        fi
    else
        info "Force xóa Oracle..."
        helm uninstall ora -n $ORA_NS 2>/dev/null || true
        force_cleanup_ns $ORA_NS
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
    info "Scale Oracle → $replicas"
    helm upgrade ora "$K3S_DIR/services/oracle" -n $ORA_NS --set replicas="$replicas" $HELM_TIMEOUT
    wait_for_ready $ORA_NS
}

# ======================== LOGS ========================

do_logs() {
    kubectl logs -f -n $ORA_NS -l app=oracle --tail=100
}

# ======================== CHECK ========================

do_check() {
    check_reset
    # ==============================================================
    hdr "1/4  POD STATUS"
    # ==============================================================

    declare -a ORA_PODS_RUNNING=()
    mapfile -t ORA_ALL_PODS < <(kubectl get pods -n "$ORA_NS" -l app=oracle --no-headers 2>/dev/null | awk '{print $1}' | sort)

    if [ ${#ORA_ALL_PODS[@]} -eq 0 ]; then
        chk_fail "Không có Oracle pod nào (namespace $ORA_NS chưa deploy hoặc đã xóa)"
    fi

    for pod in "${ORA_ALL_PODS[@]}"; do
        local idx="${pod##oracle-db-}"
        status=$(get_pod_status "$ORA_NS" "$pod")
        ready=$(get_pod_ready "$ORA_NS" "$pod")
        node=$(get_pod_node "$ORA_NS" "$pod")

        if [ "$status" = "Running" ]; then
            chk_ok "Oracle $pod — $ready  Running  ($node)"
            ORA_PODS_RUNNING+=("$idx")
        elif [ "$status" = "Pending" ]; then
            chk_warn "Oracle $pod — Pending (node $node có thể offline)"
        else
            chk_fail "Oracle $pod — $status"
        fi
    done

    # ==============================================================
    hdr "2/4  ORACLE HEALTH"
    # ==============================================================

    if [ ${#ORA_PODS_RUNNING[@]} -eq 0 ]; then
        chk_warn "Không có Oracle pod Running — bỏ qua health check"
    else
        for i in "${ORA_PODS_RUNNING[@]}"; do
            pod="oracle-db-$i"
            node=$(get_pod_node "$ORA_NS" "$pod")

            # Listener status
            chk_info "  Oracle-$i ($node): Listener"
            lsnr_out=$(kubectl exec -n "$ORA_NS" "$pod" -c oracle-engine -- bash -c "$LSNRCTL status" 2>&1)
            if echo "$lsnr_out" | grep -q "Instance.*READY"; then
                chk_ok "Oracle-$i: Listener READY"
            elif echo "$lsnr_out" | grep -q "Connecting to"; then
                chk_warn "Oracle-$i: Listener đang chạy nhưng instance chưa READY"
            else
                chk_fail "Oracle-$i: Listener KHÔNG phản hồi"
            fi

            # Instance status qua sqlplus
            chk_info "  Oracle-$i ($node): Instance"
            inst_out=$(kubectl exec -n "$ORA_NS" "$pod" -c oracle-engine -- bash -c "
                $SQLPLUS -s /nolog <<EOF
CONNECT sys/\"$ORA_PWD\"@localhost/$ORA_SID as sysdba
SET HEADING OFF FEEDBACK OFF
SELECT status FROM v\\\$instance;
EOF
            " 2>&1)
            if echo "$inst_out" | grep -q "OPEN"; then
                chk_ok "Oracle-$i: Instance OPEN"
            elif echo "$inst_out" | grep -q "MOUNTED"; then
                chk_warn "Oracle-$i: Instance MOUNTED (chưa OPEN)"
            else
                chk_fail "Oracle-$i: Instance không khả dụng"
            fi
        done
    fi

    # ==============================================================
    hdr "3/4  ORACLE CONNECTIVITY (cross-instance)"
    # ==============================================================

    if [ ${#ORA_PODS_RUNNING[@]} -lt 2 ]; then
        chk_warn "Cần ít nhất 2 Oracle pod Running để test cross-instance — bỏ qua"
    else
        local src_i="${ORA_PODS_RUNNING[0]}"
        local dst_i="${ORA_PODS_RUNNING[1]}"

        # tnsping src → dst
        chk_info "  Oracle-$src_i → Oracle-$dst_i: tnsping"
        local tns_alias_dst="ORACLE_DB_$dst_i"
        tns01=$(kubectl exec -n "$ORA_NS" "oracle-db-$src_i" -c oracle-engine -- bash -c "$TNSPING $tns_alias_dst" 2>&1)
        if echo "$tns01" | grep -q "OK"; then
            chk_ok "tnsping Oracle-$src_i → Oracle-$dst_i: OK"
        else
            chk_fail "tnsping Oracle-$src_i → Oracle-$dst_i: THẤT BẠI"
        fi

        # tnsping dst → src
        chk_info "  Oracle-$dst_i → Oracle-$src_i: tnsping"
        local tns_alias_src="ORACLE_DB_$src_i"
        tns10=$(kubectl exec -n "$ORA_NS" "oracle-db-$dst_i" -c oracle-engine -- bash -c "$TNSPING $tns_alias_src" 2>&1)
        if echo "$tns10" | grep -q "OK"; then
            chk_ok "tnsping Oracle-$dst_i → Oracle-$src_i: OK"
        else
            chk_fail "tnsping Oracle-$dst_i → Oracle-$src_i: THẤT BẠI"
        fi

        # SQL connect: src → dst
        chk_info "  Oracle-$src_i → Oracle-$dst_i: SQL query"
        sql01=$(kubectl exec -n "$ORA_NS" "oracle-db-$src_i" -c oracle-engine -- bash -c "
            $SQLPLUS -s /nolog <<EOF
CONNECT sys/\"$ORA_PWD\"@$tns_alias_dst as sysdba
SET HEADING OFF FEEDBACK OFF
SELECT host_name FROM v\\\$instance;
EOF
        " 2>&1)
        if ! echo "$sql01" | grep -q "ORA-\|ERROR\|SP2-"; then
            remote_host=$(echo "$sql01" | grep -v "^$" | tail -1 | xargs)
            chk_ok "Oracle-$src_i → Oracle-$dst_i: kết nối thành công (host: $remote_host)"
        else
            chk_fail "Oracle-$src_i → Oracle-$dst_i: kết nối thất bại"
        fi

        # SQL connect: dst → src
        chk_info "  Oracle-$dst_i → Oracle-$src_i: SQL query"
        sql10=$(kubectl exec -n "$ORA_NS" "oracle-db-$dst_i" -c oracle-engine -- bash -c "
            $SQLPLUS -s /nolog <<EOF
CONNECT sys/\"$ORA_PWD\"@$tns_alias_src as sysdba
SET HEADING OFF FEEDBACK OFF
SELECT host_name FROM v\\\$instance;
EOF
        " 2>&1)
        if ! echo "$sql10" | grep -q "ORA-\|ERROR\|SP2-"; then
            remote_host=$(echo "$sql10" | grep -v "^$" | tail -1 | xargs)
            chk_ok "Oracle-$dst_i → Oracle-$src_i: kết nối thành công (host: $remote_host)"
        else
            chk_fail "Oracle-$dst_i → Oracle-$src_i: kết nối thất bại"
        fi
    fi

    # ==============================================================
    hdr "4/4  EXTERNAL ACCESS (Tailscale NodePort)"
    # ==============================================================

    chk_info "  Oracle NodePort 31521"
    for i in "${ORA_PODS_RUNNING[@]}"; do
        pod="oracle-db-$i"
        node=$(get_pod_node "$ORA_NS" "$pod")
        ts_ip=$(kubectl get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
        if [ -n "$ts_ip" ]; then
            if timeout 3 bash -c "echo >/dev/tcp/$ts_ip/31521" 2>/dev/null; then
                chk_ok "Oracle-$i: $ts_ip:31521 reachable"
            else
                chk_warn "Oracle-$i: $ts_ip:31521 không phản hồi (Oracle có thể đang khởi động)"
            fi
        fi
    done

    check_summary

    if [ "$FAIL" -gt 0 ]; then
        echo ""
        echo -e "  ${CYAN}Gợi ý sửa lỗi:${NC}"
        echo "    - Pod MISSING: chạy 'bash oracle.sh deploy'"
        echo "    - Pod Pending: Worker node offline, chờ node online hoặc scale down"
        echo "    - Oracle Listener lỗi: Oracle cần 3-5 phút khởi động, thử lại sau"
        echo "    - Image thiếu: Chạy 'sudo ctr -n k8s.io images import <file>.tar' trên node"
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
        echo -e "${YELLOW}oracle.sh — Quản lý Oracle Database${NC}"
        echo ""
        echo "Cú pháp: $0 <action> [args]"
        echo ""
        echo "Actions:"
        echo -e "  ${GREEN}deploy${NC}       Deploy / Upgrade"
        echo -e "  ${RED}delete${NC}       Force xóa"
        echo -e "  ${YELLOW}redeploy${NC}     Delete + Deploy lại sạch"
        echo -e "  ${BLUE}scale${NC} <N>    Scale replicas"
        echo -e "  ${CYAN}logs${NC}         Tail logs"
        echo -e "  ${CYAN}check${NC}        Health check Oracle"
        ;;
esac
