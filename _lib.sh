#!/bin/bash
# =================================================================
# _lib.sh — Shared helpers for K3s component scripts
# =================================================================
# Được source bởi tất cả component scripts:
#   source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
# =================================================================

K3S_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORCE="--force --grace-period=0 --ignore-not-found"
HELM_TIMEOUT="--timeout 2m --wait=false"

# ======================== COLORS ========================

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
ORANGE='\033[38;5;208m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BLUE}>>> $*${NC}"; }
ok()    { echo -e "${GREEN}    ✔ $*${NC}"; }
warn()  { echo -e "${YELLOW}    ⚠ $*${NC}"; }
err()   { echo -e "${RED}    ✘ $*${NC}"; }

# ======================== CHECK HELPERS ========================
# Dùng cho các subcommand "check"

PASS=0; FAIL=0; WARN=0

check_reset() { PASS=0; FAIL=0; WARN=0; }

chk_ok()   { echo -e "  ${GREEN}✔${NC} $*"; ((PASS++)); }
chk_fail() { echo -e "  ${RED}✘${NC} $*"; ((FAIL++)); }
chk_warn() { echo -e "  ${YELLOW}⚠${NC} $*"; ((WARN++)); }
chk_info() { echo -e "${CYAN}>>> $*${NC}"; }
hdr()      { echo -e "\n${BOLD}--- $* ---${NC}"; }

check_http() {
    local label="$1" url="$2" timeout="${3:-5}"
    local code
    code=$(curl -sf --max-time "$timeout" -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)
    if [ "$code" = "200" ]; then
        chk_ok "$label: UP"
    else
        chk_fail "$label: DOWN (HTTP ${code:-timeout})"
    fi
}

check_daemonset() {
    local ns="$1" name="$2" label="$3"
    local desired ready
    desired=$(kubectl get ds -n "$ns" -l "$label" -o jsonpath='{.items[0].status.desiredNumberScheduled}' 2>/dev/null)
    ready=$(kubectl get ds -n "$ns" -l "$label" -o jsonpath='{.items[0].status.numberReady}' 2>/dev/null)
    if [ -n "$desired" ] && [ "$ready" = "$desired" ]; then
        chk_ok "$name — $ready/$desired Ready"
    elif [ -n "$desired" ]; then
        chk_warn "$name — ${ready:-0}/$desired Ready (nodes offline?)"
    else
        chk_fail "$name — DaemonSet MISSING"
    fi
}

check_summary() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    echo -ne "  Kết quả: "
    echo -ne "${GREEN}$PASS passed${NC}  "
    [ "$WARN" -gt 0 ] && echo -ne "${YELLOW}$WARN warnings${NC}  "
    [ "$FAIL" -gt 0 ] && echo -ne "${RED}$FAIL failed${NC}  "
    echo ""
    if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
        echo -e "  Trạng thái: ${GREEN}TẤT CẢ OK${NC}"
    elif [ "$FAIL" -eq 0 ]; then
        echo -e "  Trạng thái: ${YELLOW}CÓ CẢNH BÁO${NC}"
    else
        echo -e "  Trạng thái: ${RED}CÓ LỖI${NC}"
    fi
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
}

# ======================== POD HELPERS ========================

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

# ======================== DEPLOY HELPERS ========================

# Force xóa tất cả pods trong namespace (kể cả trên node offline)
force_cleanup_ns() {
    local ns="$1"
    warn "Force xóa pods trong $ns..."
    # Patch + force-delete any stuck pods
    for pod in $(kubectl get pods -n "$ns" -o name 2>/dev/null); do
        kubectl patch "$pod" -n "$ns" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
        kubectl delete "$pod" -n "$ns" $FORCE 2>/dev/null || true
    done
    kubectl delete pods -n "$ns" --all $FORCE 2>/dev/null || true

    warn "Xóa PVC..."
    for pvc in $(kubectl get pvc -n "$ns" -o name 2>/dev/null); do
        kubectl patch "$pvc" -n "$ns" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
    done
    kubectl delete pvc -n "$ns" --all $FORCE 2>/dev/null || true

    warn "Xóa namespace..."
    kubectl delete ns "$ns" $FORCE 2>/dev/null || true
    # Patch namespace finalizers if stuck
    if kubectl get ns "$ns" &>/dev/null; then
        kubectl patch ns "$ns" -p '{"spec":{"finalizers":[]}}' --type=merge 2>/dev/null || true
    fi

    # Wait up to 30s for namespace to terminate
    local count=0
    while kubectl get ns "$ns" &>/dev/null && [ $count -lt 30 ]; do
        sleep 1
        ((count++))
    done
    kubectl get ns "$ns" &>/dev/null && warn "Namespace $ns vẫn đang xóa (nền)" || ok "Namespace $ns đã xóa"
}

