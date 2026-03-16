#!/bin/bash
# =================================================================
# localstack.sh — Manage LocalStack Pro
# =================================================================
# Usage:
#   bash localstack.sh deploy          Deploy / Upgrade
#   bash localstack.sh delete          Force delete
#   bash localstack.sh redeploy        Delete + Deploy
#   bash localstack.sh logs            Tail logs
#   bash localstack.sh check           Health check
# =================================================================

source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

LS_NS="localstack"

# ======================== DEPLOY ========================

do_deploy() {
    info "Deploy LocalStack Pro → namespace: $LS_NS"

    # Verify the Pro image is reachable before pulling (saves time on bad tokens/network)
    local ls_image ls_tag
    ls_image=$(grep 'repository:' "$K3S_DIR/services/localstack/values.yaml" | head -1 | awk '{print $2}')
    ls_tag=$(grep '  tag:' "$K3S_DIR/services/localstack/values.yaml" | head -1 | awk '{print $2}' | tr -d '"')
    info "Checking image ${ls_image}:${ls_tag} on registry..."
    if timeout 15 docker manifest inspect "${ls_image}:${ls_tag}" &>/dev/null; then
        ok "Image ${ls_image}:${ls_tag} accessible (pullPolicy:Always → will pull on deploy)"
    else
        warn "Cannot reach ${ls_image}:${ls_tag} — registry unreachable or image missing"
        echo -e "      ${CYAN}Manual check: docker manifest inspect ${ls_image}:${ls_tag}${NC}"
        read -p "      Continue deploy anyway? (y/N): " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            warn "Deploy cancelled."
            return 1
        fi
    fi

    check_node_labels localstack
    if ! check_secrets localstack "$LS_NS" quiet; then
        bash "$K3S_DIR/init-sec.sh" "$LS_NS"
    fi
    check_secrets localstack "$LS_NS"

    # Verify target node is Ready before deploying
    local target_node
    target_node=$(kubectl get nodes -l node-role.kubernetes.io/localstack -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "$target_node" ]; then
        target_node=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    fi

    if [ -n "$target_node" ]; then
        local node_status
        node_status=$(kubectl get node "$target_node" --no-headers 2>/dev/null | awk '{print $2}')
        if [ "$node_status" != "Ready" ]; then
            warn "Node $target_node not Ready (status: ${node_status:-NotFound})"
            read -p "      Continue? (y/N): " confirm
            if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
                warn "Deploy cancelled."
                return 1
            fi
        else
            ok "Node $target_node: Ready"
        fi
    fi

    if release_exists localstack $LS_NS; then
        ok "(Upgrading existing release)"
        helm upgrade localstack localstack/localstack \
            -f "$K3S_DIR/services/localstack/values.yaml" -n $LS_NS $HELM_TIMEOUT
    else
        helm install localstack localstack/localstack \
            -f "$K3S_DIR/services/localstack/values.yaml" \
            -n $LS_NS --create-namespace $HELM_TIMEOUT
    fi

    wait_for_ready $LS_NS

    local ls_node_ip
    ls_node_ip=$(kubectl get nodes -l node-role.kubernetes.io/localstack \
        -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || \
        kubectl get nodes -l node-role.kubernetes.io/control-plane \
        -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || \
        echo "127.0.0.1")

    ok "LocalStack API (external): http://${ls_node_ip}:30566"
    ok "LocalStack API (cluster):  http://localstack.localstack.svc.cluster.local:4566"
    echo ""
    echo -e "  ${CYAN}Quick test (from any node):${NC}"
    echo "    awslocal --endpoint-url=http://${ls_node_ip}:30566 s3 ls"
    echo "    awslocal --endpoint-url=http://${ls_node_ip}:30566 dynamodb list-tables"
}

# ======================== DELETE ========================

do_delete() {
    info "Force deleting LocalStack..."
    helm uninstall localstack -n $LS_NS 2>/dev/null
    force_cleanup_ns $LS_NS
}

# ======================== LOGS ========================

