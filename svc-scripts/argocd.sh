#!/bin/bash
# =================================================================
# argocd.sh — ArgoCD Bootstrap Helper
# =================================================================
# Sử dụng:
#   bash argocd.sh install          Install ArgoCD into cluster
#   bash argocd.sh login            Login to ArgoCD CLI
#   bash argocd.sh add-repo         Register k3s-homelab deploy key
#   bash argocd.sh apply-root       Apply root Application (app-of-apps)
#   bash argocd.sh bootstrap        Full bootstrap (install → login → add-repo → apply-root)
# =================================================================
# Yêu cầu:
#   - kubectl, argocd CLI installed
#   - Deploy key at /tmp/argocd-deploy-key (for add-repo)
#   - Cloudflare Tunnel route: argocd.helios.id.vn → argocd-server.argocd.svc.cluster.local:80
# =================================================================

source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

ARGOCD_NS="argocd"
ARGOCD_VERSION="v3.3.4"
ARGOCD_URL="argocd.helios.id.vn"
REPO_URL="git@github.com:helios-ryuu/k3s-homelab.git"
DEPLOY_KEY="/tmp/argocd-deploy-key"

# ======================== INSTALL ========================

do_install() {
    info "Installing ArgoCD $ARGOCD_VERSION → namespace: $ARGOCD_NS"
    kubectl create namespace $ARGOCD_NS 2>/dev/null || true
    kubectl apply -n $ARGOCD_NS --server-side \
        -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

    info "Waiting for argocd-server..."
    kubectl rollout status deployment argocd-server -n $ARGOCD_NS --timeout=120s

    info "Enabling insecure mode (Cloudflare Tunnel terminates TLS)..."
    kubectl patch deployment argocd-server -n $ARGOCD_NS \
        --type=json \
        -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--insecure"}]'

    ok "ArgoCD installed. Next steps:"
    echo "    1. Add Cloudflare Tunnel route: argocd.helios.id.vn → argocd-server.argocd.svc.cluster.local:80"
    echo "    2. Generate deploy key and add to GitHub k3s-homelab repo"
    echo "    3. Run: bash argocd.sh login"
}

# ======================== LOGIN ========================

do_login() {
    info "Fetching initial admin password..."
    local password
    password=$(kubectl get secret argocd-initial-admin-secret -n $ARGOCD_NS \
        -o jsonpath='{.data.password}' | base64 -d)
    if [ -z "$password" ]; then
        err "argocd-initial-admin-secret not found. ArgoCD may not be installed yet."
        exit 1
    fi
    info "Logging in to ArgoCD at $ARGOCD_URL..."
    argocd login "$ARGOCD_URL" --username admin --password "$password" --insecure --grpc-web || {
        err "argocd login failed"
        exit 1
    }
    ok "Logged in. Change the admin password:"
    echo "    argocd account update-password"
}

# ======================== ADD REPO ========================

do_add_repo() {
    if [ ! -f "$DEPLOY_KEY" ]; then
        err "Deploy key not found at $DEPLOY_KEY"
        echo ""
        echo "    Generate a key pair and add the public key to GitHub:"
        echo "      ssh-keygen -t ed25519 -C 'argocd-deploy-key' -f /tmp/argocd-deploy-key -N ''"
        echo "      cat /tmp/argocd-deploy-key.pub"
        echo "      # Add to: github.com/helios-ryuu/k3s-homelab → Settings → Deploy keys"
        exit 1
    fi
    info "Registering k3s-homelab repo..."
    argocd repo add "$REPO_URL" \
        --ssh-private-key-path "$DEPLOY_KEY" \
        --name k3s-homelab \
        --grpc-web
    ok "Repo registered: $REPO_URL"
}

# ======================== APPLY ROOT ========================

do_apply_root() {
    info "Applying root Application (hands control to ArgoCD)..."
    kubectl apply -n $ARGOCD_NS -f "$K3S_DIR/argocd-apps/root.yaml"
    ok "Root Application applied."
    echo ""
    echo "    Sync order (via ArgoCD UI at https://$ARGOCD_URL):"
    echo "      1. cloudflared  2. logging  3. monitoring  4. localstack"
    echo "      5. redshark     6. sure     7. rest"
}

# ======================== BOOTSTRAP ========================

do_bootstrap() {
    do_install
    echo ""
    warn "ACTION REQUIRED: Add Cloudflare Tunnel route for argocd.helios.id.vn before continuing."
    warn "Then press Enter to continue with login..."
    read -r
    do_login
    echo ""
    warn "ACTION REQUIRED: Generate deploy key and add to GitHub before continuing."
    echo "    ssh-keygen -t ed25519 -C 'argocd-deploy-key' -f /tmp/argocd-deploy-key -N ''"
    echo "    cat /tmp/argocd-deploy-key.pub"
    echo "    # Add to: github.com/helios-ryuu/k3s-homelab → Settings → Deploy keys (read-only)"
    warn "Then press Enter to continue..."
    read -r
    do_add_repo
    echo ""
    do_apply_root
}

# ======================== MAIN ========================

ACTION="${1:-}"
case "$ACTION" in
    install)    do_install ;;
    login)      do_login ;;
    add-repo)   do_add_repo ;;
    apply-root) do_apply_root ;;
    bootstrap)  do_bootstrap ;;
    *)
        echo -e "${YELLOW}argocd.sh — ArgoCD Bootstrap Helper${NC}"
        echo ""
        echo "Cú pháp: $0 <action>"
        echo ""
        echo "Actions:"
        echo -e "  ${GREEN}install${NC}      Install ArgoCD into cluster"
        echo -e "  ${GREEN}login${NC}        Login to ArgoCD CLI"
        echo -e "  ${GREEN}add-repo${NC}     Register k3s-homelab deploy key"
        echo -e "  ${GREEN}apply-root${NC}   Apply root Application (app-of-apps)"
        echo -e "  ${GREEN}bootstrap${NC}    Full bootstrap (install → login → add-repo → apply-root)"
        ;;
esac
