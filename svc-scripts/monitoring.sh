#!/bin/bash
# =================================================================
# monitoring.sh — Quản lý Monitoring (Prometheus + Grafana)
# =================================================================
# Sử dụng:
#   bash monitoring.sh deploy          Deploy / Upgrade
#   bash monitoring.sh delete          Force xóa
#   bash monitoring.sh redeploy        Delete + Deploy
#   bash monitoring.sh logs            Tail logs Grafana
#   bash monitoring.sh check           Health check Monitoring stack
# =================================================================

source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

MON_NS="monitoring"
LOG_NS="logging"

# ======================== DEPLOY ========================

do_deploy() {
    check_node_labels monitoring
    if ! check_secrets monitoring "$MON_NS" quiet; then
        bash "$K3S_DIR/init-sec.sh" "$MON_NS"
    fi
    check_secrets monitoring "$MON_NS"
    info "Deploy Monitoring (Prometheus + Grafana) → namespace: $MON_NS"
    if release_exists mon $MON_NS; then
        ok "(Upgrade existing release)"
        helm upgrade mon prometheus-community/kube-prometheus-stack \
            -f "$K3S_DIR/services/monitoring/values.yaml" -n $MON_NS $HELM_TIMEOUT
    else
        helm install mon prometheus-community/kube-prometheus-stack \
            -f "$K3S_DIR/services/monitoring/values.yaml" \
            -n $MON_NS --create-namespace $HELM_TIMEOUT
    fi
    wait_for_ready $MON_NS
}

# ======================== DELETE ========================

do_delete() {
    info "Force xóa Monitoring..."
    helm uninstall mon -n $MON_NS --no-hooks 2>/dev/null
    # CRDs của prometheus-operator
    kubectl delete crd alertmanagerconfigs.monitoring.coreos.com \
        alertmanagers.monitoring.coreos.com \
        podmonitors.monitoring.coreos.com \
        probes.monitoring.coreos.com \
        prometheusagents.monitoring.coreos.com \
        prometheuses.monitoring.coreos.com \
        prometheusrules.monitoring.coreos.com \
        scrapeconfigs.monitoring.coreos.com \
        servicemonitors.monitoring.coreos.com \
        thanosrulers.monitoring.coreos.com $FORCE 2>/dev/null
    force_cleanup_ns $MON_NS
}

# ======================== LOGS ========================

do_logs() {
    kubectl logs -f -n $MON_NS -l app.kubernetes.io/name=grafana --tail=100
}

# ======================== CHECK ========================

