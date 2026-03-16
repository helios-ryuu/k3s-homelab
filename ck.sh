#!/bin/bash
# =================================================================
# ck.sh — K3s Cluster Check
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
PURPLE='\033[0;35m'
ORANGE='\033[38;5;208m'
BOLD='\033[1m'
NC='\033[0m'

# ======================== CORE CHECKS ========================
check_dependencies() {
    local deps=("kubectl" "jq" "awk" "column" "ping")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            echo -e "${RED}✖ Lỗi: Không tìm thấy '$dep'. Vui lòng cài đặt trước khi chạy script.${NC}"
            exit 1
        fi
    done
}

check_k3s_connection() {
    if ! kubectl cluster-info >/dev/null 2>&1; then
        echo -e "${RED}✖ Lỗi: Không thể kết nối đến K3s API.${NC}"
        exit 1
    fi
}

strip_colors() {
    sed -r 's/\x1B\[[0-9;]*[mK]//g'
}

# ======================== TIMING ========================
section_timed() {
    local start=$(date +%s%N)
    "$@"
    local ms=$(( ($(date +%s%N) - start) / 1000000 ))
    echo -e "  ${CYAN}(${ms}ms)${NC}"
}

# ======================== CACHE ========================
_cache_loaded=false
load_cache() {
    [ "$_cache_loaded" = true ] && return

    RAW_NODES_JSON=$(kubectl get nodes -o json 2>/dev/null)
    RAW_PODS_JSON=$(kubectl get pods -A -o json 2>/dev/null)
    RAW_PVC_JSON=$(kubectl get pvc -A -o json 2>/dev/null)
    RAW_WORKLOADS_JSON=$(kubectl get deploy,sts,ds -A -o json 2>/dev/null)
    RAW_SVC_JSON=$(kubectl get svc -A -o json 2>/dev/null)
    RAW_SECRETS_JSON=$(kubectl get secrets -A -o json 2>/dev/null)
    RAW_HPA_JSON=$(kubectl get hpa -A -o json 2>/dev/null)

    # Validate API response
    if [ -z "$RAW_NODES_JSON" ] || ! echo "$RAW_NODES_JSON" | jq -e '.items' >/dev/null 2>&1; then
        echo -e "${RED}✖ K3s API không phản hồi hoặc dữ liệu rỗng. Kiểm tra: kubectl cluster-info${NC}"
        exit 1
    fi

    # Build Tailscale IP maps (both IP→IP and hostname→IP)
    declare -gA TS_IPS TS_HOST_IPS
    if command -v tailscale >/dev/null 2>&1; then
        while IFS= read -r line; do
            ts_ip=$(echo "$line" | awk '{print $1}')
            ts_host=$(echo "$line" | awk '{print $2}')
            [ -z "$ts_ip" ] && continue
            TS_IPS["$ts_ip"]="$ts_ip"
            TS_HOST_IPS["$ts_host"]="$ts_ip"
        done < <(tailscale status 2>/dev/null | awk 'NF>=2{print $1, $2}')
    fi

    SORTED_NODES=$(echo "$RAW_NODES_JSON" | jq -r '
        .items[] |
        (if .metadata.labels["node-role.kubernetes.io/control-plane"] != null then "1_master" else "2_worker" end) as $role_sort |
        [$role_sort, .metadata.name] | @tsv
    ' | sort -k1,1 -k2,2 | cut -f2)

    ALL_PODS=$(echo "$RAW_PODS_JSON" | jq -r '
        .items[] |
        (.spec.nodeName // "<none>") as $node |
        .metadata.namespace as $ns |
        .metadata.name as $name |
        (((.status.containerStatuses // []) | map(select(.ready == true)) | length | tostring) + "/" + ((.spec.containers // []) | length | tostring)) as $ready |
        (
            if .metadata.deletionTimestamp != null then "Terminating"
            elif ((.status.containerStatuses // []) | map(.state.waiting.reason // empty) | first // null) != null then
                ((.status.containerStatuses // []) | map(.state.waiting.reason // empty) | first)
            else .status.phase
            end
        ) as $status |
        (((.status.containerStatuses // []) | map(.restartCount // 0) | add // 0) | tostring) as $restarts |
        (now - (.metadata.creationTimestamp | fromdateiso8601)) as $age_sec |
        (if $age_sec < 60 then "\($age_sec | floor)s"
         elif $age_sec < 3600 then "\($age_sec / 60 | floor)m"
         elif $age_sec < 86400 then "\($age_sec / 3600 | floor)h"
         else "\($age_sec / 86400 | floor)d" end) as $age |
        [$node, $ns, $name, $ready, $status, $restarts, $age] | @tsv
    ' 2>/dev/null | sort -k1,1 -k2,2 -k3,3)

    # Pre-compute PVC→node mapping
    declare -gA PVC_TO_NODE
    while IFS=$'\t' read -r pnode pns ppvc; do
        [ -n "$ppvc" ] && PVC_TO_NODE["${pns}/${ppvc}"]="$pnode"
    done < <(echo "$RAW_PODS_JSON" | jq -r '
        .items[] |
        .spec.nodeName as $node |
        (.spec.volumes[]? | select(.persistentVolumeClaim != null) | .persistentVolumeClaim.claimName) as $pvc |
        .metadata.namespace as $ns |
        [$node, $ns, $pvc] | @tsv
    ' 2>/dev/null | sort -u)

    # Parallelize ping
    declare -gA PING_CACHE
    for node in $SORTED_NODES; do
        ip=$(get_ts_ip "$node")
        if [ "$node" = "$(hostname)" ]; then
            PING_CACHE["$node"]="localhost"
        elif [ "$ip" != "N/A" ]; then
            ( lat=$(ping -c 1 -W 1 "$ip" 2>/dev/null | grep 'time=' | sed -E 's/.*time=([0-9.]+) ms.*/\1/')
              echo "${lat:-timeout}" > "/tmp/ck_ping_${node}" ) &
        else
            PING_CACHE["$node"]="N/A"
        fi
    done
    wait
    # Collect results from temp files
    for node in $SORTED_NODES; do
        if [ -z "${PING_CACHE[$node]}" ]; then
            PING_CACHE["$node"]=$(cat "/tmp/ck_ping_${node}" 2>/dev/null || echo "timeout")
        fi
        rm -f "/tmp/ck_ping_${node}"
    done

    _cache_loaded=true
}

get_ts_ip() {
    local node="$1"
    local node_ips=$(echo "$RAW_NODES_JSON" | jq -r --arg n "$node" '.items[] | select(.metadata.name==$n) | .status.addresses[]?.address')
    for ip in $node_ips; do
        if [ -n "${TS_IPS[$ip]}" ]; then
            echo "$ip"; return
        fi
    done

    # Fallback: use hostname→IP map (no extra tailscale status call)
    local ts_ip="${TS_HOST_IPS[$node]}"
    [ -n "$ts_ip" ] && echo "$ts_ip" && return

    echo "N/A"
}

# ======================== SECTIONS ========================
section_sys() {
    echo -e "\n${BLUE}--- [1/6] HỆ THỐNG & TẢI ---${NC}"
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
    echo -e "\n${BLUE}--- [2/6] TOPOLOGY & K3S NODES ---${NC}"
    for node in $SORTED_NODES; do
        ip=$(get_ts_ip "$node")

        node_info=$(echo "$RAW_NODES_JSON" | jq -r --arg n "$node" '
            .items[] | select(.metadata.name==$n) |
            (if .metadata.labels["node-role.kubernetes.io/control-plane"] != null then "master" else "worker" end) as $role |
            (.status.conditions[] | select(.type=="Ready") | .status) as $ready |
            .status.nodeInfo.kubeletVersion as $ver |
            [$role, $ready, $ver] | @tsv
        ')
        role_raw=$(echo "$node_info" | awk -F'\t' '{print $1}')
        ready_raw=$(echo "$node_info" | awk -F'\t' '{print $2}')
        ver_raw=$(echo "$node_info" | awk -F'\t' '{print $3}')

        status_col="${GREEN}Ready${NC}"
        [ "$ready_raw" != "True" ] && status_col="${RED}NotReady${NC}"

        if [ "$role_raw" == "master" ]; then
            role_col="${PURPLE}${role_raw}${NC}"
        else
            role_col="${ORANGE}${role_raw}${NC}"
        fi

        latency="${PING_CACHE[$node]:-N/A}"
        [ "$latency" != "localhost" ] && [ "$latency" != "timeout" ] && [ "$latency" != "N/A" ] && latency="${latency}ms"

        lat_col=$(echo "$latency" | awk '{
            if ($1 == "localhost") print "'"${CYAN}"'" $1 "'"${NC}"'";
            else if ($1 == "timeout" || $1 == "N/A") print "'"${RED}"'" $1 "'"${NC}"'";
            else {
                num=$1; sub("ms", "", num);
                if (num+0 < 50) print "'"${GREEN}"'" $1 "'"${NC}"'";
                else if (num+0 < 150) print "'"${YELLOW}"'" $1 "'"${NC}"'";
                else print "'"${RED}"'" $1 "'"${NC}"'";
            }
        }')

        echo -e "${CYAN}■ $node${NC} [${status_col} | ${role_col} | ${ver_raw} | IP: $ip | Ping: $lat_col]"

        # Condensed labels on single line
        NODE_LABELS=$(echo "$RAW_NODES_JSON" | jq -r --arg n "$node" '
            .items[] | select(.metadata.name==$n) | .metadata.labels | to_entries[] |
            select(.key | test("^(kubernetes\\.io|node\\.kubernetes\\.io|beta\\.kubernetes\\.io|k3s\\.io)") | not) |
            "\(.key)=\(.value)"
        ' 2>/dev/null)
        if [ -n "$NODE_LABELS" ]; then
            local labels_inline=$(echo "$NODE_LABELS" | paste -sd ", " -)
            echo -e "  ${PURPLE}Labels: $labels_inline${NC}"
        fi

        NODE_NSS=$(echo "$ALL_PODS" | awk -v n="$node" '$1==n {print $2}' | sort -u)
        if [ -z "$NODE_NSS" ]; then
            echo -e "  └── ${CYAN}(Không có pod)${NC}"
        else
            arr_nss=($NODE_NSS)
            count_nss=${#arr_nss[@]}
            for (( i=0; i<count_nss; i++ )); do
                ns="${arr_nss[$i]}"
                pod_count=$(echo "$ALL_PODS" | awk -v n="$node" -v ns="$ns" '$1==n && $2==ns' | wc -l)
                if [ $i -eq $((count_nss - 1)) ]; then
                    echo -e "  └── ${GREEN}$ns${NC} ($pod_count pods)"
                else
                    echo -e "  ├── ${GREEN}$ns${NC} ($pod_count pods)"
                fi
            done
        fi
    done

    echo -e "\n${CYAN}PODS LAYOUT:${NC}"
    for node in $SORTED_NODES; do
        echo -e "  ${YELLOW}>> $node${NC}"
        NODE_PODS=$(echo "$ALL_PODS" | awk -v n="$node" '$1==n {print $2"\t"$3"\t"$4"\t"$5"\t"$6"\t"$7}')

        if [ -z "$NODE_PODS" ]; then
            echo -e "     ${CYAN}(Không có pod)${NC}"
        else
            (
            echo -e "NS\tNAME\tREADY\tSTATUS\tRESTARTS\tAGE"
            echo "$NODE_PODS"
            ) | column -t -s $'\t' | awk '
            NR==1{print "     '"${YELLOW}"'" $0 "'"${NC}"'"}
            NR>1{
                line=$0;

                # 1) Color ready fraction FIRST (before ANSI codes break spacing)
                if (match(line, /[0-9]+\/[0-9]+/)) {
                    frac=substr(line, RSTART, RLENGTH);
                    split(frac, r, "/");
                    if (r[1]+0 == r[2]+0 && r[1]+0 > 0) sub(frac, "'"${GREEN}"'" frac "'"${NC}"'", line);
                    else if (r[1]+0 == 0) sub(frac, "'"${RED}"'" frac "'"${NC}"'", line);
                    else sub(frac, "'"${YELLOW}"'" frac "'"${NC}"'", line);
                }

                # 2) Color restart count (field 5) — before status coloring injects ANSI codes
                n=split(line, fields, /  +/);
                for (i=1; i<=n; i++) {
                    if (fields[i]+0 > 0 && fields[i] ~ /^[1-9][0-9]*$/) {
                        sub(" " fields[i] " ", " '"${ORANGE}"'" fields[i] "'"${NC}"' ", line);
                        break;
                    }
                }

                # 3) Color status LAST
                if (line ~ /CrashLoopBackOff/) sub("CrashLoopBackOff", "'"${RED}"'CrashLoopBackOff'"${NC}"'", line);
                else if (line ~ /ImagePullBackOff/) sub("ImagePullBackOff", "'"${RED}"'ImagePullBackOff'"${NC}"'", line);
                else if (line ~ /ErrImagePull/) sub("ErrImagePull", "'"${RED}"'ErrImagePull'"${NC}"'", line);
                else if (line ~ /Error/) sub("Error", "'"${RED}"'Error'"${NC}"'", line);
                else if (line ~ /Terminating/) sub("Terminating", "'"${ORANGE}"'Terminating'"${NC}"'", line);
                else if (line ~ /ContainerCreating/) sub("ContainerCreating", "'"${PURPLE}"'ContainerCreating'"${NC}"'", line);
                else if (line ~ /Pending/) sub("Pending", "'"${YELLOW}"'Pending'"${NC}"'", line);
                else if (line ~ /Succeeded/) sub("Succeeded", "'"${BLUE}"'Succeeded'"${NC}"'", line);
                else if (line ~ /Running/) sub("Running", "'"${GREEN}"'Running'"${NC}"'", line);

                print "     " line;
            }'
        fi
    done
}

section_secrets() {
    load_cache
    echo -e "\n${BLUE}--- SECRETS (theo namespace, chỉ hiện tên) ---${NC}"
    local ns_list=$(echo "$RAW_SECRETS_JSON" | jq -r '
        .items[] | select(.type != "kubernetes.io/service-account-token" and .metadata.namespace != "kube-system") |
        .metadata.namespace
    ' 2>/dev/null | sort -u)

    if [ -z "$ns_list" ]; then
        echo -e "  ${CYAN}(Không có secrets ngoài kube-system)${NC}"
        return
    fi

    for ns in $ns_list; do
        echo -e "  ${YELLOW}>> $ns${NC}"
        local sec_data=$(echo "$RAW_SECRETS_JSON" | jq -r --arg ns "$ns" '
            .items[] | select(.metadata.namespace==$ns and .type != "kubernetes.io/service-account-token") |
            "\(.metadata.name)\t\(.type)\t\((.data // {}) | keys | join(", "))"
        ' 2>/dev/null)

        if [ -n "$sec_data" ]; then
            (
                echo -e "${YELLOW}NAME\tTYPE\tKEYS${NC}"
                echo -e "$sec_data"
            ) | column -t -s $'\t' | sed 's/^/     /'
        else
            echo -e "     ${CYAN}(Không có secret)${NC}"
        fi
    done
}

section_pvc() {
    load_cache
    echo -e "\n${BLUE}--- [3/6] STORAGE (PVC) ---${NC}"

    ALL_PVC=$(echo "$RAW_PVC_JSON" | jq -r '
        .items[] | [.metadata.namespace, .metadata.name, (.status.capacity.storage // "N/A")] | @tsv
    ')

    for node in $SORTED_NODES; do
        echo -e "  ${YELLOW}>> $node${NC}"
        NODE_PVC=""
        while IFS=$'\t' read -r pvc_ns pvc_name pvc_size; do
            [ -z "$pvc_name" ] && continue
            # Use pre-computed PVC→node map for O(1) lookup
            local node_for_pvc="${PVC_TO_NODE["${pvc_ns}/${pvc_name}"]}"
            if [ "$node_for_pvc" = "$node" ]; then
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
    load_cache
    local ns_filter="$1"
    echo -e "\n${BLUE}--- [4/6] DEPLOYED RESOURCES ---${NC}"

    local jq_ns_filter=""
    if [ -n "$ns_filter" ]; then
        jq_ns_filter=" and (.metadata.namespace | startswith(\"$ns_filter\"))"
    fi

    echo -e "  ${YELLOW}>> WORKLOADS (Deployments, StatefulSets, DaemonSets)${NC}"
    local workloads=$(echo "$RAW_WORKLOADS_JSON" | jq -r '
        .items[] | select(.metadata.namespace != "kube-system"'"$jq_ns_filter"') |
        .metadata.namespace as $ns |
        .kind as $kind |
        .metadata.name as $name |
        (if $kind == "Deployment" then
            [($ns), "deploy", $name, (.spec.replicas // 0), (.status.readyReplicas // 0), (.status.updatedReplicas // 0), (.status.availableReplicas // 0)]
         elif $kind == "StatefulSet" then
            [($ns), "sts", $name, (.spec.replicas // 0), (.status.readyReplicas // 0), (.status.updatedReplicas // 0), (.status.availableReplicas // 0)]
         elif $kind == "DaemonSet" then
            [($ns), "ds", $name, (.status.desiredNumberScheduled // 0), (.status.numberReady // 0), (.status.updatedNumberScheduled // 0), (.status.numberAvailable // 0)]
         else empty end) | @tsv
    ' 2>/dev/null | sort -k1,1 -k2,2 -k3,3)

    if [ -z "$workloads" ]; then
        echo -e "     ${CYAN}(Không có workloads)${NC}"
    else
        local workloads_colored=$(echo "$workloads" | awk -F'\t' 'OFS="\t" {
            desired=$4; ready=$5; upto=$6; avail=$7;
            color="'"${GREEN}"'";
            if (desired+0 > 0) {
                if (ready+0 == 0 && avail+0 == 0) color="'"${RED}"'";
                else if (ready+0 < desired+0 || avail+0 < desired+0 || upto+0 < desired+0) color="'"${ORANGE}"'";
            }
            $4 = color desired "'"${NC}"'";
            $5 = color ready "'"${NC}"'";
            $6 = color upto "'"${NC}"'";
            $7 = color avail "'"${NC}"'";

            if ($2 == "deploy") $2 = "'"${CYAN}"'" $2 "'"${NC}"'";
            else if ($2 == "sts") $2 = "'"${PURPLE}"'" $2 "'"${NC}"'";
            else if ($2 == "ds") $2 = "'"${ORANGE}"'" $2 "'"${NC}"'";
            print $0
        }')
        (
            echo -e "${YELLOW}NS\tKIND\tNAME\tDESIRED\tREADY\tUP-TO-DATE\tAVAILABLE${NC}"
            echo -e "$workloads_colored"
        ) | column -t -s $'\t' | sed 's/^/     /'
    fi

    # ========================== KHỐI HPA ==========================
    echo -e "\n  ${YELLOW}>> AUTOSCALING (HPA)${NC}"
    local hpas=$(echo "$RAW_HPA_JSON" | jq -r '
        .items[] | select(.metadata.namespace != "kube-system"'"$jq_ns_filter"') |
        .metadata.namespace as $ns |
        .metadata.name as $name |
        .spec.scaleTargetRef.kind as $targetKind |
        .spec.scaleTargetRef.name as $targetName |
        (.spec.minReplicas // 1) as $min |
        .spec.maxReplicas as $max |
        (.status.currentReplicas // 0) as $current |
        (.status.desiredReplicas // 0) as $desired |
        [$ns, $name, "\($targetKind)/\($targetName)", "\($min) -> \($max)", "\($current)/\($desired)"] | @tsv
    ' 2>/dev/null | sort -k1,1 -k2,2)

    if [ -z "$hpas" ]; then
        echo -e "     ${CYAN}(Không có HPA nào được cấu hình)${NC}"
    else
        local hpas_colored=$(echo "$hpas" | awk -F'\t' 'OFS="\t" {
            current=$5;
            split(current, arr, "/");
            curr_val=arr[1]; des_val=arr[2];

            color="'"${GREEN}"'";
            split($4, max_arr, " -> ");
            max_val=max_arr[2];

            if (curr_val >= max_val && max_val > 0) color="'"${RED}"'";
            else if (curr_val >= max_val * 0.8) color="'"${ORANGE}"'";

            $5 = color current "'"${NC}"'";
            $3 = "'"${PURPLE}"'" $3 "'"${NC}"'";
            print $0
        }')

        (
            echo -e "${YELLOW}NS\tHPA NAME\tTARGET\tMIN->MAX\tCURRENT/DESIRED${NC}"
            echo -e "$hpas_colored"
        ) | column -t -s $'\t' | sed 's/^/     /'
    fi
    # ===================================================================

    echo -e "\n  ${YELLOW}>> SERVICES${NC}"
    local svcs=$(echo "$RAW_SVC_JSON" | jq -r '
        .items[] | select(.metadata.namespace != "kube-system" and .metadata.name != "kubernetes"'"$jq_ns_filter"') |
        .metadata.namespace as $ns |
        .metadata.name as $name |
        .spec.type as $type |
        .spec.clusterIP as $cip |
        ([.spec.ports[]? | "\(.port)/\(.protocol)"] | join(",")) as $ports |
        [$ns, $name, $type, $cip, $ports] | @tsv
    ' 2>/dev/null | sort -k1,1 -k2,2)

    if [ -z "$svcs" ]; then
        echo -e "     ${CYAN}(Không có services)${NC}"
    else
        local svcs_colored=$(echo "$svcs" | awk -F'\t' 'OFS="\t" {
            if ($3 == "ClusterIP") $3 = "'"${CYAN}"'" $3 "'"${NC}"'";
            else if ($3 == "NodePort") $3 = "'"${ORANGE}"'" $3 "'"${NC}"'";
            else if ($3 == "LoadBalancer") $3 = "'"${PURPLE}"'" $3 "'"${NC}"'";
            print $0
        }')
        (
            echo -e "${YELLOW}NS\tNAME\tTYPE\tCLUSTER-IP\tPORTS${NC}"
            echo -e "$svcs_colored"
        ) | column -t -s $'\t' | sed 's/^/     /'
    fi
}

section_img() {
    load_cache
    echo -e "\n${BLUE}--- [5/6] CUSTOM IMAGES & USAGE ---${NC}"
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
                short_img=$(echo "$full_img" | sed 's/@sha256:\([a-f0-9]\{6\}\)[a-f0-9]*/@sha256:\1…/')
                core_name=$(echo "$full_img" | awk -F'/' '{print $NF}' | sed 's/:.*//; s/@sha256.*//')
                using_pods=$(echo "$POD_DATA" | awk -v n="$node" -v c="$core_name" '$1==n && $2==c {print $3}' | sort -u | paste -sd "," -)
                size_gb=$(awk -v s="$size" 'BEGIN {printf "%.2f", s/1073741824}')

                if [ -n "$using_pods" ]; then
                    sort_key="1_inuse"
                    tag="${GREEN}[In-Use]${NC}"
                    info="${CYAN}(Pod: $using_pods)${NC}"
                else
                    sort_key="2_unused"
                    tag="${ORANGE}[Unused]${NC}"
                    info=""
                fi
                printf "%s\t-\t%s\t|\t%s GB\t|\t%b\t%b\n" "$sort_key" "$short_img" "$size_gb" "$tag" "$info"
            done | sort -k1,1 | cut -f2-)

            echo "$output" | column -t -s $'\t' | sed 's/^/   /'
        fi
    done
}

section_helm() {
    if ! command -v helm >/dev/null 2>&1; then return; fi
    echo -e "\n${BLUE}--- [6/6] HELM RELEASES ---${NC}"

    helm list -A -o json 2>/dev/null | jq -r '
        ["NAMESPACE", "NAME", "REVISION", "UPDATED", "STATUS", "CHART", "APP_VERSION"],
        (.[] | [
            .namespace,
            .name,
            .revision,
            (.updated | split(".") | .[0] | sub("T"; " ")),
            .status,
            .chart,
            .app_version
        ]) | @tsv
    ' | column -t -s $'\t' | awk '
    NR==1{print "'"${YELLOW}"'" $0 "'"${NC}"'"}
    NR>1{
        line=$0;
        if (line ~ /deployed/) sub("deployed", "'"${GREEN}"'deployed'"${NC}"'", line);
        else if (line ~ /failed/) sub("failed", "'"${RED}"'failed'"${NC}"'", line);
        else if (line ~ /pending/) sub("pending", "'"${YELLOW}"'pending'"${NC}"'", line);
        print line;
    }'
}

# ======================== EXPORT & MAIN ========================
generate_full_report() {
    echo "K3s Cluster Check — $(date '+%Y-%m-%d %H:%M:%S')"
    echo "================================================="
    section_timed section_sys
    section_timed section_node
    section_timed section_secrets
    section_timed section_pvc
    section_timed section_res
    section_timed section_img
    section_timed section_helm
    echo -e "\n>>> Kiểm tra hoàn tất!"
}

do_export() {
    local compact=false
    [ "$1" = "-c" ] || [ "$1" = "--compact" ] && compact=true

    mkdir -p "$CK_DIR"
    local ts=$(date +"%H%M%S-%d%m%y")
    local suffix=$($compact && echo "-compact" || echo "")
    local outfile="$CK_DIR/ck-${ts}${suffix}.txt"

    if $compact; then
        echo -e "${YELLOW}>>> Compact mode không hỗ trợ ở phiên bản rút gọn này. Xin dùng bản full.${NC}"
        return
    else
        generate_full_report | strip_colors > "$outfile"
    fi

    local size=$(du -h "$outfile" | awk '{print $1}')
    local lines=$(wc -l < "$outfile")
    echo -e "${GREEN}✔ Exported: $outfile ($lines lines, $size)${NC}"
}

check_dependencies

case "${1:-}" in
    -h|--help)
        echo "K3s Cluster Check"
        echo ""
        echo "Cú pháp: ./ck.sh [section] [args]"
        echo ""
        echo "Sections:"
        echo "  sys       Hệ thống & tải (CPU, RAM, Disk)"
        echo "  node      Topology, nodes, pod layout"
        echo "  pvc       Persistent Volume Claims"
        echo "  res [ns]  Workloads, HPA, Services (filter by namespace)"
        echo "  img       Container images & usage"
        echo "  helm      Helm releases"
        echo "  secrets   Secrets (theo namespace)"
        echo "  export    Xuất report ra file (./ck/)"
        echo ""
        echo "Không có argument = chạy tất cả sections"
        ;;
    sys) section_sys ;;
    node|pod) check_k3s_connection; section_node ;;
    pvc) check_k3s_connection; section_pvc ;;
    res) check_k3s_connection; section_res "${2:-}" ;;
    img) check_k3s_connection; section_img ;;
    helm) check_k3s_connection; section_helm ;;
    secrets) check_k3s_connection; section_secrets ;;
    export)
        check_k3s_connection
        echo -e "${YELLOW}>>> Đang export...${NC}"
        do_export "${2:-}"
        ;;
    *)
        check_k3s_connection
        echo -e "${YELLOW}>>> Đang thu thập dữ liệu từ K3s API...${NC}"
        generate_full_report
        ;;
esac