do_logs() {
    kubectl logs -f -n $LS_NS -l app.kubernetes.io/name=localstack --tail=100
}

# ======================== CHECK ========================

do_check() {
    check_reset
    local LS_NODE_IP LS_EXTERNAL
    LS_NODE_IP=$(get_master_ip)
    LS_EXTERNAL="${LS_NODE_IP}:30566"

    # ==============================================================
    hdr "1/5  POD STATUS"
    # ==============================================================

    local POD_LINE POD_NAME POD_READY POD_STATUS POD_NODE
    POD_LINE=$(kubectl get pods -n "$LS_NS" -l app.kubernetes.io/name=localstack --no-headers 2>/dev/null | head -1)

    if [ -z "$POD_LINE" ]; then
        chk_fail "LocalStack pod not found — run 'bash localstack.sh deploy'"
        check_summary
        return
    fi

    POD_NAME=$(echo "$POD_LINE" | awk '{print $1}')
    POD_READY=$(echo "$POD_LINE" | awk '{print $2}')
    POD_STATUS=$(echo "$POD_LINE" | awk '{print $3}')
    POD_NODE=$(kubectl get pod -n "$LS_NS" "$POD_NAME" -o jsonpath='{.spec.nodeName}' 2>/dev/null)

    if [ "$POD_STATUS" = "Running" ]; then
        chk_ok "LocalStack: $POD_NAME — $POD_READY $POD_STATUS ($POD_NODE)"
    elif [ "$POD_STATUS" = "Pending" ]; then
        chk_warn "LocalStack: $POD_NAME — Pending ($POD_NODE)"
        chk_warn "Node may be offline or PVC not bound yet"
        check_summary
        return
    else
        chk_fail "LocalStack: $POD_NAME — $POD_STATUS ($POD_NODE)"
    fi

    # DinD sidecar must be Ready for Lambda to work
    local DIND_STATUS
    DIND_STATUS=$(kubectl get pod -n "$LS_NS" "$POD_NAME" \
        -o jsonpath='{.status.containerStatuses[?(@.name=="dind")].ready}' 2>/dev/null)
    if [ "$DIND_STATUS" = "true" ]; then
        chk_ok "DinD sidecar: Ready (Lambda execution available)"
    elif [ -n "$DIND_STATUS" ]; then
        chk_warn "DinD sidecar: Not Ready — Lambda functions will fail"
    else
        chk_warn "DinD sidecar: not found (mountDind may be disabled)"
    fi

    # ==============================================================
    hdr "2/5  API HEALTH"
    # ==============================================================

    local HEALTH_JSON
    HEALTH_JSON=$(kubectl exec -n "$LS_NS" "$POD_NAME" -c localstack -- \
        curl -sf --max-time 10 "http://localhost:4566/_localstack/health" 2>/dev/null)

    if [ -n "$HEALTH_JSON" ]; then
        chk_ok "Health endpoint: OK"

        local VERSION EDITION
        VERSION=$(echo "$HEALTH_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null)
        [ -n "$VERSION" ] && chk_ok "Version: $VERSION"

        EDITION=$(echo "$HEALTH_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('edition','community'))" 2>/dev/null)
        if [ "$EDITION" = "pro" ]; then
            chk_ok "Edition: Pro (license active)"
        else
            chk_warn "Edition: ${EDITION:-unknown} — Pro license may not be active. Check LOCALSTACK_AUTH_TOKEN in infra-secrets."
        fi
    else
        chk_fail "Health endpoint not responding — pod may still be starting (allow 30-60s)"
    fi

    # External reachability via Tailscale
    if curl -sf --max-time 5 "http://$LS_EXTERNAL/_localstack/health" &>/dev/null; then
        chk_ok "External ($LS_EXTERNAL): reachable"
    else
        chk_warn "External ($LS_EXTERNAL): unreachable (check NodePort or Tailscale)"
    fi

    # ==============================================================
    hdr "3/5  SERVICES STATUS"
    # ==============================================================

    if [ -n "$HEALTH_JSON" ]; then
        local SERVICES
        SERVICES=$(echo "$HEALTH_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
svcs = d.get('services', {})
enabled = {k: v for k, v in svcs.items() if v != 'disabled'}
disabled_count = len(svcs) - len(enabled)
print(f'__SUMMARY__ {len(enabled)} {disabled_count}')
for name, status in sorted(enabled.items()):
    print(f'{name} {status}')
" 2>/dev/null)

        if [ -n "$SERVICES" ]; then
            local ENABLED_COUNT DISABLED_COUNT
            ENABLED_COUNT=$(echo "$SERVICES" | grep "^__SUMMARY__" | awk '{print $2}')
            DISABLED_COUNT=$(echo "$SERVICES" | grep "^__SUMMARY__" | awk '{print $3}')
            echo -e "  ${CYAN}Enabled: $ENABLED_COUNT | Disabled/not-started: $DISABLED_COUNT${NC}"

            while IFS=' ' read -r svc_name svc_status; do
                [ -z "$svc_name" ] && continue
                case "$svc_status" in
                    running|available) chk_ok "$svc_name: $svc_status" ;;
                    starting)          chk_warn "$svc_name: $svc_status (still initializing)" ;;
                    error)             chk_fail "$svc_name: $svc_status" ;;
                    *)                 chk_warn "$svc_name: $svc_status" ;;
                esac
            done < <(echo "$SERVICES" | grep -v "^__SUMMARY__")
        else
            chk_warn "Could not parse services from health response"
        fi
    else
        chk_warn "Skip — API not responding"
    fi

    # ==============================================================
    hdr "4/5  LAMBDA / DIND CHECK"
    # ==============================================================

    # Verify LocalStack can reach the DinD daemon (prerequisite for Lambda)
    # Uses curl against the Docker API (port 2375) — LocalStack image has no docker CLI.
    local DOCKER_OK
    DOCKER_OK=$(kubectl exec -n "$LS_NS" "$POD_NAME" -c localstack -- \
        curl -sf --max-time 5 "http://localhost:2375/info" 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('ServerVersion',''))" 2>/dev/null)
    if [ -n "$DOCKER_OK" ]; then
        chk_ok "Docker daemon reachable from LocalStack (version: $DOCKER_OK)"
        chk_ok "Lambda execution: ready (DinD connected)"
    else
        chk_fail "Docker daemon NOT reachable — Lambda will fail. Check DinD sidecar and DOCKER_HOST env."
    fi

    # ==============================================================
    hdr "5/5  SMOKE TESTS (S3 · DynamoDB · SQS · SNS · Secrets Manager)"
    # ==============================================================

    local _exec="kubectl exec -n $LS_NS $POD_NAME -c localstack --"

    # S3 — create and delete a bucket
    local S3_OUT
    S3_OUT=$($_exec awslocal s3 mb s3://healthcheck-smoke-test 2>&1)
    if echo "$S3_OUT" | grep -q "make_bucket\|already"; then
        chk_ok "S3: create bucket OK"
        $_exec awslocal s3 rb s3://healthcheck-smoke-test &>/dev/null
        chk_ok "S3: delete bucket OK"
    else
        chk_fail "S3: FAILED — $S3_OUT"
    fi

    # DynamoDB — create table, put item, get item, delete table
    local DDB_OUT
    DDB_OUT=$($_exec awslocal dynamodb create-table \
        --table-name healthcheck-smoke-test \
        --attribute-definitions AttributeName=pk,AttributeType=S \
        --key-schema AttributeName=pk,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST 2>&1)
    if echo "$DDB_OUT" | grep -q "TableDescription\|ResourceInUseException"; then
        chk_ok "DynamoDB: create table OK"
        $_exec awslocal dynamodb put-item \
            --table-name healthcheck-smoke-test \
            --item '{"pk":{"S":"test-key"},"val":{"S":"test-value"}}' &>/dev/null
        local DDB_GET
        DDB_GET=$($_exec awslocal dynamodb get-item \
            --table-name healthcheck-smoke-test \
            --key '{"pk":{"S":"test-key"}}' 2>/dev/null)
        if echo "$DDB_GET" | grep -q "test-value"; then
            chk_ok "DynamoDB: put/get item OK"
        else
            chk_warn "DynamoDB: get-item returned unexpected result"
        fi
        $_exec awslocal dynamodb delete-table --table-name healthcheck-smoke-test &>/dev/null
        chk_ok "DynamoDB: delete table OK"
    else
        chk_fail "DynamoDB: FAILED — $DDB_OUT"
    fi

    # SQS — create and delete queue
    local SQS_OUT
    SQS_OUT=$($_exec awslocal sqs create-queue --queue-name healthcheck-smoke-test 2>&1)
    if echo "$SQS_OUT" | grep -q "QueueUrl"; then
        chk_ok "SQS: create queue OK"
        local QUEUE_URL
        QUEUE_URL=$(echo "$SQS_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['QueueUrl'])" 2>/dev/null)
        [ -n "$QUEUE_URL" ] && $_exec awslocal sqs delete-queue --queue-url "$QUEUE_URL" &>/dev/null
        chk_ok "SQS: delete queue OK"
    else
        chk_fail "SQS: FAILED — $SQS_OUT"
    fi

    # SNS — create and delete topic
    local SNS_OUT
    SNS_OUT=$($_exec awslocal sns create-topic --name healthcheck-smoke-test 2>&1)
    if echo "$SNS_OUT" | grep -q "TopicArn"; then
        chk_ok "SNS: create topic OK"
        local TOPIC_ARN
        TOPIC_ARN=$(echo "$SNS_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['TopicArn'])" 2>/dev/null)
        [ -n "$TOPIC_ARN" ] && $_exec awslocal sns delete-topic --topic-arn "$TOPIC_ARN" &>/dev/null
        chk_ok "SNS: delete topic OK"
    else
        chk_fail "SNS: FAILED — $SNS_OUT"
    fi

    # Secrets Manager — create and delete secret
    local SEC_OUT
    SEC_OUT=$($_exec awslocal secretsmanager create-secret \
        --name healthcheck-smoke-test \
        --secret-string '{"test":"value"}' 2>&1)
    if echo "$SEC_OUT" | grep -q "ARN\|healthcheck-smoke-test"; then
        chk_ok "Secrets Manager: create secret OK"
        $_exec awslocal secretsmanager delete-secret \
            --secret-id healthcheck-smoke-test --force-delete-without-recovery &>/dev/null
        chk_ok "Secrets Manager: delete secret OK"
    else
        chk_fail "Secrets Manager: FAILED — $SEC_OUT"
    fi

    check_summary

    if [ "$FAIL" -gt 0 ]; then
        echo ""
        echo -e "  ${CYAN}Troubleshooting:${NC}"
        echo "    Pod missing:          bash localstack.sh deploy"
        echo "    API not responding:   pod may still be starting (allow 30-60s)"
        echo "    Edition not Pro:      check LOCALSTACK_AUTH_TOKEN in infra-secrets"
        echo "    Lambda/DinD fail:     do NOT set DOCKER_HOST in values.yaml (chart auto-sets it)"
        echo "    S3/DDB/SQS fail:      service may not be initialized yet — retry in ~1 min"
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
        echo -e "${YELLOW}localstack.sh — Manage LocalStack Pro${NC}"
        echo ""
        echo "Usage: $0 <action>"
        echo ""
        echo "Actions:"
        echo -e "  ${GREEN}deploy${NC}       Deploy / Upgrade"
        echo -e "  ${RED}delete${NC}       Force delete"
        echo -e "  ${YELLOW}redeploy${NC}     Delete + re-deploy clean"
        echo -e "  ${CYAN}logs${NC}         Tail logs"
        echo -e "  ${CYAN}check${NC}        Health check (API + services + smoke tests)"
        ;;
esac
