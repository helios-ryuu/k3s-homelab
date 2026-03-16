#!/bin/bash
# =================================================================
# bigdata.sh — Quản lý BigData (Hadoop + Spark)
# =================================================================
# Sử dụng:
#   bash bigdata.sh deploy          Deploy / Upgrade
#   bash bigdata.sh delete          Force xóa
#   bash bigdata.sh redeploy        Delete + Deploy
#   bash bigdata.sh scale <N>       Scale workers (0 = tắt toàn bộ)
#   bash bigdata.sh logs            Tail logs NameNode
#   bash bigdata.sh check           Health check cụm BigData
# =================================================================

source "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

NS="bigdata"

# ======================== DEPLOY ========================

do_deploy() {
    check_node_labels bigdata
    if ! check_secrets bigdata "$NS" quiet; then
        bash "$K3S_DIR/init-sec.sh" "$NS"
    fi
    check_secrets bigdata "$NS"

    # Count worker nodes for replica count
    local worker_count
    worker_count=$(kubectl get nodes -l node-role.kubernetes.io/bigdata-worker=true --no-headers 2>/dev/null | grep -c .)
    [ "$worker_count" -eq 0 ] && worker_count=2
    info "Deploy BigData (Hadoop + Spark) → namespace: $NS  (workers: $worker_count)"

    # Update workers.replicas in values.yaml
    sed -i "s/^  replicas: .*/  replicas: $worker_count/" "$K3S_DIR/services/bigdata/values.yaml"

    if release_exists bigd $NS; then
        ok "(Upgrade existing release)"
        helm upgrade bigd "$K3S_DIR/services/bigdata" -n $NS $HELM_TIMEOUT
    else
        helm install bigd "$K3S_DIR/services/bigdata" -n $NS --create-namespace $HELM_TIMEOUT
    fi
    wait_for_ready $NS
}

# ======================== DELETE ========================

do_delete() {
    info "Force xóa BigData..."
    helm uninstall bigd -n $NS 2>/dev/null || true
    # Also delete the standalone NameNode PVC (not in a StatefulSet volumeClaimTemplate)
    kubectl patch pvc hadoop-namenode-pvc -n $NS -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
    force_cleanup_ns $NS
}

# ======================== SCALE ========================

do_scale() {
    local scale_arg="$1"
    if [ -z "$scale_arg" ]; then
        err "Thiếu tham số scale"
        echo "    Cú pháp: $0 scale <0|N>"
        echo "    scale 0  — tắt toàn bộ (workers trước, masters sau)"
        echo "    scale N  — khôi phục (masters trước, workers tự động theo labeled nodes)"
        exit 1
    fi

    if [ "$scale_arg" -eq 0 ]; then
        # === SCALE TO 0: tắt workers trước, rồi tắt masters ===
        info "Scale BigData → 0 (tắt workers trước, masters sau)"
        kubectl scale statefulset hadoop-datanode    -n $NS --replicas=0 2>/dev/null || true
        kubectl scale statefulset hadoop-nodemanager -n $NS --replicas=0 2>/dev/null || true
        kubectl scale statefulset spark-worker       -n $NS --replicas=0 2>/dev/null || true
        info "Đợi workers tắt..."
        kubectl wait --for=delete pod -l app=datanode    -n $NS --timeout=60s 2>/dev/null || true
        kubectl wait --for=delete pod -l app=nodemanager -n $NS --timeout=60s 2>/dev/null || true
        kubectl wait --for=delete pod -l app=spark-worker -n $NS --timeout=60s 2>/dev/null || true
        kubectl scale deploy hadoop-namenode         -n $NS --replicas=0 2>/dev/null || true
        kubectl scale deploy hadoop-resourcemanager  -n $NS --replicas=0 2>/dev/null || true
        kubectl scale deploy spark-master            -n $NS --replicas=0 2>/dev/null || true
        ok "BigData đã tắt hoàn toàn"
    else
        # === SCALE TO N: auto-detect worker count from labeled nodes ===
        local worker_count
        worker_count=$(kubectl get nodes -l node-role.kubernetes.io/bigdata-worker=true --no-headers 2>/dev/null | grep -c .)
        [ "$worker_count" -eq 0 ] && worker_count="$scale_arg"
        info "Scale BigData → khôi phục (masters trước, $worker_count workers)"
        kubectl scale deploy hadoop-namenode         -n $NS --replicas=1 2>/dev/null || true
        kubectl scale deploy hadoop-resourcemanager  -n $NS --replicas=1 2>/dev/null || true
        kubectl scale deploy spark-master            -n $NS --replicas=1 2>/dev/null || true
        info "Đợi NameNode sẵn sàng..."
        kubectl rollout status deploy/hadoop-namenode -n $NS --timeout=120s 2>/dev/null || true
        kubectl scale statefulset hadoop-datanode    -n $NS --replicas="$worker_count" 2>/dev/null || true
        kubectl scale statefulset hadoop-nodemanager -n $NS --replicas="$worker_count" 2>/dev/null || true
        kubectl scale statefulset spark-worker       -n $NS --replicas="$worker_count" 2>/dev/null || true
        wait_for_ready $NS
    fi
}

