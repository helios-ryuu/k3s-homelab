#!/bin/bash
# =================================================================
# mon-check.sh — Kiểm tra sức khỏe Monitoring Stack
# =================================================================
# Sử dụng: bash ./mon-check.sh
# =================================================================
# Kiểm tra:
#   1. Pod status (Prometheus, Grafana, Operator, KSM, Node-Exporter, Alloy, Loki)
#   2. Prometheus targets & rules
#   3. Grafana login & datasources
#   4. Loki readiness & push test
#   5. Alloy DaemonSet + Node-Exporter coverage
# =================================================================

MON_NS="monitoring"
LOG_NS="logging"
MASTER_IP=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || \
            kubectl get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || \
            kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || \
            echo "127.0.0.1")
PROM_URL="http://${MASTER_IP}:30090"
GRAFANA_URL="http://${MASTER_IP}:30300"
LOKI_URL="http://${MASTER_IP}:30100"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0; FAIL=0; WARN=0

ok()   { echo -e "  ${GREEN}✔${NC} $*"; ((PASS++)); }
fail() { echo -e "  ${RED}✘${NC} $*"; ((FAIL++)); }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; ((WARN++)); }
hdr()  { echo -e "\n${BOLD}--- $* ---${NC}"; }

# ======================== 1/5 POD STATUS ========================

hdr "1/5  POD STATUS"

