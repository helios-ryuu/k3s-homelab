#!/bin/bash
# =================================================================
# ck.sh — K3s Cluster Check (read-only)
# =================================================================
# Chạy:
#   ./ck.sh               Hiển thị tất cả 7 sections
#   ./ck.sh sys           Chỉ hiển thị hệ thống & tải
#   ./ck.sh node          Nodes overview
#   ./ck.sh node <name>   Chi tiết 1 node (kubectl describe)
#   ./ck.sh pod           Pods layout
#   ./ck.sh pod <name>    Chi tiết 1 pod (kubectl describe)
#   ./ck.sh pvc           Storage (PVC)
#   ./ck.sh pvc <name>    Chi tiết 1 PVC (kubectl describe)
#   ./ck.sh res           Deployed resources
#   ./ck.sh img           Custom images & usage
#   ./ck.sh helm          Helm releases
#   ./ck.sh topo          Topology
#   ./ck.sh export [.]    Export ra file txt (vào ck/ folder)
#   ./ck.sh export -c     Export compact (không giảm thông tin)
#   ./ck.sh -h|--help     Help
# =================================================================

set -o pipefail
K3S_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CK_DIR="$K3S_DIR/ck"

# ======================== COLORS ========================

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Khi export, tắt màu
NO_COLOR=false
if [ "$1" = "export" ]; then
    NO_COLOR=true
    GREEN=''; RED=''; BLUE=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi

# ======================== HELP ========================

show_help() {
    cat <<'EOF'
ck.sh — K3s Cluster Check (read-only)

USAGE:
  ck.sh                    Hiển thị tất cả 7 sections
  ck.sh <section>          Hiển thị 1 section cụ thể
  ck.sh <section> <name>   Chi tiết kubectl describe (node/pod/pvc)
  ck.sh export [. | -c]    Export ra file txt
  ck.sh -h | --help        Hiển thị help

SECTIONS:
  sys       Hệ thống & tải (hostname, kernel, RAM, CPU, disk)
  node      K3s nodes overview (status, role, version, Tailscale IP)
  pod       Pods layout (grouped by node)
  pvc       Storage / PVC (grouped by node)
  res       Deployed resources (deploy, sts, ds, svc — exclude kube-system)
  img       Custom images & usage per node
  helm      Helm releases
  topo      Topology tree

DETAIL MODE (node/pod/pvc):
  ck.sh node <node-name>         kubectl describe node <node-name>
  ck.sh pod loki-0          kubectl describe pod loki-0 (auto-detect namespace)
  ck.sh pvc loki-data       kubectl describe pvc loki-data (auto-detect namespace)
  ck.sh res bigdata         Resources chỉ trong namespace bigdata

EXPORT:
  ck.sh export              Export full output → ck/ck-HHmmss-ddMMyy.txt
  ck.sh export .            Tương tự (export vào ck/ folder)
  ck.sh export -c           Compact: bỏ box art, bỏ dòng trống thừa, giữ nguyên data

EXAMPLES:
  ck.sh                     # Full check
  ck.sh sys                 # Chỉ xem RAM/CPU/disk
  ck.sh node nameofnode     # Describe node nameofnode
  ck.sh pod                 # Pods layout
  ck.sh pod nameofpod       # Describe pod nameofpod
  ck.sh export -c           # Export compact
EOF
}

# ======================== CACHE ========================