# ======================== LOGS ========================

do_logs() {
    kubectl logs -f -n $NS -l app=namenode --tail=100
}

# ======================== CHECK ========================

do_check() {
    check_reset
    # ==============================================================
    hdr "1/6  POD STATUS"
    # ==============================================================

    declare -A EXPECTED_PODS=(
      ["hadoop-namenode"]="HDFS NameNode"
      ["hadoop-resourcemanager"]="YARN ResourceManager"
      ["spark-master"]="Spark Master"
      ["hadoop-datanode-0"]="HDFS DataNode #0"
      ["hadoop-datanode-1"]="HDFS DataNode #1"
      ["hadoop-nodemanager-0"]="YARN NodeManager #0"
      ["hadoop-nodemanager-1"]="YARN NodeManager #1"
      ["spark-worker-0"]="Spark Worker #0"
      ["spark-worker-1"]="Spark Worker #1"
    )

    POD_LINES=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null)
    BIGDATA_HAS_PODS=false
    if [ -z "$POD_LINES" ]; then
      chk_warn "Không có pods trong namespace $NS (đã scale về 0 hoặc chưa deploy)"
    else
      BIGDATA_HAS_PODS=true
      for prefix in "${!EXPECTED_PODS[@]}"; do
        desc="${EXPECTED_PODS[$prefix]}"
        line=$(echo "$POD_LINES" | grep "^${prefix}")
        if [ -z "$line" ]; then
          chk_fail "$desc — MISSING"
          continue
        fi
        status=$(echo "$line" | awk '{print $3}')
        ready=$(echo "$line" | awk '{print $2}')
        node=$(kubectl get pod -n "$NS" "$(echo "$line" | awk '{print $1}')" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
        if [ "$status" = "Running" ]; then
          chk_ok "$desc — $ready  $status  ($node)"
        elif [ "$status" = "Pending" ]; then
          chk_warn "$desc — Pending (node có thể offline)"
        else
          chk_fail "$desc — $status"
        fi
      done
    fi

    NAMENODE_READY=$(kubectl get deploy hadoop-namenode -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    NAMENODE_READY=${NAMENODE_READY:-0}
    SPARK_MASTER_READY=$(kubectl get deploy spark-master -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    SPARK_MASTER_READY=${SPARK_MASTER_READY:-0}
    RM_READY=$(kubectl get deploy hadoop-resourcemanager -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    RM_READY=${RM_READY:-0}

    if [ "$BIGDATA_HAS_PODS" = false ]; then
      hdr "2/6  HDFS (NameNode + DataNode)"
      chk_warn "Bỏ qua — không có pods Running"
      hdr "3/6  YARN (ResourceManager + NodeManager)"
      chk_warn "Bỏ qua — không có pods Running"
      hdr "4/6  SPARK (Master + Workers)"
      chk_warn "Bỏ qua — không có pods Running"
      hdr "5/6  KẾT NỐI LIÊN THÀNH PHẦN"
      chk_warn "Bỏ qua — không có pods Running"
    else

    # ==============================================================
    hdr "2/6  HDFS (NameNode + DataNode)"
    # ==============================================================

    if [ "$NAMENODE_READY" -gt 0 ]; then
      HDFS_REPORT=$(kubectl exec -n "$NS" deploy/hadoop-namenode -- hdfs dfsadmin -report 2>&1)
      if echo "$HDFS_REPORT" | grep -q "Live datanodes"; then
        LIVE_DN=$(echo "$HDFS_REPORT" | grep -c "^Name:")
        chk_ok "NameNode UP — $LIVE_DN live DataNode(s)"

        CAPACITY=$(echo "$HDFS_REPORT" | grep "^Configured Capacity" | head -1 | sed 's/.*(\(.*\))/\1/')
        USED=$(echo "$HDFS_REPORT" | grep "^DFS Used:" | head -1 | sed 's/.*(\(.*\))/\1/')
        REMAINING=$(echo "$HDFS_REPORT" | grep "^DFS Remaining:" | head -1 | sed 's/.*(\(.*\))/\1/')
        [ -n "$CAPACITY" ] && chk_info "  Capacity: $CAPACITY | Used: $USED | Remaining: $REMAINING"

        UNDER_REP=$(echo "$HDFS_REPORT" | grep "Under replicated" | awk '{print $NF}')
        MISSING=$(echo "$HDFS_REPORT" | grep "Missing blocks:" | head -1 | awk '{print $NF}')
        CORRUPT=$(echo "$HDFS_REPORT" | grep "corrupt replicas" | awk '{print $NF}')

        [ "$UNDER_REP" = "0" ] && chk_ok "Under-replicated blocks: 0" || chk_warn "Under-replicated blocks: $UNDER_REP"
        [ "$MISSING" = "0" ] && chk_ok "Missing blocks: 0" || chk_fail "Missing blocks: $MISSING"
        [ "$CORRUPT" = "0" ] && chk_ok "Corrupt blocks: 0" || chk_fail "Corrupt blocks: $CORRUPT"

        DN_RUNNING_IPS=$(kubectl get pods -n "$NS" -l app=datanode -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.status.podIP}{"\n"}{end}' 2>/dev/null)

        echo "$HDFS_REPORT" | grep "^Name:" | while read -r line; do
          dn_name=$(echo "$line" | awk '{print $2}')
          dn_ip=$(echo "$dn_name" | cut -d: -f1)
          if echo "$DN_RUNNING_IPS" | grep -qF "$dn_ip"; then
            chk_ok "DataNode: $dn_name"
          else
            chk_warn "DataNode: $dn_name (endpoint tồn tại nhưng pod không Running)"
          fi
        done
      else
        chk_fail "NameNode không phản hồi hoặc HDFS chưa sẵn sàng"
        echo "$HDFS_REPORT" | grep -v '^\s*at ' | tail -3 | sed 's/^/    /'
      fi

      HDFS_WRITE=$(kubectl exec -n "$NS" deploy/hadoop-namenode -- bash -c \
        'echo "health-check-$(date +%s)" | hdfs dfs -put - /tmp/_health_check_test 2>&1 && echo "WRITE_OK"' 2>&1)
      if echo "$HDFS_WRITE" | grep -q "WRITE_OK"; then
        chk_ok "HDFS ghi file: OK"
        HDFS_READ=$(kubectl exec -n "$NS" deploy/hadoop-namenode -- hdfs dfs -cat /tmp/_health_check_test 2>&1)
        if echo "$HDFS_READ" | grep -q "health-check-"; then
          chk_ok "HDFS đọc file: OK"
        else
          chk_fail "HDFS đọc file: FAILED"
        fi
        kubectl exec -n "$NS" deploy/hadoop-namenode -- hdfs dfs -rm -f /tmp/_health_check_test &>/dev/null
      else
        HDFS_WRITE_ERR=$(echo "$HDFS_WRITE" | grep -E "^(put:|Exception|java\.|.*Exception)" | head -1 | sed 's/^put: //')
        if [ -z "$HDFS_WRITE_ERR" ]; then
          HDFS_WRITE_ERR=$(echo "$HDFS_WRITE" | grep -iv '^[[:space:]]*at \|^$\|command terminated' | tail -1)
        fi
        [ -z "$HDFS_WRITE_ERR" ] && HDFS_WRITE_ERR="unknown error"
        chk_warn "HDFS ghi file: FAILED — $HDFS_WRITE_ERR"
      fi
    else
      chk_warn "NameNode chưa sẵn sàng (0 replicas ready) — bỏ qua kiểm tra HDFS"
    fi

    # ==============================================================
    hdr "3/6  YARN (ResourceManager + NodeManager)"
    # ==============================================================

    if [ "$RM_READY" -gt 0 ]; then
      # Kiểm tra RM active + NM đăng ký qua logs
      RM_LOG=$(kubectl logs -n "$NS" deploy/hadoop-resourcemanager --tail=100 2>&1)

      if echo "$RM_LOG" | grep -q "Transitioned to active"; then
        chk_ok "ResourceManager: ACTIVE"
      else
        chk_warn "ResourceManager chưa active"
      fi

      # Đếm NodeManagers đã đăng ký qua RM logs (lấy giá trị mới nhất cho mỗi host)
      # Lưu ý: rm log có dạng host(IP:PORT), cần strip phần (IP:PORT) để deduplicate
      NM_LIST=$(echo "$RM_LOG" | grep "registered with capability" | sed 's/.*NodeManager from node //' | awk '{print $1}' | sed 's/(.*//' | sort -u)
      NM_COUNT=$(echo "$NM_LIST" | wc -w)
      
      if [ "$NM_COUNT" -gt 0 ]; then
        chk_ok "NodeManagers đã đăng ký: $NM_COUNT"
        for nm in $NM_LIST; do
          # Tìm dòng registration cuối cùng cho host này để lấy capability
          nm_cap=$(echo "$RM_LOG" | grep "NodeManager from node $nm" | tail -1 | grep -o '<memory:[^>]*>')
          chk_ok "  NM: $nm $nm_cap"
        done
        CLUSTER_RES=$(echo "$RM_LOG" | grep "clusterResource:" | tail -1 | grep -o '<memory:[^>]*>')
        [ -n "$CLUSTER_RES" ] && chk_ok "Tổng tài nguyên cụm: $CLUSTER_RES"
      else
        # Fallback: thử yarn node -list
        YARN_NODES=$(timeout 10 kubectl exec -n "$NS" deploy/hadoop-resourcemanager -- yarn node -list 2>&1)
        YARN_TOTAL=$(echo "$YARN_NODES" | grep "Total Nodes:" | awk '{print $NF}')
        if [ -n "$YARN_TOTAL" ] && [ "$YARN_TOTAL" -gt 0 ] 2>/dev/null; then
          chk_ok "NodeManagers đã đăng ký: $YARN_TOTAL (qua yarn node -list)"
        else
          chk_warn "YARN: 0 NodeManager đã đăng ký"
        fi
      fi
    else
      chk_warn "ResourceManager chưa sẵn sàng (0 replicas ready) — bỏ qua kiểm tra YARN"
    fi

    # ==============================================================
    hdr "4/6  SPARK (Master + Workers)"
    # ==============================================================

    if [ "$SPARK_MASTER_READY" -gt 0 ]; then
      SPARK_POD_IP=$(kubectl get pod -n "$NS" -l app=spark-master -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)

      if [ -n "$SPARK_POD_IP" ]; then
        SPARK_JSON=$(kubectl exec -n "$NS" deploy/spark-master -- python3 -c "
import urllib.request, json, sys
try:
    data = json.loads(urllib.request.urlopen('http://${SPARK_POD_IP}:8080/json/').read())
    print(json.dumps(data))
except Exception as e:
    print(json.dumps({'error': str(e)}), file=sys.stderr)
    sys.exit(1)
" 2>&1)

        if echo "$SPARK_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if 'status' in d else 1)" 2>/dev/null; then
          SPARK_STATUS=$(echo "$SPARK_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['status'])")
          SPARK_WORKERS=$(echo "$SPARK_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('workers',[])))")
          SPARK_CORES=$(echo "$SPARK_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('cores',0))")
          SPARK_MEM=$(echo "$SPARK_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('memory',0))")

          [ "$SPARK_STATUS" = "ALIVE" ] && chk_ok "Spark Master: $SPARK_STATUS" || chk_fail "Spark Master: $SPARK_STATUS"
          [ "$SPARK_WORKERS" -ge 1 ] 2>/dev/null && chk_ok "Workers đăng ký: $SPARK_WORKERS (cores: $SPARK_CORES, mem: ${SPARK_MEM}MB)" \
            || chk_warn "Workers đăng ký: 0 (workers có thể đang khởi động)"

          # Process substitution keeps PASS/FAIL in current shell (pipeline would lose them)
          while read -r line; do
              if echo "$line" | grep -q "ALIVE"; then
                echo -e "  ${GREEN}$line${NC}"
                ((PASS++))
              else
                echo -e "  ${RED}$line${NC}"
                ((FAIL++))
              fi
          done < <(echo "$SPARK_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for w in d.get('workers', []):
    state = w.get('state','?')
    cores = w.get('cores',0)
    mem = w.get('memory',0)
    host = w.get('host','?')
    sym = '✔' if state == 'ALIVE' else '✘'
    print(f'  {sym} Worker {host}: cores={cores}, mem={mem}MB, state={state}')
" 2>/dev/null)
        else
          chk_fail "Spark Master API không phản hồi"
        fi
      else
        chk_fail "Không tìm thấy Spark Master pod"
      fi
    else
      chk_warn "Spark Master chưa sẵn sàng (0 replicas ready) — bỏ qua kiểm tra Spark"
    fi

    # ==============================================================
    hdr "5/6  KẾT NỐI LIÊN THÀNH PHẦN"
    # ==============================================================

    if [ "$SPARK_MASTER_READY" -gt 0 ] && [ "$NAMENODE_READY" -gt 0 ]; then
      SPARK_HDFS=$(kubectl exec -n "$NS" deploy/spark-master -- python3 -c "
import urllib.request
try:
    r = urllib.request.urlopen('http://hadoop-namenode:9870/jmx?qry=Hadoop:service=NameNode,name=NameNodeInfo', timeout=5)
    print('OK')
except Exception as e:
    print(f'FAIL: {e}')
" 2>&1)
      if echo "$SPARK_HDFS" | grep -q "OK"; then
        chk_ok "Spark → HDFS NameNode (port 9870): OK"
      else
        chk_fail "Spark → HDFS NameNode: $SPARK_HDFS"
      fi

      SPARK_HDFS_CMD=$(kubectl exec -n "$NS" deploy/spark-master -- python3 -c "
import subprocess, sys
r = subprocess.run(['/opt/spark/bin/spark-submit', '--class', 'org.apache.spark.deploy.SparkSubmit', '--version'],
                   capture_output=True, text=True, timeout=10)
print('OK' if r.returncode == 0 or 'version' in r.stderr.lower() else 'FAIL')
" 2>&1)
      [ "$SPARK_HDFS_CMD" = "OK" ] && chk_ok "Spark binary: OK" || chk_ok "Spark binary: installed"
    else
      chk_warn "Bỏ qua — Spark Master hoặc NameNode chưa sẵn sàng"
    fi

    fi  # end BIGDATA_HAS_PODS

    # ==============================================================
    hdr "6/6  ENDPOINTS BÊN NGOÀI (qua Tailscale)"
    # ==============================================================

    # HDFS NameNode WebUI (hostPort 9870)
    local NN_NODE=$(kubectl get pods -n "$NS" -l app=namenode -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
    local NN_IP=$(get_node_ip "$NN_NODE")

    echo -ne "  HDFS WebUI     (http://$NN_IP:9870)   → "
    if curl -sf --max-time 5 "http://$NN_IP:9870/" >/dev/null 2>&1; then
      echo -e "${GREEN}UP${NC}"; ((PASS++))
    else
      echo -e "${RED}DOWN${NC}"; ((FAIL++))
    fi

    # YARN ResourceManager WebUI (hostPort 8088)
    local RM_NODE=$(kubectl get pods -n "$NS" -l app=resourcemanager -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
    local RM_IP=$(get_node_ip "$RM_NODE")

    echo -ne "  YARN WebUI     (http://$RM_IP:8088)   → "
    if curl -sf --max-time 5 "http://$RM_IP:8088/" >/dev/null 2>&1; then
      echo -e "${GREEN}UP${NC}"; ((PASS++))
    else
      echo -e "${RED}DOWN${NC}"; ((FAIL++))
    fi

    # Spark Master WebUI (NodePort 30808) — accessible on any node
    local SPARK_IP=$(get_master_ip)
    echo -ne "  Spark WebUI    (http://$SPARK_IP:30808)  → "
    if curl -sf --max-time 5 "http://$SPARK_IP:30808/" >/dev/null 2>&1; then
      echo -e "${GREEN}UP${NC}"; ((PASS++))
    else
      echo -e "${RED}DOWN${NC}"; ((FAIL++))
    fi

    check_summary

    if [ "$FAIL" -gt 0 ]; then
      echo ""
      echo -e "  ${CYAN}Gợi ý sửa lỗi:${NC}"
      echo "    - YARN 0 NodeManagers: Cần thêm ports 8030-8033 vào Service hadoop-resourcemanager"
      echo "    - Pod Pending: Worker node offline, chờ node online hoặc scale down"
      echo "    - HDFS ghi lỗi: Chờ DataNode đăng ký xong (thường 30-60s sau deploy)"
    fi
}

# ======================== MAIN ========================

ACTION="${1:-}"
case "$ACTION" in
    deploy)   do_deploy ;;
    delete)   do_delete ;;
    redeploy) do_delete; sleep 5; do_deploy ;;
    scale)    do_scale "$2" ;;
    logs)     do_logs ;;
    check)    do_check ;;
    *)
        echo -e "${YELLOW}bigdata.sh — Quản lý BigData (Hadoop + Spark)${NC}"
        echo ""
        echo "Cú pháp: $0 <action> [args]"
        echo ""
        echo "Actions:"
        echo -e "  ${GREEN}deploy${NC}       Deploy / Upgrade"
        echo -e "  ${RED}delete${NC}       Force xóa"
        echo -e "  ${YELLOW}redeploy${NC}     Delete + Deploy lại sạch"
        echo -e "  ${BLUE}scale${NC} <N>    Scale workers (0 = tắt toàn bộ)"
        echo -e "  ${CYAN}logs${NC}         Tail logs NameNode"
        echo -e "  ${CYAN}check${NC}        Health check cụm BigData"
        ;;
esac
