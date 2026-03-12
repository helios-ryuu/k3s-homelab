#!/bin/bash
# =================================================================
# ddb-check.sh — Kiểm tra sức khỏe Oracle + MSSQL (DDB Labs)
# =================================================================
# Sử dụng: bash ./ddb-check.sh
# =================================================================
# Kiểm tra:
#   1. Pod status (Running / Pending / CrashLoop)
#   2. Oracle health (listener, instance status)
#   3. Oracle connectivity (cross-instance tnsping + sqlplus)
#   4. MSSQL health (sqlcmd SELECT @@SERVERNAME)
#   5. MSSQL connectivity (cross-instance query qua headless DNS)
#   6. Tóm tắt kết quả
# =================================================================
# Graceful: pod Pending → warn + skip exec tests
# =================================================================

ORA_NS="oracle"
MSSQL_NS="mssql"
ORA_PWD="Oracle@2026"
MSSQL_PWD="MSSQLServer@2026"
ORA_SID="ORCLCDB"
SQLPLUS="/opt/oracle/product/19c/dbhome_1/bin/sqlplus"
LSNRCTL="/opt/oracle/product/19c/dbhome_1/bin/lsnrctl"
TNSPING="/opt/oracle/product/19c/dbhome_1/bin/tnsping"
SQLCMD="/opt/mssql-tools18/bin/sqlcmd"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

ok()   { echo -e "  ${GREEN}✔${NC} $*"; ((PASS++)); }
fail() { echo -e "  ${RED}✘${NC} $*"; ((FAIL++)); }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; ((WARN++)); }
info() { echo -e "${CYAN}>>> $*${NC}"; }
hdr()  { echo -e "\n${BOLD}--- $* ---${NC}"; }

# Lấy trạng thái pod: Running / Pending / khác
# Returns: status hoặc "MISSING"
get_pod_status() {
    local ns="$1" pod="$2"
    local line
    line=$(kubectl get pod -n "$ns" "$pod" --no-headers 2>/dev/null)
    if [ -z "$line" ]; then
        echo "MISSING"
    else
        echo "$line" | awk '{print $3}'
    fi
}

get_pod_node() {
    local ns="$1" pod="$2"
    kubectl get pod -n "$ns" "$pod" -o jsonpath='{.spec.nodeName}' 2>/dev/null
}

get_pod_ready() {
    local ns="$1" pod="$2"
    kubectl get pod -n "$ns" "$pod" --no-headers 2>/dev/null | awk '{print $2}'
}

# ==============================================================
hdr "1/6  POD STATUS"
# ==============================================================

# Oracle pods
declare -a ORA_PODS_RUNNING=()
for i in 0 1; do
    pod="oracle-db-$i"
    status=$(get_pod_status "$ORA_NS" "$pod")
    ready=$(get_pod_ready "$ORA_NS" "$pod")
    node=$(get_pod_node "$ORA_NS" "$pod")

    if [ "$status" = "MISSING" ]; then
        fail "Oracle $pod — MISSING (namespace $ORA_NS có thể chưa deploy)"
    elif [ "$status" = "Running" ]; then
        ok "Oracle $pod — $ready  Running  ($node)"
        ORA_PODS_RUNNING+=("$i")
    elif [ "$status" = "Pending" ]; then
        warn "Oracle $pod — Pending (node $node có thể offline)"
    else
        fail "Oracle $pod — $status"
    fi
done

# MSSQL pods (0, 1, 2)
declare -a MSSQL_PODS_RUNNING=()
for i in 0 1 2; do
    pod="mssql-db-$i"
    status=$(get_pod_status "$MSSQL_NS" "$pod")
    if [ "$status" = "MISSING" ]; then
        # Pod 2 có thể không tồn tại nếu replicas=2
        if [ "$i" -eq 2 ]; then
            info "  MSSQL $pod — không tồn tại (replicas có thể = 2, bình thường)"
        else
            fail "MSSQL $pod — MISSING (namespace $MSSQL_NS có thể chưa deploy)"
        fi
        continue
    fi
    ready=$(get_pod_ready "$MSSQL_NS" "$pod")
    node=$(get_pod_node "$MSSQL_NS" "$pod")

    if [ "$status" = "Running" ]; then
        ok "MSSQL $pod — $ready  Running  ($node)"
        MSSQL_PODS_RUNNING+=("$i")
    elif [ "$status" = "Pending" ]; then
        warn "MSSQL $pod — Pending (node có thể offline)"
    else
        fail "MSSQL $pod — $status"
    fi
done

# ==============================================================
hdr "2/6  ORACLE HEALTH"
# ==============================================================

