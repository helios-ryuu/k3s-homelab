#!/bin/bash
# =================================================================
# init-sec.sh — Khoi tao infra-secrets va redshark-secrets
# =================================================================
# Su dung:
#   ./init-sec.sh                  Ap dung cho tat ca namespace
#   ./init-sec.sh <namespace>      Chi ap dung mot namespace
# =================================================================

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# ======================== LOAD .env ========================

load_env() {
    local ENV_FILE="$K3S_DIR/.env"
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
    else
        warn ".env not found — using PLACEHOLDER values"
    fi

    # infra-secrets
    [ -z "$CLOUDFLARE_TOKEN" ]        && CLOUDFLARE_TOKEN="PLACEHOLDER_CF_TOKEN"
    [ -z "$LOCALSTACK_TOKEN" ]        && LOCALSTACK_TOKEN="PLACEHOLDER_LS_TOKEN"
    [ -z "$GRAFANA_ADMIN_PASSWORD" ]  && GRAFANA_ADMIN_PASSWORD="PLACEHOLDER_GRAFANA_PASSWORD"
    [ -z "$MSSQL_PASSWORD" ]          && MSSQL_PASSWORD="PLACEHOLDER_MSSQL_PASSWORD"
    [ -z "$ORACLE_PASSWORD" ]         && ORACLE_PASSWORD="PLACEHOLDER_ORACLE_PASSWORD"
    [ -z "$SURE_POSTGRES_PASSWORD" ]  && SURE_POSTGRES_PASSWORD="PLACEHOLDER_SURE_POSTGRES_PASSWORD"

    # redshark-secrets
    [ -z "$REDSHARK_DB_USERNAME" ]    && REDSHARK_DB_USERNAME="PLACEHOLDER_REDSHARK_DB_USERNAME"
    [ -z "$REDSHARK_DB_PASSWORD" ]    && REDSHARK_DB_PASSWORD="PLACEHOLDER_REDSHARK_DB_PASSWORD"
}

# ======================== INFRA-SECRETS ========================
# Shared secret applied to: cloudflared, localstack, monitoring,
#                           mssql, oracle, sure, kube-system

INFRA_NAMESPACES=("cloudflared" "localstack" "monitoring" "mssql" "oracle" "sure" "kube-system")

do_infra_secret() {
    local ns="$1"
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - &>/dev/null

    # Preserve sure-secret-key-base across runs to avoid invalidating sessions
    local SURE_KEY=""
    if kubectl get secret infra-secrets -n "$ns" &>/dev/null; then
        SURE_KEY=$(kubectl get secret infra-secrets -n "$ns" \
            -o jsonpath='{.data.sure-secret-key-base}' | base64 -d 2>/dev/null)
    fi
    [ -z "$SURE_KEY" ] && SURE_KEY=$(head -c 64 /dev/urandom | od -An -tx1 | tr -d " \n")

    kubectl create secret generic infra-secrets \
        --from-literal=cloudflare-token="$CLOUDFLARE_TOKEN" \
        --from-literal=localstack-token="$LOCALSTACK_TOKEN" \
        --from-literal=grafana-admin-password="$GRAFANA_ADMIN_PASSWORD" \
        --from-literal=admin-user="admin" \
        --from-literal=admin-password="$GRAFANA_ADMIN_PASSWORD" \
        --from-literal=mssql-password="$MSSQL_PASSWORD" \
        --from-literal=oracle-password="$ORACLE_PASSWORD" \
        --from-literal=sure-secret-key-base="$SURE_KEY" \
        --from-literal=sure-postgres-password="$SURE_POSTGRES_PASSWORD" \
        -n "$ns" --dry-run=client -o yaml | kubectl apply -f - &>/dev/null

    ok "[$ns] infra-secrets READY"
}

# ======================== REDSHARK-SECRETS ========================
# Separate secret for redshark namespace only

do_redshark_secret() {
    local ns="redshark"
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - &>/dev/null

    kubectl create secret generic redshark-secrets \
        --from-literal=db-username="$REDSHARK_DB_USERNAME" \
        --from-literal=db-password="$REDSHARK_DB_PASSWORD" \
        -n "$ns" --dry-run=client -o yaml | kubectl apply -f - &>/dev/null

    ok "[$ns] redshark-secrets READY"
}

# ======================== MAIN ========================

do_secrets() {
    local target_ns="$1"
    load_env
    info "Khoi tao / Cap nhat secrets..."

    if [ -z "$target_ns" ] || [ "$target_ns" = "redshark" ]; then
        do_redshark_secret
    fi

    for ns in "${INFRA_NAMESPACES[@]}"; do
        if [ -n "$target_ns" ] && [ "$ns" != "$target_ns" ]; then
            continue
        fi
        do_infra_secret "$ns"
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    do_secrets "$1"
fi