check_deploy() {
    local ns="$1" name="$2" label="$3"
    local line
    line=$(kubectl get pods -n "$ns" -l "$label" --no-headers 2>/dev/null | head -1)
    if [ -z "$line" ]; then
        fail "$name — pod MISSING"
        return 1
    fi
    local pod_name=$(echo "$line" | awk '{print $1}')
    local ready=$(echo "$line" | awk '{print $2}')
    local status=$(echo "$line" | awk '{print $3}')
    local node=$(kubectl get pod -n "$ns" "$pod_name" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
    if [ "$status" = "Running" ]; then
        ok "$name — $ready $status ($node)"
        return 0
    elif [ "$status" = "Pending" ]; then
        warn "$name — Pending ($node)"
        return 1
    else
        fail "$name — $status ($node)"
        return 1
    fi
}

check_deploy "$MON_NS" "Prometheus" "app.kubernetes.io/name=prometheus"
PROM_OK=$?
check_deploy "$MON_NS" "Grafana" "app.kubernetes.io/name=grafana"
GRAFANA_OK=$?
check_deploy "$MON_NS" "Prometheus Operator" "app.kubernetes.io/name=kube-prometheus-stack-prometheus-operator"
check_deploy "$MON_NS" "Kube State Metrics" "app.kubernetes.io/name=kube-state-metrics"

# Node exporter (DaemonSet)
NE_DESIRED=$(kubectl get ds -n "$MON_NS" -l app.kubernetes.io/name=prometheus-node-exporter -o jsonpath='{.items[0].status.desiredNumberScheduled}' 2>/dev/null)
NE_READY=$(kubectl get ds -n "$MON_NS" -l app.kubernetes.io/name=prometheus-node-exporter -o jsonpath='{.items[0].status.numberReady}' 2>/dev/null)
if [ -n "$NE_DESIRED" ] && [ "$NE_READY" = "$NE_DESIRED" ]; then
    ok "Node Exporter — $NE_READY/$NE_DESIRED Ready"
elif [ -n "$NE_DESIRED" ]; then
    warn "Node Exporter — $NE_READY/$NE_DESIRED Ready (một số nodes offline?)"
else
    fail "Node Exporter — DaemonSet MISSING"
fi

# Alloy (DaemonSet, logging namespace)
ALLOY_DESIRED=$(kubectl get ds -n "$LOG_NS" -l app=alloy -o jsonpath='{.items[0].status.desiredNumberScheduled}' 2>/dev/null)
ALLOY_READY=$(kubectl get ds -n "$LOG_NS" -l app=alloy -o jsonpath='{.items[0].status.numberReady}' 2>/dev/null)
if [ -n "$ALLOY_DESIRED" ] && [ "$ALLOY_READY" = "$ALLOY_DESIRED" ]; then
    ok "Alloy (logging) — $ALLOY_READY/$ALLOY_DESIRED Ready"
elif [ -n "$ALLOY_DESIRED" ]; then
    warn "Alloy (logging) — $ALLOY_READY/$ALLOY_DESIRED Ready"
else
    fail "Alloy (logging) — DaemonSet MISSING"
fi

check_deploy "$LOG_NS" "Loki" "app=loki"
LOKI_OK=$?

# ======================== 2/5 PROMETHEUS ========================

hdr "2/5  PROMETHEUS"

if [ "$PROM_OK" -eq 0 ]; then
    # Check readiness
    PROM_READY=$(curl -sf --max-time 5 "$PROM_URL/-/ready" 2>/dev/null)
    if echo "$PROM_READY" | grep -qi "ready\|ok" 2>/dev/null; then
        ok "Prometheus readiness: OK"
    else
        fail "Prometheus readiness: NOT READY"
    fi

    # Targets summary
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
        if [ "$DOWN" -eq 0 ] 2>/dev/null; then
            ok "Targets: $UP/$TOTAL up"
        else
            warn "Targets: $UP up, $DOWN down, $UNKNOWN unknown (total $TOTAL)"
            echo "$ACTIVE" | grep "^DOWN:" | while IFS=: read -r _ job inst err; do
                echo -e "    ↳ ${RED}DOWN${NC}: $job ($inst) — $err"
            done
        fi
    else
        fail "Prometheus targets API: không phản hồi"
    fi

    # Rules
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
        ok "Rules: $R_RULES rules in $R_GROUPS groups"
    fi
else
    warn "Skip Prometheus checks (pod not running)"
fi

# ======================== 3/5 GRAFANA ========================

hdr "3/5  GRAFANA"

if [ "$GRAFANA_OK" -eq 0 ]; then
    # Check login page
    GRAFANA_RESP=$(curl -sf --max-time 5 -o /dev/null -w "%{http_code}" "$GRAFANA_URL/api/health" 2>/dev/null)
    if [ "$GRAFANA_RESP" = "200" ]; then
        ok "Grafana API health: 200 OK"
    else
        fail "Grafana API health: HTTP $GRAFANA_RESP"
    fi

    # Check datasources (needs auth, try anonymous)
    DS_RESP=$(curl -sf --max-time 5 "$GRAFANA_URL/api/datasources" 2>/dev/null)
    if [ -n "$DS_RESP" ] && echo "$DS_RESP" | python3 -c "import sys,json; json.load(sys.stdin)" &>/dev/null; then
        DS_COUNT=$(echo "$DS_RESP" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)
        ok "Datasources: $DS_COUNT configured"
    else
        warn "Datasources: không thể kiểm tra (cần auth hoặc anonymous disabled)"
    fi

    # External access
    GRAFANA_EXT=$(curl -sf --max-time 5 -o /dev/null -w "%{http_code}" "https://grafana.<your-domain>" 2>/dev/null)
    if [ "$GRAFANA_EXT" = "200" ] || [ "$GRAFANA_EXT" = "302" ]; then
        ok "External (grafana.<your-domain>): UP (HTTP $GRAFANA_EXT)"
    else
        warn "External (grafana.<your-domain>): HTTP $GRAFANA_EXT (Cloudflare tunnel?)"
    fi
else
    warn "Skip Grafana checks (pod not running)"
fi

# ======================== 4/5 LOKI ========================

hdr "4/5  LOKI"

if [ "$LOKI_OK" -eq 0 ]; then
    # Readiness
    LOKI_READY=$(curl -sf --max-time 5 "$LOKI_URL/ready" 2>/dev/null)
    if echo "$LOKI_READY" | grep -qi "ready" 2>/dev/null; then
        ok "Loki readiness: OK"
    else
        fail "Loki readiness: NOT READY"
    fi

    # Check labels (proves data ingestion)
    LABELS=$(curl -sf --max-time 5 "$LOKI_URL/loki/api/v1/labels" 2>/dev/null)
    if [ -n "$LABELS" ]; then
        LABEL_COUNT=$(echo "$LABELS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data',[])))" 2>/dev/null)
        if [ "${LABEL_COUNT:-0}" -gt 0 ]; then
            ok "Loki labels: $LABEL_COUNT (data ingestion working)"
        else
            warn "Loki labels: 0 (chưa có log nào?)"
        fi
    else
        fail "Loki API: không phản hồi"
    fi

    # Query test: last 5 minutes logs count
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
            ok "Loki query test: $STREAMS stream(s) (logs flowing)"
        else
            warn "Loki query test: 0 streams (không có logs trong 5 phút gần)"
        fi
    fi
else
    warn "Skip Loki checks (pod not running)"
fi

# ======================== 5/5 NODE COVERAGE ========================

hdr "5/5  NODE COVERAGE"

TOTAL_NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready")

ok "Nodes: $READY_NODES/$TOTAL_NODES Ready"

# Check that every Ready node has a node-exporter pod
READY_NODE_LIST=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"{print $1}')
MISSING_NE=""
for node in $READY_NODE_LIST; do
    NE_POD=$(kubectl get pods -n "$MON_NS" --field-selector spec.nodeName="$node" -l app.kubernetes.io/name=prometheus-node-exporter --no-headers 2>/dev/null | grep Running)
    if [ -z "$NE_POD" ]; then
        MISSING_NE+="$node "
    fi
done

if [ -z "$MISSING_NE" ]; then
    ok "Node-Exporter: coverage 100% (mỗi Ready node có 1 pod)"
else
    warn "Node-Exporter: thiếu trên node(s): $MISSING_NE"
fi

# Check Alloy coverage on Ready nodes
MISSING_ALLOY=""
for node in $READY_NODE_LIST; do
    ALLOY_POD=$(kubectl get pods -n "$LOG_NS" --field-selector spec.nodeName="$node" -l app=alloy --no-headers 2>/dev/null | grep Running)
    if [ -z "$ALLOY_POD" ]; then
        MISSING_ALLOY+="$node "
    fi
done

if [ -z "$MISSING_ALLOY" ]; then
    ok "Alloy: coverage 100% (mỗi Ready node có 1 pod)"
else
    warn "Alloy: thiếu trên node(s): $MISSING_ALLOY"
fi

# ======================== SUMMARY ========================

echo ""
echo -e "${BOLD}═══════════════════════════════════════${NC}"
echo -e "  Kết quả: ${GREEN}${PASS} passed${NC}  ${YELLOW}${WARN} warnings${NC}  ${RED}${FAIL} failed${NC}"
if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
    echo -e "  Trạng thái: ${GREEN}TẤT CẢ OK${NC}"
elif [ "$FAIL" -eq 0 ]; then
    echo -e "  Trạng thái: ${YELLOW}CÓ CẢNH BÁO${NC}"
else
    echo -e "  Trạng thái: ${RED}CÓ LỖI${NC}"
fi
echo -e "${BOLD}═══════════════════════════════════════${NC}"