if [ ${#ORA_PODS_RUNNING[@]} -eq 0 ]; then
    warn "Không có Oracle pod Running — bỏ qua health check"
else
    for i in "${ORA_PODS_RUNNING[@]}"; do
        pod="oracle-db-$i"
        node=$(get_pod_node "$ORA_NS" "$pod")

        # Listener status
        info "  Oracle-$i ($node): Listener"
        lsnr_out=$(kubectl exec -n "$ORA_NS" "$pod" -c oracle-engine -- bash -c "$LSNRCTL status" 2>&1)
        if echo "$lsnr_out" | grep -q "Instance.*READY"; then
            ok "Oracle-$i: Listener READY"
        elif echo "$lsnr_out" | grep -q "Connecting to"; then
            warn "Oracle-$i: Listener đang chạy nhưng instance chưa READY"
        else
            fail "Oracle-$i: Listener KHÔNG phản hồi"
        fi

        # Instance status qua sqlplus
        info "  Oracle-$i ($node): Instance"
        inst_out=$(kubectl exec -n "$ORA_NS" "$pod" -c oracle-engine -- bash -c "
            $SQLPLUS -s /nolog <<EOF
CONNECT sys/\"$ORA_PWD\"@localhost/$ORA_SID as sysdba
SET HEADING OFF FEEDBACK OFF
SELECT status FROM v\\\$instance;
EOF
        " 2>&1)
        if echo "$inst_out" | grep -q "OPEN"; then
            ok "Oracle-$i: Instance OPEN"
        elif echo "$inst_out" | grep -q "MOUNTED"; then
            warn "Oracle-$i: Instance MOUNTED (chưa OPEN)"
        else
            fail "Oracle-$i: Instance không khả dụng"
        fi
    done
fi

# ==============================================================
hdr "3/6  ORACLE CONNECTIVITY (cross-instance)"
# ==============================================================

if [ ${#ORA_PODS_RUNNING[@]} -lt 2 ]; then
    warn "Cần ít nhất 2 Oracle pod Running để test cross-instance — bỏ qua"
else
    # tnsping Oracle-0 → Oracle-1
    info "  Oracle-0 → Oracle-1: tnsping"
    tns01=$(kubectl exec -n "$ORA_NS" oracle-db-0 -c oracle-engine -- bash -c "$TNSPING ORACLE_DB_1" 2>&1)
    if echo "$tns01" | grep -q "OK"; then
        ok "tnsping Oracle-0 → Oracle-1: OK"
    else
        fail "tnsping Oracle-0 → Oracle-1: THẤT BẠI"
    fi

    # tnsping Oracle-1 → Oracle-0
    info "  Oracle-1 → Oracle-0: tnsping"
    tns10=$(kubectl exec -n "$ORA_NS" oracle-db-1 -c oracle-engine -- bash -c "$TNSPING ORACLE_DB_0" 2>&1)
    if echo "$tns10" | grep -q "OK"; then
        ok "tnsping Oracle-1 → Oracle-0: OK"
    else
        fail "tnsping Oracle-1 → Oracle-0: THẤT BẠI"
    fi

    # SQL connect: Oracle-0 query Oracle-1
    info "  Oracle-0 → Oracle-1: SQL query"
    sql01=$(kubectl exec -n "$ORA_NS" oracle-db-0 -c oracle-engine -- bash -c "
        $SQLPLUS -s /nolog <<EOF
CONNECT sys/\"$ORA_PWD\"@ORACLE_DB_1 as sysdba
SET HEADING OFF FEEDBACK OFF
SELECT host_name FROM v\\\$instance;
EOF
    " 2>&1)
    if echo "$sql01" | grep -q -v "ORA-\|ERROR\|SP2-"; then
        remote_host=$(echo "$sql01" | grep -v "^$" | tail -1 | xargs)
        ok "Oracle-0 → Oracle-1: kết nối thành công (host: $remote_host)"
    else
        fail "Oracle-0 → Oracle-1: kết nối thất bại"
    fi

    # SQL connect: Oracle-1 query Oracle-0
    info "  Oracle-1 → Oracle-0: SQL query"
    sql10=$(kubectl exec -n "$ORA_NS" oracle-db-1 -c oracle-engine -- bash -c "
        $SQLPLUS -s /nolog <<EOF
CONNECT sys/\"$ORA_PWD\"@ORACLE_DB_0 as sysdba
SET HEADING OFF FEEDBACK OFF
SELECT host_name FROM v\\\$instance;
EOF
    " 2>&1)
    if echo "$sql10" | grep -q -v "ORA-\|ERROR\|SP2-"; then
        remote_host=$(echo "$sql10" | grep -v "^$" | tail -1 | xargs)
        ok "Oracle-1 → Oracle-0: kết nối thành công (host: $remote_host)"
    else
        fail "Oracle-1 → Oracle-0: kết nối thất bại"
    fi
fi

# ==============================================================
hdr "4/6  MSSQL HEALTH"
# ==============================================================

if [ ${#MSSQL_PODS_RUNNING[@]} -eq 0 ]; then
    warn "Không có MSSQL pod Running — bỏ qua health check"
else
    for i in "${MSSQL_PODS_RUNNING[@]}"; do
        pod="mssql-db-$i"
        node=$(get_pod_node "$MSSQL_NS" "$pod")

        info "  MSSQL-$i ($node): Server identity"
        srv_out=$(kubectl exec -n "$MSSQL_NS" "$pod" -c mssql-engine -- \
            $SQLCMD -S localhost -U sa -P "$MSSQL_PWD" -No \
            -h -1 -W -Q "SELECT @@SERVERNAME" 2>&1)
        if [ $? -eq 0 ] && echo "$srv_out" | grep -q -v "Sqlcmd: Error"; then
            srv_name=$(echo "$srv_out" | head -1 | xargs)
            ok "MSSQL-$i: Server = $srv_name"
        else
            fail "MSSQL-$i: sqlcmd không kết nối được"
        fi

        # Kiểm tra database MSSQLDB
        info "  MSSQL-$i ($node): Database MSSQLDB"
        db_out=$(kubectl exec -n "$MSSQL_NS" "$pod" -c mssql-engine -- \
            $SQLCMD -S localhost -U sa -P "$MSSQL_PWD" -No \
            -h -1 -W -Q "SELECT name FROM sys.databases WHERE name='MSSQLDB'" 2>&1)
        if echo "$db_out" | grep -q "MSSQLDB"; then
            ok "MSSQL-$i: Database MSSQLDB tồn tại"
        else
            warn "MSSQL-$i: Database MSSQLDB chưa được tạo (init sidecar có thể đang chạy)"
        fi
    done
fi

# ==============================================================
hdr "5/6  MSSQL CONNECTIVITY (cross-instance)"
# ==============================================================

if [ ${#MSSQL_PODS_RUNNING[@]} -lt 2 ]; then
    warn "Cần ít nhất 2 MSSQL pod Running để test cross-instance — bỏ qua"
else
    # Lấy 2 pod Running đầu tiên để test
    src_i=${MSSQL_PODS_RUNNING[0]}
    dst_i=${MSSQL_PODS_RUNNING[1]}

    # MSSQL-src → MSSQL-dst
    info "  MSSQL-$src_i → MSSQL-$dst_i: cross-instance query"
    remote_dns="mssql-db-${dst_i}.mssql-svc.${MSSQL_NS}.svc.cluster.local"
    cross_out=$(kubectl exec -n "$MSSQL_NS" "mssql-db-$src_i" -c mssql-engine -- \
        $SQLCMD -S "$remote_dns" -U sa -P "$MSSQL_PWD" -No \
        -h -1 -W -Q "SELECT @@SERVERNAME" 2>&1)
    if [ $? -eq 0 ] && echo "$cross_out" | grep -q -v "Sqlcmd: Error"; then
        remote_srv=$(echo "$cross_out" | head -1 | xargs)
        ok "MSSQL-$src_i → MSSQL-$dst_i: kết nối thành công (server: $remote_srv)"
    else
        fail "MSSQL-$src_i → MSSQL-$dst_i: kết nối thất bại"
    fi

    # MSSQL-dst → MSSQL-src
    info "  MSSQL-$dst_i → MSSQL-$src_i: cross-instance query"
    remote_dns="mssql-db-${src_i}.mssql-svc.${MSSQL_NS}.svc.cluster.local"
    cross_out=$(kubectl exec -n "$MSSQL_NS" "mssql-db-$dst_i" -c mssql-engine -- \
        $SQLCMD -S "$remote_dns" -U sa -P "$MSSQL_PWD" -No \
        -h -1 -W -Q "SELECT @@SERVERNAME" 2>&1)
    if [ $? -eq 0 ] && echo "$cross_out" | grep -q -v "Sqlcmd: Error"; then
        remote_srv=$(echo "$cross_out" | head -1 | xargs)
        ok "MSSQL-$dst_i → MSSQL-$src_i: kết nối thành công (server: $remote_srv)"
    else
        fail "MSSQL-$dst_i → MSSQL-$src_i: kết nối thất bại"
    fi

    # Nếu có pod thứ 3, test thêm
    if [ ${#MSSQL_PODS_RUNNING[@]} -ge 3 ]; then
        third_i=${MSSQL_PODS_RUNNING[2]}
        info "  MSSQL-$src_i → MSSQL-$third_i: cross-instance query"
        remote_dns="mssql-db-${third_i}.mssql-svc.${MSSQL_NS}.svc.cluster.local"
        cross_out=$(kubectl exec -n "$MSSQL_NS" "mssql-db-$src_i" -c mssql-engine -- \
            $SQLCMD -S "$remote_dns" -U sa -P "$MSSQL_PWD" -No \
            -h -1 -W -Q "SELECT @@SERVERNAME" 2>&1)
        if [ $? -eq 0 ] && echo "$cross_out" | grep -q -v "Sqlcmd: Error"; then
            remote_srv=$(echo "$cross_out" | head -1 | xargs)
            ok "MSSQL-$src_i → MSSQL-$third_i: kết nối thành công (server: $remote_srv)"
        else
            fail "MSSQL-$src_i → MSSQL-$third_i: kết nối thất bại"
        fi
    fi
fi

# ==============================================================
hdr "6/6  EXTERNAL ACCESS (Tailscale NodePort)"
# ==============================================================

# Oracle NodePort 31521
info "  Oracle NodePort 31521"
for i in "${ORA_PODS_RUNNING[@]}"; do
    pod="oracle-db-$i"
    node=$(get_pod_node "$ORA_NS" "$pod")
    # Lấy Tailscale IP của node
    ts_ip=$(kubectl get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
    if [ -n "$ts_ip" ]; then
        # TCP check port 31521
        if timeout 3 bash -c "echo >/dev/tcp/$ts_ip/31521" 2>/dev/null; then
            ok "Oracle-$i: $ts_ip:31521 reachable"
        else
            warn "Oracle-$i: $ts_ip:31521 không phản hồi (Oracle có thể đang khởi động)"
        fi
    fi
done

# MSSQL NodePort 31433
info "  MSSQL NodePort 31433"
for i in "${MSSQL_PODS_RUNNING[@]}"; do
    pod="mssql-db-$i"
    node=$(get_pod_node "$MSSQL_NS" "$pod")
    ts_ip=$(kubectl get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
    if [ -n "$ts_ip" ]; then
        if timeout 3 bash -c "echo >/dev/tcp/$ts_ip/31433" 2>/dev/null; then
            ok "MSSQL-$i: $ts_ip:31433 reachable"
        else
            warn "MSSQL-$i: $ts_ip:31433 không phản hồi (MSSQL có thể đang khởi động)"
        fi
    fi
done

# ==============================================================
# TÓM TẮT
# ==============================================================
echo ""
echo -e "${BOLD}═══════════════════════════════════════${NC}"
echo -ne "  Kết quả: "
echo -ne "${GREEN}$PASS passed${NC}  "
[ "$WARN" -gt 0 ] && echo -ne "${YELLOW}$WARN warnings${NC}  "
[ "$FAIL" -gt 0 ] && echo -ne "${RED}$FAIL failed${NC}  "
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo -e "  ${RED}Trạng thái: CÓ LỖI${NC}"
    echo ""
    echo -e "  ${CYAN}Gợi ý sửa lỗi:${NC}"
    echo "    - Pod MISSING: chạy 'bash ./mng.sh deploy oracle' hoặc 'deploy mssql'"
    echo "    - Pod Pending: Worker node offline, chờ node online hoặc scale down"
    echo "    - Oracle Listener lỗi: Oracle cần 3-5 phút khởi động, thử lại sau"
    echo "    - MSSQL sqlcmd lỗi: Kiểm tra init sidecar logs 'kubectl logs -n mssql mssql-db-X -c mssql-init'"
    echo "    - Cross-instance thất bại: Kiểm tra DNS headless service + network policy"
    echo "    - Image thiếu: Chạy 'sudo ctr -n k8s.io images import <file>.tar' trên node"
elif [ "$WARN" -gt 0 ]; then
    echo -e "  ${YELLOW}Trạng thái: CÓ CẢNH BÁO${NC}"
    echo ""
    echo -e "  ${CYAN}Lưu ý:${NC}"
    echo "    - Pod Pending do node offline là bình thường (fault tolerance)"
    echo "    - Oracle cần 3-5 phút khởi động lần đầu"
    echo "    - MSSQL init sidecar cần 30-60s tạo database"
else
    echo -e "  ${GREEN}Trạng thái: TẤT CẢ HOẠT ĐỘNG TỐT${NC}"
fi
echo -e "${BOLD}═══════════════════════════════════════${NC}"