# Kiểm tra release đã tồn tại chưa
release_exists() {
    helm status "$1" -n "$2" &>/dev/null
}

# Hiển thị trạng thái pods sau deploy (NON-BLOCKING)
wait_for_ready() {
    local ns="$1"
    sleep 3

    info "Trạng thái pods trong $ns:"

    local running=0 pending=0 crash=0 other=0
    while read -r line; do
        [ -z "$line" ] && continue
        local name ready status
        name=$(echo "$line" | awk '{print $1}')
        ready=$(echo "$line" | awk '{print $2}')
        status=$(echo "$line" | awk '{print $3}')

        if [ "$status" = "Running" ]; then
            echo -e "      ${GREEN}✔${NC} $name  ${GREEN}$ready${NC}  $status"
            ((running++))
        elif [ "$status" = "Succeeded" ] || [ "$status" = "Completed" ]; then
            echo -e "      ${BLUE}✔${NC} $name  $ready  $status"
        elif [ "$status" = "Pending" ]; then
            echo -e "      ${YELLOW}…${NC} $name  $ready  ${YELLOW}$status${NC}  (node có thể offline)"
            ((pending++))
        elif echo "$status" | grep -q "CrashLoop\|Error\|Failed"; then
            echo -e "      ${RED}✘${NC} $name  $ready  ${RED}$status${NC}"
            ((crash++))
        else
            echo -e "      ${YELLOW}…${NC} $name  $ready  ${YELLOW}$status${NC}"
            ((other++))
        fi
    done < <(kubectl get pods -n "$ns" --no-headers 2>/dev/null)

    # Tóm tắt
    echo -ne "    → "
    [ "$running" -gt 0 ] && echo -ne "${GREEN}$running Running${NC}  "
    [ "$pending" -gt 0 ] && echo -ne "${YELLOW}$pending Pending${NC}  "
    [ "$crash" -gt 0 ]   && echo -ne "${RED}$crash CrashLoop${NC}  "
    [ "$other" -gt 0 ]   && echo -ne "${CYAN}$other Other${NC}  "
    echo ""
}

# Kiểm tra image có sẵn trên node (cho imagePullPolicy: Never)
check_image_on_nodes() {
    local image="$1"; shift
    local nodes=("$@")
    local all_ok=true

    info "Kiểm tra image '$image' trên các nodes..."
    for node in "${nodes[@]}"; do
        local node_status
        node_status=$(kubectl get node "$node" --no-headers 2>/dev/null | awk '{print $2}')
        if [ "$node_status" != "Ready" ]; then
            warn "$node: node $node_status (bỏ qua kiểm tra image)"
            continue
        fi

        local found
        found=$(kubectl get node "$node" -o jsonpath='{.status.images[*].names[*]}' 2>/dev/null | tr ' ' '\n' | grep -F "$image")
        if [ -n "$found" ]; then
            ok "$node: image sẵn sàng"
        else
            err "$node: THIẾU image '$image'"
            echo -e "      ${CYAN}Gợi ý: Trên node $node chạy:${NC}"
            echo "        sudo ctr -n k8s.io images import <file>.tar"
            echo "        # hoặc: docker load -i <file>.tar"
            all_ok=false
        fi
    done

    if [ "$all_ok" = false ]; then
        err "Một hoặc nhiều node thiếu image. Deploy sẽ thất bại (imagePullPolicy: Never)."
        echo -e "      ${YELLOW}Tiếp tục deploy? Pod trên node thiếu image sẽ ErrImageNeverPull.${NC}"
        read -p "      Tiếp tục? (y/N): " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            warn "Hủy deploy."
            return 1
        fi
    fi
    return 0
}

# ======================== NODE ROLE HELPERS ========================

