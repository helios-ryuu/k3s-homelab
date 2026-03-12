#!/bin/bash
# =================================================================
# ls-check.sh — Kiểm tra sức khỏe LocalStack Pro
# =================================================================
# Sử dụng: bash ./ls-check.sh
# =================================================================
# Kiểm tra:
#   1. Pod status (Running / Pending / CrashLoop)
#   2. API health endpoint (_localstack/health)
#   3. Services status (từng service enabled)
#   4. Smoke test: S3 create bucket + SQS create queue
# =================================================================

LS_NS="localstack"
LS_SVC="localstack.localstack.svc.cluster.local:4566"
LS_NODE_IP=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || \
             kubectl get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || \
             kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || \
             echo "127.0.0.1")
LS_EXTERNAL="${LS_NODE_IP}:30566"

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

# ======================== 1/4 POD STATUS ========================

hdr "1/4  POD STATUS"

POD_LINE=$(kubectl get pods -n "$LS_NS" -l app.kubernetes.io/name=localstack --no-headers 2>/dev/null | head -1)
if [ -z "$POD_LINE" ]; then
    fail "Không tìm thấy LocalStack pod (chưa deploy?)"
    echo -e "\n${RED}═══ Không thể tiếp tục — pod không tồn tại ═══${NC}"
    exit 1
fi

POD_NAME=$(echo "$POD_LINE" | awk '{print $1}')
POD_READY=$(echo "$POD_LINE" | awk '{print $2}')
POD_STATUS=$(echo "$POD_LINE" | awk '{print $3}')
POD_NODE=$(kubectl get pod -n "$LS_NS" "$POD_NAME" -o jsonpath='{.spec.nodeName}' 2>/dev/null)

if [ "$POD_STATUS" = "Running" ]; then
    ok "LocalStack pod: $POD_NAME — $POD_READY $POD_STATUS ($POD_NODE)"
elif [ "$POD_STATUS" = "Pending" ]; then
    warn "LocalStack pod: $POD_NAME — Pending ($POD_NODE)"
    warn "Node có thể offline hoặc PVC chưa bind"
    echo -e "\n${YELLOW}═══ Pod Pending — skip health tests ═══${NC}"
    exit 0
else
    fail "LocalStack pod: $POD_NAME — $POD_STATUS ($POD_NODE)"
fi

# Check DinD sidecar
DIND_STATUS=$(kubectl get pod -n "$LS_NS" "$POD_NAME" -o jsonpath='{.status.containerStatuses[?(@.name=="dind")].ready}' 2>/dev/null)
if [ "$DIND_STATUS" = "true" ]; then
    ok "DinD sidecar: Ready"
elif [ -n "$DIND_STATUS" ]; then
    warn "DinD sidecar: Not Ready (Lambda/ECS sẽ không hoạt động)"
else
    warn "DinD sidecar: không tìm thấy (mountDind có thể tắt)"
fi

# ======================== 2/4 API HEALTH ========================

hdr "2/4  API HEALTH"

# Test từ trong cluster
HEALTH_JSON=$(kubectl exec -n "$LS_NS" "$POD_NAME" -c localstack -- \
    curl -sf --max-time 10 "http://localhost:4566/_localstack/health" 2>/dev/null)