do_check() {
    check_reset
    local MASTER_IP=$(get_master_ip)
    local PROM_URL="http://${MASTER_IP}:30090"
    local GRAFANA_URL="http://${MASTER_IP}:30300"
    local LOKI_URL="http://${MASTER_IP}:30100"

    # ======================== 1/5 POD STATUS ========================

    hdr "1/5  POD STATUS"

    check_deploy_pod() {
        local ns="$1" name="$2" label="$3"
        local line
        line=$(kubectl get pods -n "$ns" -l "$label" --no-headers 2>/dev/null | head -1)
        if [ -z "$line" ]; then
            chk_fail "$name — pod MISSING"
            return 1
        fi
        local pod_name=$(echo "$line" | awk '{print $1}')
        local ready=$(echo "$line" | awk '{print $2}')
        local status=$(echo "$line" | awk '{print $3}')
        local node=$(kubectl get pod -n "$ns" "$pod_name" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
        if [ "$status" = "Running" ]; then
            chk_ok "$name — $ready $status ($node)"
            return 0
        elif [ "$status" = "Pending" ]; then
            chk_warn "$name — Pending ($node)"
            return 1
        else
            chk_fail "$name — $status ($node)"
            return 1
        fi
    }

    check_deploy_pod "$MON_NS" "Prometheus" "app.kubernetes.io/name=prometheus"
    PROM_OK=$?
    check_deploy_pod "$MON_NS" "Grafana" "app.kubernetes.io/name=grafana"
    GRAFANA_OK=$?
    check_deploy_pod "$MON_NS" "Prometheus Operator" "app.kubernetes.io/name=kube-prometheus-stack-prometheus-operator"
    check_deploy_pod "$MON_NS" "Kube State Metrics" "app.kubernetes.io/name=kube-state-metrics"

    # Node exporter (DaemonSet)
    check_daemonset "$MON_NS" "Node Exporter" "app.kubernetes.io/name=prometheus-node-exporter"

    # Alloy (DaemonSet, logging namespace)
    check_daemonset "$LOG_NS" "Alloy (logging)" "app=alloy"

    check_deploy_pod "$LOG_NS" "Loki" "app=loki"
    LOKI_OK=$?

    # ======================== 2/5 PROMETHEUS ========================

    hdr "2/5  PROMETHEUS"

    if [ "$PROM_OK" -eq 0 ]; then
        PROM_READY=$(curl -sf --max-time 5 "$PROM_URL/-/ready" 2>/dev/null)
        if echo "$PROM_READY" | grep -qi "ready\|ok" 2>/dev/null; then
            chk_ok "Prometheus readiness: OK"
        else
            chk_fail "Prometheus readiness: NOT READY"
        fi

        ACTIVE=$(curl -sf --max-time 10 "$PROM_URL/api/v1/targets" 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
targets = d.get('data',{}).get('activeTargets',[])
up = sum(1 for t in targets if t.get('health') == 'up')
down = sum(1 for t in targets if t.get('health') == 'down')
unknown = len(targets) - up - down
print(f'{up} {down} {unknown} {len(targets)}')
for t in targets:
    if t.get('health') == 'down':
        job = t.get('labels',{}).get('job','?')
        inst = t.get('labels',{}).get('instance','?')
        err = t.get('lastError','')[:80]
        print(f'DOWN:{job}:{inst}:{err}')
" 2>/dev/null)
        if [ -n "$ACTIVE" ]; then
            FIRST_LINE=$(echo "$ACTIVE" | head -1)
            UP=$(echo "$FIRST_LINE" | awk '{print $1}')
            DOWN=$(echo "$FIRST_LINE" | awk '{print $2}')
            UNKNOWN=$(echo "$FIRST_LINE" | awk '{print $3}')
            TOTAL=$(echo "$FIRST_LINE" | awk '{print $4}')
            if [ "${TOTAL:-0}" -eq 0 ]; then
                chk_warn "Prometheus: no active targets found"
            elif [ "${DOWN:-0}" -eq 0 ] 2>/dev/null; then
                chk_ok "Targets: $UP/$TOTAL up"
            else
                chk_warn "Targets: $UP up, $DOWN down, $UNKNOWN unknown (total $TOTAL)"
                echo "$ACTIVE" | grep "^DOWN:" | while IFS=: read -r _ job inst err; do
                    echo -e "    ↳ ${RED}DOWN${NC}: $job ($inst) — $err"
                done
            fi
        else
            chk_fail "Prometheus targets API: không phản hồi"
        fi

        R_COUNT=$(curl -sf --max-time 15 "$PROM_URL/api/v1/rules" 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
groups = d.get('data',{}).get('groups',[])
rules = sum(len(g.get('rules',[])) for g in groups)
print(f'{len(groups)} {rules}')
" 2>/dev/null)
        if [ -n "$R_COUNT" ]; then
            R_GROUPS=$(echo "$R_COUNT" | awk '{print $1}')
            R_RULES=$(echo "$R_COUNT" | awk '{print $2}')
            chk_ok "Rules: $R_RULES rules in $R_GROUPS groups"
        fi
    else
        chk_warn "Skip Prometheus checks (pod not running)"
    fi

    # ======================== 3/5 GRAFANA ========================

    hdr "3/5  GRAFANA"

    if [ "$GRAFANA_OK" -eq 0 ]; then
        GRAFANA_RESP=$(curl -sf --max-time 5 -o /dev/null -w "%{http_code}" "$GRAFANA_URL/api/health" 2>/dev/null)
        if [ "$GRAFANA_RESP" = "200" ]; then
            chk_ok "Grafana API health: 200 OK"
        else
            chk_fail "Grafana API health: HTTP $GRAFANA_RESP"
        fi

        DS_RESP=$(curl -sf --max-time 5 "$GRAFANA_URL/api/datasources" 2>/dev/null)
        if [ -n "$DS_RESP" ] && echo "$DS_RESP" | python3 -c "import sys,json; json.load(sys.stdin)" &>/dev/null; then
            DS_COUNT=$(echo "$DS_RESP" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)
            chk_ok "Datasources: $DS_COUNT configured"
        else
            chk_warn "Datasources: không thể kiểm tra (cần auth hoặc anonymous disabled)"
        fi
    else
        chk_warn "Skip Grafana checks (pod not running)"
    fi

    # ======================== 4/5 LOKI ========================

    hdr "4/5  LOKI"

    if [ "$LOKI_OK" -eq 0 ]; then
        LOKI_READY=$(curl -sf --max-time 5 "$LOKI_URL/ready" 2>/dev/null)
        if echo "$LOKI_READY" | grep -qi "ready" 2>/dev/null; then
            chk_ok "Loki readiness: OK"
        else
            chk_fail "Loki readiness: NOT READY"
        fi

        LABELS=$(curl -sf --max-time 5 "$LOKI_URL/loki/api/v1/labels" 2>/dev/null)
        if [ -n "$LABELS" ]; then
            LABEL_COUNT=$(echo "$LABELS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data',[])))" 2>/dev/null)
            if [ "${LABEL_COUNT:-0}" -gt 0 ]; then
                chk_ok "Loki labels: $LABEL_COUNT (data ingestion working)"
            else
                chk_warn "Loki labels: 0 (chưa có log nào?)"
            fi
        else
            chk_fail "Loki API: không phản hồi"
        fi

        NOW=$(date +%s)
        START=$((NOW - 300))
        QUERY_RESP=$(curl -sf --max-time 10 \
            "$LOKI_URL/loki/api/v1/query_range?query=%7Bnamespace%21%3D%22%22%7D&start=${START}&end=${NOW}&limit=1" 2>/dev/null)
        if [ -n "$QUERY_RESP" ]; then
            STREAMS=$(echo "$QUERY_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
streams = d.get('data',{}).get('result',[])
print(len(streams))
" 2>/dev/null)
            if [ "${STREAMS:-0}" -gt 0 ]; then
                chk_ok "Loki query test: $STREAMS stream(s) (logs flowing)"
            else
                chk_warn "Loki query test: 0 streams (không có logs trong 5 phút gần)"
            fi
        fi
    else
        chk_warn "Skip Loki checks (pod not running)"
    fi

    # ======================== 5/5 NODE COVERAGE ========================

    hdr "5/5  NODE COVERAGE"

    TOTAL_NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready")
    chk_ok "Nodes: $READY_NODES/$TOTAL_NODES Ready"

    READY_NODE_LIST=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"{print $1}')
    MISSING_NE=""
    for node in $READY_NODE_LIST; do
        NE_POD=$(kubectl get pods -n "$MON_NS" --field-selector spec.nodeName="$node" -l app.kubernetes.io/name=prometheus-node-exporter --no-headers 2>/dev/null | grep Running)
        if [ -z "$NE_POD" ]; then
            MISSING_NE+="$node "
        fi
    done

    if [ -z "$MISSING_NE" ]; then
        chk_ok "Node-Exporter: coverage 100% (mỗi Ready node có 1 pod)"
    else
        chk_warn "Node-Exporter: thiếu trên node(s): $MISSING_NE"
    fi

    MISSING_ALLOY=""
    for node in $READY_NODE_LIST; do
        ALLOY_POD=$(kubectl get pods -n "$LOG_NS" --field-selector spec.nodeName="$node" -l app=alloy --no-headers 2>/dev/null | grep Running)
        if [ -z "$ALLOY_POD" ]; then
            MISSING_ALLOY+="$node "
        fi
    done

    if [ -z "$MISSING_ALLOY" ]; then
        chk_ok "Alloy: coverage 100% (mỗi Ready node có 1 pod)"
    else
        chk_warn "Alloy: thiếu trên node(s): $MISSING_ALLOY"
    fi

    check_summary

    if [ "$FAIL" -gt 0 ]; then
        echo ""
        echo -e "  ${CYAN}Gợi ý sửa lỗi:${NC}"
        echo "    - Pod MISSING: chạy 'bash monitoring.sh deploy'"
        echo "    - Prometheus NOT READY: có thể đang load WAL (1-2 phút)"
        echo "    - Targets DOWN: kiểm tra network policies hoặc pod health"
        echo "    - Grafana 401/403: Kiểm tra grafana-admin-password trong infra-secrets"
        echo "    - Loki no labels: Alloy chưa ship logs, kiểm tra 'bash logging.sh logs'"
    fi
}

# ======================== MAIN ========================

ACTION="${1:-}"
case "$ACTION" in
    deploy)   do_deploy ;;
    delete)   do_delete ;;
    redeploy) do_delete; sleep 5; do_deploy ;;
    logs)     do_logs ;;
    check)    do_check ;;
    *)
        echo -e "${YELLOW}monitoring.sh — Quản lý Monitoring (Prometheus + Grafana)${NC}"
        echo ""
        echo "Cú pháp: $0 <action>"
        echo ""
        echo "Actions:"
        echo -e "  ${GREEN}deploy${NC}       Deploy / Upgrade"
        echo -e "  ${RED}delete${NC}       Force xóa"
        echo -e "  ${YELLOW}redeploy${NC}     Delete + Deploy lại sạch"
        echo -e "  ${CYAN}logs${NC}         Tail logs Grafana"
        echo -e "  ${CYAN}check${NC}        Health check Monitoring stack"
        ;;
esac