# Kiểm tra các node role labels cần thiết trước khi deploy
check_node_labels() {
    local target="$1"
    local labels=()
    
    case "$target" in
        bigdata)
            labels=("node-role.kubernetes.io/bigdata-master=true" "node-role.kubernetes.io/bigdata-worker=true")
            ;;
        oracle)
            labels=("node-role.kubernetes.io/database-oracle=true")
            ;;
        mssql)
            labels=("node-role.kubernetes.io/database-mssql=true")
            ;;
        monitoring)
            labels=("node-role.kubernetes.io/monitoring=true")
            ;;
        logging)
            labels=("node-role.kubernetes.io/logging=true")
            ;;
        sure)
            labels=("app-host=sure")
            ;;
        localstack)
            # LocalStack falls back to control-plane if no dedicated node exists — skip label check
            return 0
            ;;
        *)
            return 0
            ;;
    esac

    info "Kiểm tra node labels cho target '$target'..."
    local all_found=true
    for label in "${labels[@]}"; do
        local nodes
        nodes=$(kubectl get nodes -l "$label" --no-headers 2>/dev/null | awk '{print $1}')
        
        if [ -n "$nodes" ]; then
            ok "Đã tìm thấy nodes có label $label: $(echo $nodes | tr '\n' ' ')"
        else
            err "KHÔNG tìm thấy node nào có label $label"
            all_found=false
        fi
    done

    if [ "$all_found" = false ]; then
        err "Thiếu role labels cần thiết cho '$target' trên các nodes."
        echo -e "      ${CYAN}Gợi ý: Dùng lệnh sau để gán label:${NC}"
        echo "        kubectl label node <node-name> <label-key>=<label-value>"
        echo ""
        err "Dừng deploy do thiếu node labels."
        exit 1
    fi
    return 0
}

# Kiểm tra các secrets cần thiết trước khi deploy
check_secrets() {
    local target="$1"
    local ns="$2"
    local mode="$3" # "quiet" or empty
    local keys=()

    case "$target" in
        oracle)      keys=("oracle-password") ;;
        mssql)       keys=("mssql-password") ;;
        monitoring)  keys=("grafana-admin-password" "admin-user" "admin-password") ;;
        cloudflared) keys=("cloudflare-token") ;;
        localstack)  keys=("localstack-token") ;;
        sure)        keys=("sure-secret-key-base" "sure-postgres-password") ;;
        bigdata)     return 0 ;; # BigData doesn't seem to use infra-secrets directly in values.yaml
        *)           return 0 ;;
    esac

    [ "$mode" != "quiet" ] && info "Kiểm tra secrets cho target '$target' trong namespace '$ns'..."
    
    if ! kubectl get secret infra-secrets -n "$ns" &>/dev/null; then
        if [ "$mode" = "quiet" ]; then
            return 1
        fi
        err "KHÔNG tìm thấy secret 'infra-secrets' trong namespace '$ns'."
        echo -e "      ${CYAN}Gợi ý: Chạy './init-sec.sh' để khởi tạo secrets.${NC}"
        exit 1
    fi

    local all_keys_found=true
    for key in "${keys[@]}"; do
        # jsonpath returns empty (exit 0) when key is missing — must check output, not exit code
        local val
        val=$(kubectl get secret infra-secrets -n "$ns" -o jsonpath="{.data['${key}']}" 2>/dev/null)
        if [ -z "$val" ]; then
            if [ "$mode" != "quiet" ]; then
                err "Secret 'infra-secrets' thiếu key: $key"
            fi
            all_keys_found=false
        fi
    done

    if [ "$all_keys_found" = false ]; then
        if [ "$mode" = "quiet" ]; then
            return 1
        fi
        err "Dừng deploy do thiếu keys trong infra-secrets."
        echo -e "      ${CYAN}Gợi ý: Kiểm tra file .env và chạy lại './init-sec.sh'.${NC}"
        exit 1
    fi

    [ "$mode" != "quiet" ] && ok "Secrets cho '$target' đã sẵn sàng."
    return 0
}

# ======================== NODE IP HELPERS ========================

get_node_ip() {
    local node="$1"
    if [ -z "$node" ]; then
        get_master_ip
        return
    fi
    # Ưu tiên InternalIP (Tailscale)
    local ip
    ip=$(kubectl get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
    if [ -z "$ip" ]; then
        # Fallback ExternalIP
        ip=$(kubectl get node "$node" -o jsonpath='{.status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null)
    fi
    echo "${ip:-127.0.0.1}"
}

get_master_ip() {
    local ip
    # Tìm node control-plane đầu tiên có IP 100.x (Tailscale)
    ip=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null | tr ' ' '\n' | grep '^100\.' | head -1)
    
    if [ -z "$ip" ]; then
        # Fallback sang bất kỳ control-plane nào
        ip=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
    fi
    
    if [ -z "$ip" ]; then
        # Fallback sang node đầu tiên
        ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
    fi
    
    echo "${ip:-127.0.0.1}"
}