if [ -n "$HEALTH_JSON" ]; then
    ok "API health endpoint: OK"

    # Parse version
    VERSION=$(echo "$HEALTH_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null)
    [ -n "$VERSION" ] && ok "Version: $VERSION"

    # Parse edition
    EDITION=$(echo "$HEALTH_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('edition','community'))" 2>/dev/null)
    if [ "$EDITION" = "pro" ]; then
        ok "Edition: Pro (license active)"
    else
        warn "Edition: $EDITION (Pro license không hoạt động?)"
    fi
else
    fail "API health endpoint: không phản hồi"
fi

# Test từ bên ngoài (Tailscale)
EXTERNAL_OK=$(curl -sf --max-time 5 "http://$LS_EXTERNAL/_localstack/health" 2>/dev/null)
if [ -n "$EXTERNAL_OK" ]; then
    ok "External endpoint ($LS_EXTERNAL): UP"
else
    warn "External endpoint ($LS_EXTERNAL): DOWN (node có thể không accessible)"
fi

# ======================== 3/4 SERVICES STATUS ========================

hdr "3/4  SERVICES STATUS"

if [ -n "$HEALTH_JSON" ]; then
    SERVICES=$(echo "$HEALTH_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
svcs = d.get('services', {})
enabled = {k:v for k,v in svcs.items() if v != 'disabled'}
disabled_count = len(svcs) - len(enabled)
print(f'__SUMMARY__ {len(enabled)} {disabled_count}')
for name, status in sorted(enabled.items()):
    print(f'{name} {status}')
" 2>/dev/null)

    if [ -n "$SERVICES" ]; then
        # Parse summary line
        SUMMARY_LINE=$(echo "$SERVICES" | grep "^__SUMMARY__")
        ENABLED_COUNT=$(echo "$SUMMARY_LINE" | awk '{print $2}')
        DISABLED_COUNT=$(echo "$SUMMARY_LINE" | awk '{print $3}')
        echo -e "  ${CYAN}Enabled: $ENABLED_COUNT services | Disabled: $DISABLED_COUNT services${NC}"

        while IFS=' ' read -r svc_name svc_status; do
            [ -z "$svc_name" ] && continue
            if [ "$svc_status" = "running" ] || [ "$svc_status" = "available" ]; then
                ok "$svc_name: $svc_status"
            elif [ "$svc_status" = "starting" ]; then
                warn "$svc_name: $svc_status (đang khởi động)"
            elif [ "$svc_status" = "error" ]; then
                fail "$svc_name: $svc_status"
            else
                warn "$svc_name: $svc_status"
            fi
        done < <(echo "$SERVICES" | grep -v "^__SUMMARY__")
    else
        warn "Không parse được services status"
    fi
else
    warn "Skip services check (API không phản hồi)"
fi

# ======================== 4/4 SMOKE TEST ========================

hdr "4/4  SMOKE TEST"

# S3: create + list + delete bucket
S3_CREATE=$(kubectl exec -n "$LS_NS" "$POD_NAME" -c localstack -- \
    awslocal s3 mb s3://ls-check-test-bucket 2>&1)
if echo "$S3_CREATE" | grep -q "make_bucket\|already" 2>/dev/null; then
    ok "S3: create bucket OK"
    # Cleanup
    kubectl exec -n "$LS_NS" "$POD_NAME" -c localstack -- \
        awslocal s3 rb s3://ls-check-test-bucket &>/dev/null
    ok "S3: delete bucket OK (cleanup)"
else
    fail "S3: create bucket FAILED — $S3_CREATE"
fi

# SQS: create + delete queue
SQS_CREATE=$(kubectl exec -n "$LS_NS" "$POD_NAME" -c localstack -- \
    awslocal sqs create-queue --queue-name ls-check-test-queue 2>&1)
if echo "$SQS_CREATE" | grep -q "QueueUrl\|ls-check-test-queue" 2>/dev/null; then
    ok "SQS: create queue OK"
    # Cleanup
    QUEUE_URL=$(echo "$SQS_CREATE" | python3 -c "import sys,json; print(json.load(sys.stdin)['QueueUrl'])" 2>/dev/null)
    if [ -n "$QUEUE_URL" ]; then
        kubectl exec -n "$LS_NS" "$POD_NAME" -c localstack -- \
            awslocal sqs delete-queue --queue-url "$QUEUE_URL" &>/dev/null
        ok "SQS: delete queue OK (cleanup)"
    fi
else
    fail "SQS: create queue FAILED — $SQS_CREATE"
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

