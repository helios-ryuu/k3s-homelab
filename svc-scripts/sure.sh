#!/bin/bash
# =================================================================
# sure.sh — Sure Special Operations (Web + Worker + Postgres + Redis)
# =================================================================
# Sử dụng:
#   bash sure.sh setup                 Rails DB migrations (first time or after data loss)
#   bash sure.sh logs [web|worker]     Tail logs (default: web)
#   bash sure.sh check                 Health check Sure
# =================================================================
# Deploy/delete/redeploy: managed by ArgoCD
#   argocd app sync sure
#   argocd app delete sure --cascade
# =================================================================

source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

NS="sure"

# ======================== LOGS ========================

do_logs() {
    local target="${1:-web}"
    case "$target" in
        web)    kubectl logs -f -n $NS -l app=sure-web --tail=100 ;;
        worker) kubectl logs -f -n $NS -l app=sure-worker --tail=100 ;;
        *)
            err "Target không hợp lệ: $target"
            echo "    Targets: web, worker"
            exit 1
            ;;
    esac
}

# ======================== SETUP ========================

do_setup() {
    info "Khởi tạo database cho Sure..."
    kubectl exec -n $NS deploy/sure-web -- bundle exec rails db:prepare
    if [ $? -eq 0 ]; then
        ok "Database setup/migration hoàn tất."
    else
        err "Database setup thất bại. Kiểm tra kết nối Postgres."
    fi
}

# ======================== CHECK ========================

do_check() {
    check_reset

    # ==============================================================
    hdr "1/4  POD STATUS"
    # ==============================================================

    local deployments=("sure-postgres" "sure-redis" "sure-web" "sure-worker")
    local POSTGRES_OK=false
    local REDIS_OK=false
    local WEB_OK=false

    for dep in "${deployments[@]}"; do
        local line
        line=$(kubectl get pods -n "$NS" -l app="$dep" --no-headers 2>/dev/null | head -1)
        if [ -z "$line" ]; then
            chk_fail "$dep — pod MISSING"
            continue
        fi
        local pod_name=$(echo "$line" | awk '{print $1}')
        local ready=$(echo "$line" | awk '{print $2}')
        local status=$(echo "$line" | awk '{print $3}')
        local node=$(kubectl get pod -n "$NS" "$pod_name" -o jsonpath='{.spec.nodeName}' 2>/dev/null)

        if [ "$status" = "Running" ]; then
            chk_ok "$dep — $ready $status ($node)"
            case "$dep" in
                sure-postgres) POSTGRES_OK=true ;;
                sure-redis) REDIS_OK=true ;;
                sure-web) WEB_OK=true ;;
            esac
        elif [ "$status" = "Pending" ]; then
            chk_warn "$dep — Pending ($node — node có thể offline)"
        else
            chk_fail "$dep — $status ($node)"
        fi
    done

    # ==============================================================
    hdr "2/4  DATABASE HEALTH"
    # ==============================================================

    if $POSTGRES_OK; then
        local pg_pod
        pg_pod=$(kubectl get pods -n "$NS" -l app=sure-postgres --no-headers 2>/dev/null | awk '{print $1}' | head -1)
        local pg_ready
        pg_ready=$(kubectl exec -n "$NS" "$pg_pod" -- pg_isready 2>&1)
        if echo "$pg_ready" | grep -q "accepting connections"; then
            chk_ok "PostgreSQL: accepting connections"
        else
            chk_fail "PostgreSQL: not ready — $pg_ready"
        fi
    else
        chk_warn "Skip PostgreSQL check (pod not running)"
    fi

    # ==============================================================
    hdr "3/4  REDIS HEALTH"
    # ==============================================================

    if $REDIS_OK; then
        local redis_pod
        redis_pod=$(kubectl get pods -n "$NS" -l app=sure-redis --no-headers 2>/dev/null | awk '{print $1}' | head -1)
        local redis_ping
        redis_ping=$(kubectl exec -n "$NS" "$redis_pod" -- redis-cli ping 2>&1)
        if echo "$redis_ping" | grep -q "PONG"; then
            chk_ok "Redis: PONG (healthy)"
        else
            chk_fail "Redis: not responding — $redis_ping"
        fi
    else
        chk_warn "Skip Redis check (pod not running)"
    fi

    # ==============================================================
    hdr "4/4  WEB ENDPOINT"
    # ==============================================================

    if $WEB_OK; then
        local sure_node
        sure_node=$(kubectl get nodes -l app-host=sure -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        local sure_ip
        sure_ip=$(kubectl get node "$sure_node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
        if [ -n "$sure_ip" ]; then
            local http_code
            http_code=$(curl -sf --max-time 5 -o /dev/null -w "%{http_code}" "http://${sure_ip}:30333" 2>/dev/null)
            if [ "$http_code" = "200" ] || [ "$http_code" = "302" ]; then
                chk_ok "Sure Web: http://${sure_ip}:30333 — HTTP $http_code"
            else
                chk_fail "Sure Web: http://${sure_ip}:30333 — HTTP ${http_code:-timeout}"
            fi
        else
            chk_warn "Sure Web: không tìm được node IP"
        fi
    else
        chk_warn "Skip Web endpoint check (pod not running)"
    fi

    check_summary

    if [ "$FAIL" -gt 0 ]; then
        echo ""
        echo -e "  ${CYAN}Gợi ý sửa lỗi:${NC}"
        echo "    - Pod MISSING: chạy 'bash sure.sh deploy'"
        echo "    - Pod Pending: Node offline, chờ node online"
        echo "    - PostgreSQL not ready: Kiểm tra PVC và logs 'kubectl logs -n sure -l app=sure-postgres'"
        echo "    - Redis not responding: Kiểm tra 'kubectl logs -n sure -l app=sure-redis'"
        echo "    - Web HTTP fail: Chạy 'bash sure.sh setup' nếu chưa migrate DB"
    fi
}

# ======================== MAIN ========================

ACTION="${1:-}"
case "$ACTION" in
    setup)    do_setup ;;
    logs)     do_logs "$2" ;;
    check)    do_check ;;
    *)
        echo -e "${YELLOW}sure.sh — Sure Special Operations (Web + Worker + Postgres + Redis)${NC}"
        echo ""
        echo "Cú pháp: $0 <action> [args]"
        echo ""
        echo "Actions:"
        echo -e "  ${CYAN}setup${NC}               Rails DB migrations (first time or after data loss)"
        echo -e "  ${CYAN}logs${NC} [web|worker]    Tail logs (default: web)"
        echo -e "  ${CYAN}check${NC}               Health check Sure"
        echo ""
        echo "Deploy/delete/redeploy → ArgoCD:"
        echo "  argocd app sync sure"
        echo "  argocd app delete sure --cascade"
        ;;
esac
