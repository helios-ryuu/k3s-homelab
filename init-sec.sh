#!/bin/bash
# =================================================================
# init-sec.sh — Khoi tao infra-secrets cho tat ca namespaces
# =================================================================

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

do_secrets() {
    local target_ns="$1"
    info "Khoi tao / Cap nhat infra-secrets..."

    # 1. Lay bien tu .env
    local ENV_FILE="$K3S_DIR/.env"
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
    fi
    # Neu khong co, dung placeholder de tranh loi cu phap lenh kubectl
    [ -z "$CLOUDFLARE_TOKEN" ] && CLOUDFLARE_TOKEN="PLACEHOLDER_CF_TOKEN"
    [ -z "$LOCALSTACK_TOKEN" ] && LOCALSTACK_TOKEN="PLACEHOLDER_LS_TOKEN"
    [ -z "$GRAFANA_ADMIN_PASSWORD" ] && GRAFANA_ADMIN_PASSWORD="PLACEHOLDER_GRAFANA_PASSWORD"
    [ -z "$MSSQL_PASSWORD" ] && MSSQL_PASSWORD="PLACEHOLDER_MSSQL_PASSWORD"
    [ -z "$ORACLE_PASSWORD" ] && ORACLE_PASSWORD="PLACEHOLDER_ORACLE_PASSWORD"
    [ -z "$SURE_POSTGRES_PASSWORD" ] && SURE_POSTGRES_PASSWORD="PLACEHOLDER_SURE_POSTGRES_PASSWORD"

    # 3. Create secrets cho tung namespace
    local namespaces=("cloudflared" "localstack" "monitoring" "mssql" "oracle" "sure" "kube-system")
    for ns in "${namespaces[@]}"; do
        if [ -n "$target_ns" ] && [ "$ns" != "$target_ns" ]; then
            continue
        fi
        kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - &>/dev/null
        
        # Tao moi hoac lay lai Sure Key Base neu da ton tai de tranh invalidate session
        local SURE_KEY=""
        if kubectl get secret infra-secrets -n "$ns" &>/dev/null; then
            SURE_KEY=$(kubectl get secret infra-secrets -n "$ns" -o jsonpath='{.data.sure-secret-key-base}' | base64 -d 2>/dev/null)
        fi
        [ -z "$SURE_KEY" ] && SURE_KEY=$(head -c 64 /dev/urandom | od -An -tx1 | tr -d " \n")

        kubectl create secret generic infra-secrets \
            --from-literal=cloudflare-token="$CLOUDFLARE_TOKEN" \
            --from-literal=localstack-token="$LOCALSTACK_TOKEN" \
            --from-literal=grafana-admin-password="$GRAFANA_ADMIN_PASSWORD" \
            --from-literal=admin-user='admin' \
            --from-literal=admin-password="$GRAFANA_ADMIN_PASSWORD" \
            --from-literal=mssql-password="$MSSQL_PASSWORD" \
            --from-literal=oracle-password="$ORACLE_PASSWORD" \
            --from-literal=sure-secret-key-base="$SURE_KEY" \
            --from-literal=sure-postgres-password="$SURE_POSTGRES_PASSWORD" \
            -n "$ns" --dry-run=client -o yaml | kubectl apply -f - &>/dev/null
        
        ok "Namespace '$ns': infra-secrets READY"
    done
}

# Cho phep goi truc tiep hoac source tu script khac
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    do_secrets "$1"
fi