_cache_loaded=false
load_cache() {
    [ "$_cache_loaded" = true ] && return
    RAW_NODES_JSON=$(kubectl get nodes -o json 2>/dev/null)
    RAW_PODS_JSON=$(kubectl get pods -A -o json 2>/dev/null)
    RAW_PVC_JSON=$(kubectl get pvc -A -o json 2>/dev/null)

    # Tailscale IPs
    declare -gA TS_IPS
    while IFS= read -r line; do
        ts_ip=$(echo "$line" | awk '{print $1}')
        [ -z "$ts_ip" ] && continue
        TS_IPS["$ts_ip"]="$ts_ip"
    done < <(tailscale status 2>/dev/null | awk 'NF>=2{print $1}')

    # Sorted nodes (masters first)
    SORTED_NODES=$(echo "$RAW_NODES_JSON" | jq -r '
        .items[] |
        (if .metadata.labels["node-role.kubernetes.io/control-plane"] != null then "1_master" else "2_worker" end) as $role_sort |
        [$role_sort, .metadata.name] | @tsv
    ' | sort -k1,1 -k2,2 | cut -f2)

    # All pods flat
    ALL_PODS=$(echo "$RAW_PODS_JSON" | jq -r '
        .items[] | [(.spec.nodeName // "<none>"), .metadata.namespace, .metadata.name, .status.phase] | @tsv
    ' | sort -k1,1 -k2,2 -k3,3)

    _cache_loaded=true
}

get_ts_ip() {
    local node="$1"
    local node_ips=$(echo "$RAW_NODES_JSON" | jq -r --arg n "$node" '.items[] | select(.metadata.name==$n) | .status.addresses[].address')
    for ip in $node_ips; do
        if [ -n "${TS_IPS[$ip]}" ]; then
            echo "$ip"; return
        fi
    done
    local ts_ip=$(tailscale status 2>/dev/null | grep -i "$node" | awk '{print $1}' | head -1)
    [ -n "$ts_ip" ] && echo "$ts_ip" || echo "N/A"
}

# ======================== SECTIONS ========================

section_sys() {
    echo -e "\n${BLUE}--- [1/7] HỆ THỐNG & TẢI ---${NC}"
    printf "${CYAN}%-12s${NC} %s\n" "Hostname:" "$(hostname)"
    printf "${CYAN}%-12s${NC} %s\n" "Kernel:" "$(uname -r)"
    printf "${CYAN}%-12s${NC} %s\n" "Uptime:" "$(uptime -p)"
    uptime | awk -F'load average:' '{ printf "'"${CYAN}"'%-12s'"${NC}"' %s (1m / 5m / 15m)\n", "Load avg:", $2 }'
    free -m | awk 'NR==2{
        used=$3; total=$2; pct=used*100/total;
        bar=""; for(i=0;i<20;i++) bar=bar (i<pct/5 ? "█" : "░");
        printf "'"${CYAN}"'%-12s'"${NC}"' %d/%d MB (%d%%) [%s]\n", "RAM:", used, total, pct, bar
    }'
    free -m | awk 'NR==3{
        if($2>0) {
            pct=$3*100/$2;
            bar=""; for(i=0;i<20;i++) bar=bar (i<pct/5 ? "█" : "░");
            printf "'"${CYAN}"'%-12s'"${NC}"' %d/%d MB (%d%%) [%s]\n", "Swap:", $3, $2, pct, bar;
        }
    }'
    df -h / | awk 'NR==2{printf "'"${CYAN}"'%-12s'"${NC}"' %s/%s (%s used)\n", "Disk (/):", $3, $2, $5}'
    printf "${CYAN}%-12s${NC} %s cores | %s\n" "CPU:" "$(nproc)" "$(grep -m 1 'model name' /proc/cpuinfo | sed 's/.*: //')"
}

section_node() {
    load_cache
    echo -e "\n${BLUE}--- [2/7] K3S NODES & PODS ---${NC}"
    (
    echo -e "NAME\tSTATUS\tROLE\tVERSION\tTAILSCALE_IP"
    echo "$RAW_NODES_JSON" | jq -r '
        .items[] |
        .metadata.name as $name |
        (.status.conditions[] | select(.type=="Ready") | .status) as $ready |
        (if .metadata.labels["node-role.kubernetes.io/control-plane"] != null then "1_master" else "2_worker" end) as $role_sort |
        (if .metadata.labels["node-role.kubernetes.io/control-plane"] != null then "master" else "worker" end) as $role |
        .status.nodeInfo.kubeletVersion as $ver |
        [$role_sort, $name, $ready, $role, $ver] | @tsv
    ' | sort -k1,1 -k2,2 | while IFS=$'\t' read -r role_sort name ready role ver; do
        status="Ready"
        [ "$ready" != "True" ] && status="NotReady"
        ts_ip=$(get_ts_ip "$name")
        echo -e "$name\t$status\t$role\t$ver\t$ts_ip"
    done
    ) | column -t -s $'\t' | awk '
    NR==1{print "'"${YELLOW}"'" $0 "'"${NC}"'"}
    NR>1{
        line=$0;
        if (line ~ /NotReady/) sub("NotReady", "'"${RED}"'NotReady'"${NC}"'", line);
        else sub("Ready", "'"${GREEN}"'Ready'"${NC}"'", line);
        print line;
    }'
}

section_pod() {
    load_cache
    echo -e "\n${CYAN}PODS LAYOUT:${NC}"
    for node in $SORTED_NODES; do
        echo -e "  ${YELLOW}>> $node${NC}"
        NODE_PODS=$(echo "$ALL_PODS" | awk -v n="$node" '$1==n {print $2"\t"$3"\t"$4}')
        if [ -z "$NODE_PODS" ]; then
            echo -e "     ${CYAN}(Không có pod)${NC}"
        else
            (
            echo -e "NS\tNAME\tSTATUS"
            echo "$NODE_PODS"
            ) | column -t -s $'\t' | awk '
            NR==1{print "     '"${YELLOW}"'" $0 "'"${NC}"'"}
            NR>1{
                line=$0;
                if ($3 == "Running") sub("Running$", "'"${GREEN}"'Running'"${NC}"'", line);
                else if ($3 == "Pending") sub("Pending$", "'"${YELLOW}"'Pending'"${NC}"'", line);
                else if ($3 == "Succeeded") sub("Succeeded$", "'"${BLUE}"'Succeeded'"${NC}"'", line);
                else sub($3 "$", "'"${RED}"'" $3 "'"${NC}"'", line);
                print "     " line;
            }'
        fi
    done
}

section_pvc() {
    load_cache
    echo -e "\n${BLUE}--- [3/7] STORAGE (PVC) ---${NC}"
    PVC_NODE_MAP=$(echo "$RAW_PODS_JSON" | jq -r '
        .items[] |
        .spec.nodeName as $node |
        (.spec.volumes[]? |
            select(.persistentVolumeClaim != null) |
            .persistentVolumeClaim.claimName
        ) as $pvc |
        .metadata.namespace as $ns |
        [$node, $ns, $pvc] | @tsv
    ' 2>/dev/null | sort -u)

    ALL_PVC=$(echo "$RAW_PVC_JSON" | jq -r '
        .items[] | [.metadata.namespace, .metadata.name, (.status.capacity.storage // "N/A")] | @tsv
    ')

    for node in $SORTED_NODES; do
        echo -e "  ${YELLOW}>> $node${NC}"
        NODE_PVC=""
        while IFS=$'\t' read -r pvc_ns pvc_name pvc_size; do
            [ -z "$pvc_name" ] && continue
            match=$(echo "$PVC_NODE_MAP" | awk -v n="$node" -v ns="$pvc_ns" -v pvc="$pvc_name" '$1==n && $2==ns && $3==pvc')
            if [ -n "$match" ]; then
                NODE_PVC+="${pvc_ns}\t${pvc_name}\t${pvc_size}\n"
            fi
        done <<< "$ALL_PVC"

        if [ -z "$NODE_PVC" ]; then
            echo -e "     ${CYAN}(Không có PVC)${NC}"
        else
            (
            echo -e "NS\tNAME\tSIZE"
            echo -e "$NODE_PVC"
            ) | column -t -s $'\t' | awk 'NR==1{print "     '"${YELLOW}"'" $0 "'"${NC}"'"} NR>1{print "     " $0}'
        fi
    done
}

section_res() {
    local ns_filter="$1"
    echo -e "\n${BLUE}--- [4/7] DEPLOYED RESOURCES ---${NC}"
    (
    echo -e "NS\tKIND\tREADY\tPORTS"
    local namespaces
    if [ -n "$ns_filter" ]; then
        namespaces="$ns_filter"
    else
        namespaces=$(kubectl get ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -v kube-system | sort)
    fi
    for ns in $namespaces; do
        kubectl get deploy,sts,ds -n "$ns" --no-headers 2>/dev/null | while read -r line; do
            kind=$(echo "$line" | awk '{print $1}')
            ready=$(echo "$line" | awk '{print $2}')
            echo -e "$ns\t$kind\t$ready\t"
        done
        kubectl get svc -n "$ns" --no-headers 2>/dev/null | grep -v "kubernetes " | while read -r line; do
            name=$(echo "$line" | awk '{print $1}')
            type=$(echo "$line" | awk '{print $2}')
            ports=$(echo "$line" | awk '{print $5}')
            [ ${#ports} -gt 40 ] && ports="${ports:0:37}..."
            echo -e "$ns\tsvc/$name\t$type\t$ports"
        done
    done
    ) | column -t -s $'\t' | awk '
    NR==1{print "'"${YELLOW}"'" $0 "'"${NC}"'"}
    NR>1{
        line=$0;
        if (match(line, /[0-9]+\/[0-9]+/)) {
            frac=substr(line, RSTART, RLENGTH);
            split(frac, r, "/");
            if (r[1]+0 == r[2]+0 && r[1]+0 > 0) gsub(frac, "'"${GREEN}"'" frac "'"${NC}"'", line);
            else if (r[1]+0 == 0 && r[2]+0 == 0) gsub(frac, "'"${BLUE}"'" frac "'"${NC}"'", line);
            else gsub(frac, "'"${YELLOW}"'" frac "'"${NC}"'", line);
        }
        print line;
    }'
}

section_img() {
    load_cache
    echo -e "\n${BLUE}--- [5/7] CUSTOM IMAGES & USAGE ---${NC}"
    POD_DATA=$(echo "$RAW_PODS_JSON" | jq -r '.items[] | .spec.nodeName as $node | .metadata.name as $pod | (.spec.containers[], (.spec.initContainers[]? // empty)) | [$node, (.image | split("/") | last | split(":") | first | split("@") | first), $pod] | @tsv' | sort -u)
    SYS_IMAGES="rancher|k8s\.io|gcr\.io|klipper|pause|coredns|traefik|metrics|local-path"

    for node in $SORTED_NODES; do
        echo -e "${YELLOW}>> Node: $node${NC}"
        NODE_IMAGES=$(echo "$RAW_NODES_JSON" | jq -r --arg n "$node" '
            .items[] | select(.metadata.name==$n) | .status.images[]? | "\(.names[0])\t\(.sizeBytes)"
        ' 2>/dev/null | grep -vE "$SYS_IMAGES" | grep -v "<none>" | sort -u)

        if [ -z "$NODE_IMAGES" ]; then
            echo -e "   ${CYAN}(Trống)${NC}"
        else
            output=$(echo "$NODE_IMAGES" | while IFS=$'\t' read -r full_img size; do
                short_img=$(echo "$full_img" | sed 's/@sha256:\([a-f0-9]\{10\}\)[a-f0-9]*/@sha256:\1…/')
                core_name=$(echo "$full_img" | awk -F'/' '{print $NF}' | sed 's/:.*//; s/@sha256.*//')
                using_pods=$(echo "$POD_DATA" | awk -v n="$node" -v c="$core_name" '$1==n && $2==c {print $3}' | sort -u | paste -sd "," -)
                size_gb=$(awk -v s="$size" 'BEGIN {printf "%.2f", s/1073741824}')

                if [ -n "$using_pods" ]; then
                    tag="${GREEN}[In-Use]${NC}"
                    info="${CYAN}(Pod: $using_pods)${NC}"
                else
                    tag="${RED}[Unused]${NC}"
                    info=""
                fi
                printf -- "-\t%s\t|\t%s GB\t|\t%b\t%b\n" "$short_img" "$size_gb" "$tag" "$info"
            done)
            echo "$output" | column -t -s $'\t' | sed 's/^/   /'
        fi
    done
}

section_helm() {
    echo -e "\n${BLUE}--- [6/7] HELM RELEASES ---${NC}"
    helm list -A 2>/dev/null | awk '
    NR==1{print "'"${YELLOW}"'" $0 "'"${NC}"'"}
    NR>1{
        line=$0;
        if (line ~ /deployed/) sub("deployed", "'"${GREEN}"'deployed'"${NC}"'", line);
        else if (line ~ /failed/) sub("failed", "'"${RED}"'failed'"${NC}"'", line);
        else if (line ~ /pending/) {
            match(line, /pending[^ ]*/);
            w=substr(line, RSTART, RLENGTH);
            sub(w, "'"${YELLOW}"'" w "'"${NC}"'", line);
        }
        print line;
    }'
}

section_topo() {
    load_cache
    echo -e "\n${BLUE}--- [7/7] TOPOLOGY ---${NC}"
    for node in $SORTED_NODES; do
        role_raw=$(echo "$RAW_NODES_JSON" | jq -r --arg n "$node" '.items[] | select(.metadata.name==$n) | if .metadata.labels["node-role.kubernetes.io/control-plane"] != null then "master" else "worker" end')
        ip=$(get_ts_ip "$node")
        echo -e "${CYAN}■ $node${NC} [${YELLOW}${role_raw}${NC} | ${ip}]"

        NODE_NSS=$(echo "$ALL_PODS" | awk -v n="$node" '$1==n {print $2}' | sort -u)
        if [ -z "$NODE_NSS" ]; then
            echo -e "  └── ${CYAN}(Không có pod)${NC}"
        else
            arr_nss=($NODE_NSS)
            count_nss=${#arr_nss[@]}
            for (( i=0; i<count_nss; i++ )); do
                ns="${arr_nss[$i]}"
                pod_count=$(echo "$ALL_PODS" | awk -v n="$node" -v ns="$ns" '$1==n && $2==ns {print $3}' | wc -l)
                if [ $i -eq $((count_nss - 1)) ]; then
                    echo -e "  └── ${GREEN}$ns${NC} ($pod_count pods)"
                else
                    echo -e "  ├── ${GREEN}$ns${NC} ($pod_count pods)"
                fi
            done
        fi
    done
}

# ======================== DETAIL (describe) ========================

detail_node() {
    local name="$1"
    echo -e "${BLUE}>>> kubectl describe node $name${NC}"
    kubectl describe node "$name" 2>&1
}

detail_pod() {
    local name="$1"
    # Auto-detect namespace
    local ns_pod
    ns_pod=$(kubectl get pods -A --no-headers 2>/dev/null | grep -E "\b${name}\b" | head -1)
    if [ -z "$ns_pod" ]; then
        echo -e "${RED}Pod '$name' không tìm thấy${NC}"
        return 1
    fi
    local ns=$(echo "$ns_pod" | awk '{print $1}')
    local pod=$(echo "$ns_pod" | awk '{print $2}')
    echo -e "${BLUE}>>> kubectl describe pod -n $ns $pod${NC}"
    kubectl describe pod -n "$ns" "$pod" 2>&1
}

detail_pvc() {
    local name="$1"
    local ns_pvc
    ns_pvc=$(kubectl get pvc -A --no-headers 2>/dev/null | grep -E "\b${name}\b" | head -1)
    if [ -z "$ns_pvc" ]; then
        echo -e "${RED}PVC '$name' không tìm thấy${NC}"
        return 1
    fi
    local ns=$(echo "$ns_pvc" | awk '{print $1}')
    local pvc=$(echo "$ns_pvc" | awk '{print $2}')
    echo -e "${BLUE}>>> kubectl describe pvc -n $ns $pvc${NC}"
    kubectl describe pvc -n "$ns" "$pvc" 2>&1
}

# ======================== EXPORT ========================

do_export() {
    local compact=false
    [ "$1" = "-c" ] || [ "$1" = "--compact" ] && compact=true

    mkdir -p "$CK_DIR"
    local ts=$(date +"%H%M%S-%d%m%y")
    local suffix=""
    $compact && suffix="-compact"
    local outfile="$CK_DIR/ck-${ts}${suffix}.txt"

    if $compact; then
        # ── COMPACT MODE ──
        # Giữ nguyên 100% thông tin, nhưng:
        # - Bỏ section dividers (--- [x/7] ... ---), dùng header ngắn
        # - Pods: gộp thành 1 dòng per node (ns:count thay vì liệt kê từng pod)
        # - PVC: gộp thành 1 dòng per node
        # - Images: chỉ giữ image_short size status, bỏ pipe decorations
        # - Topology: bỏ (trùng với pods compact)
        # - Bỏ dòng trống thừa
        (
            GREEN=''; RED=''; BLUE=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
            NO_COLOR=true
            load_cache

            echo "K3s Cluster Check (compact) — $(date '+%Y-%m-%d %H:%M:%S')"

            # SYS — giữ nguyên nhưng bỏ section header dài
            echo ""
            echo "[SYS]"
            printf "%-10s %s\n" "Host:" "$(hostname)"
            printf "%-10s %s\n" "Kernel:" "$(uname -r)"
            printf "%-10s %s\n" "Uptime:" "$(uptime -p)"
            free -m | awk 'NR==2{ printf "%-10s %d/%d MB (%d%%)\n", "RAM:", $3, $2, $3*100/$2 }'
            free -m | awk 'NR==3{ if($2>0) printf "%-10s %d/%d MB (%d%%)\n", "Swap:", $3, $2, $3*100/$2 }'
            df -h / | awk 'NR==2{ printf "%-10s %s/%s (%s)\n", "Disk:", $3, $2, $5 }'
            printf "%-10s %s cores\n" "CPU:" "$(nproc)"

            # NODES — giữ nguyên table
            echo ""
            echo "[NODES]"
            echo "$RAW_NODES_JSON" | jq -r '
                .items[] |
                (if .metadata.labels["node-role.kubernetes.io/control-plane"] != null then "1" else "2" end) as $s |
                (if $s == "1" then "master" else "worker" end) as $role |
                (.status.conditions[] | select(.type=="Ready") | if .status == "True" then "Ready" else "NotReady" end) as $st |
                [$s, .metadata.name, $st, $role, .status.nodeInfo.kubeletVersion] | @tsv
            ' | sort | while IFS=$'\t' read -r _ name st role ver; do
                ts_ip=$(get_ts_ip "$name")
                printf "%-24s %-8s %-7s %-14s %s\n" "$name" "$st" "$role" "$ver" "$ts_ip"
            done

            # PODS — gộp: node → ns(count) ns(count) ...
            echo ""
            echo "[PODS]"
            for node in $SORTED_NODES; do
                # Đếm pods per namespace, kèm trạng thái tổng hợp
                local pod_summary=""
                local total=0 running=0 pending=0 other=0
                while IFS=$'\t' read -r _ ns name phase; do
                    ((total++))
                    case "$phase" in
                        Running)   ((running++)) ;;
                        Pending)   ((pending++)) ;;
                        *)         ((other++)) ;;
                    esac
                done < <(echo "$ALL_PODS" | awk -v n="$node" '$1==n')

                # Pods by namespace
                local ns_counts=""
                while IFS= read -r line; do
                    [ -z "$line" ] && continue
                    local cnt=$(echo "$line" | awk '{print $1}')
                    local ns=$(echo "$line" | awk '{print $2}')
                    ns_counts+="$ns($cnt) "
                done < <(echo "$ALL_PODS" | awk -v n="$node" '$1==n {print $2}' | sort | uniq -c | sort -rn)

                local status_str="${running}R"
                [ "$pending" -gt 0 ] && status_str+="/${pending}P"
                [ "$other" -gt 0 ] && status_str+="/${other}?"
                printf "%-24s [%s] %s\n" "$node" "$status_str" "$ns_counts"
            done

            # PVC — gộp: node → ns/name(size) ...
            echo ""
            echo "[PVC]"
            local PVC_NODE_MAP=$(echo "$RAW_PODS_JSON" | jq -r '
                .items[] | .spec.nodeName as $node |
                (.spec.volumes[]? | select(.persistentVolumeClaim != null) | .persistentVolumeClaim.claimName) as $pvc |
                .metadata.namespace as $ns | [$node, $ns, $pvc] | @tsv
            ' 2>/dev/null | sort -u)
            local ALL_PVC_DATA=$(echo "$RAW_PVC_JSON" | jq -r '.items[] | [.metadata.namespace, .metadata.name, (.status.capacity.storage // "?")] | @tsv')

            for node in $SORTED_NODES; do
                local pvc_line=""
                while IFS=$'\t' read -r pvc_ns pvc_name pvc_size; do
                    [ -z "$pvc_name" ] && continue
                    local match=$(echo "$PVC_NODE_MAP" | awk -v n="$node" -v ns="$pvc_ns" -v pvc="$pvc_name" '$1==n && $2==ns && $3==pvc {print 1; exit}')
                    [ -n "$match" ] && pvc_line+="$pvc_ns/$pvc_name($pvc_size) "
                done <<< "$ALL_PVC_DATA"
                if [ -n "$pvc_line" ]; then
                    printf "%-24s %s\n" "$node" "$pvc_line"
                fi
            done

            # RESOURCES — giữ nguyên
            echo ""
            echo "[RESOURCES]"
            for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -v kube-system | sort); do
                kubectl get deploy,sts,ds -n "$ns" --no-headers 2>/dev/null | while read -r line; do
                    local kind=$(echo "$line" | awk '{print $1}')
                    local ready=$(echo "$line" | awk '{print $2}')
                    printf "%-12s %-65s %s\n" "$ns" "$kind" "$ready"
                done
                kubectl get svc -n "$ns" --no-headers 2>/dev/null | grep -v "kubernetes " | while read -r line; do
                    local name=$(echo "$line" | awk '{print $1}')
                    local type=$(echo "$line" | awk '{print $2}')
                    local ports=$(echo "$line" | awk '{print $5}')
                    [ ${#ports} -gt 50 ] && ports="${ports:0:47}..."
                    printf "%-12s svc/%-60s %-10s %s\n" "$ns" "$name" "$type" "$ports"
                done
            done

            # IMAGES — compact: bỏ pipe decorations
            echo ""
            echo "[IMAGES]"
            local POD_DATA=$(echo "$RAW_PODS_JSON" | jq -r '.items[] | .spec.nodeName as $node | .metadata.name as $pod | (.spec.containers[], (.spec.initContainers[]? // empty)) | [$node, (.image | split("/") | last | split(":") | first | split("@") | first), $pod] | @tsv' | sort -u)
            local SYS_IMAGES="rancher|k8s\.io|gcr\.io|klipper|pause|coredns|traefik|metrics|local-path"
            for node in $SORTED_NODES; do
                echo "  $node:"
                echo "$RAW_NODES_JSON" | jq -r --arg n "$node" '
                    .items[] | select(.metadata.name==$n) | .status.images[]? | "\(.names[0])\t\(.sizeBytes)"
                ' 2>/dev/null | grep -vE "$SYS_IMAGES" | grep -v "<none>" | sort -u | while IFS=$'\t' read -r full_img size; do
                    local short_img=$(echo "$full_img" | sed 's/@sha256:\([a-f0-9]\{10\}\).*/…/')
                    local core_name=$(echo "$full_img" | awk -F'/' '{print $NF}' | sed 's/:.*//; s/@sha256.*//')
                    local using_pods=$(echo "$POD_DATA" | awk -v n="$node" -v c="$core_name" '$1==n && $2==c {print $3}' | sort -u | paste -sd "," -)
                    local size_gb=$(awk -v s="$size" 'BEGIN {printf "%.2f", s/1073741824}')
                    local tag="Unused"
                    [ -n "$using_pods" ] && tag="$using_pods"
                    printf "    %-70s %5s GB  %s\n" "$short_img" "$size_gb" "$tag"
                done
            done

            # HELM — giữ nguyên
            echo ""
            echo "[HELM]"
            helm list -A --no-headers 2>/dev/null | while read -r line; do
                echo "  $line"
            done

            echo ""
            echo ">>> Done"
        ) > "$outfile"
    else
        # ── NORMAL MODE ──
        (
            GREEN=''; RED=''; BLUE=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
            NO_COLOR=true

            echo "K3s Cluster Check — $(date '+%Y-%m-%d %H:%M:%S')"
            echo "================================================="
            section_sys
            section_node
            section_pod
            section_pvc
            section_res
            section_img
            section_helm
            section_topo
            echo ""
            echo ">>> Kiểm tra hoàn tất!"
        ) > "$outfile"
    fi

    local size=$(du -h "$outfile" | awk '{print $1}')
    local lines=$(wc -l < "$outfile")
    echo -e "\033[0;32m✔ Exported: $outfile ($lines lines, $size)\033[0m"
}

# ======================== MAIN ========================

case "${1:-}" in
    -h|--help)
        show_help
        ;;
    sys)
        section_sys
        ;;
    node)
        if [ -n "${2:-}" ]; then
            detail_node "$2"
        else
            echo -e "${YELLOW}>>> Đang thu thập dữ liệu từ K3s API...${NC}"
            section_node
        fi
        ;;
    pod)
        if [ -n "${2:-}" ]; then
            detail_pod "$2"
        else
            echo -e "${YELLOW}>>> Đang thu thập dữ liệu từ K3s API...${NC}"
            section_pod
        fi
        ;;
    pvc)
        if [ -n "${2:-}" ]; then
            detail_pvc "$2"
        else
            echo -e "${YELLOW}>>> Đang thu thập dữ liệu từ K3s API...${NC}"
            section_pvc
        fi
        ;;
    res)
        if [ -n "${2:-}" ]; then
            section_res "$2"
        else
            section_res
        fi
        ;;
    img)
        echo -e "${YELLOW}>>> Đang thu thập dữ liệu từ K3s API...${NC}"
        section_img
        ;;
    helm)
        section_helm
        ;;
    topo)
        echo -e "${YELLOW}>>> Đang thu thập dữ liệu từ K3s API...${NC}"
        section_topo
        ;;
    export)
        echo -e "${YELLOW}>>> Đang export...${NC}"
        do_export "${2:-}"
        ;;
    *)
        # Full check — tất cả sections
        echo -e "${YELLOW}>>> Đang thu thập dữ liệu từ K3s API...${NC}"
        section_sys
        section_node
        section_pod
        section_pvc
        section_res
        section_img
        section_helm
        section_topo
        echo -e "\n${GREEN}>>> Kiểm tra hoàn tất!${NC}"
        ;;
esac
