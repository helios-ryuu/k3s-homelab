#!/bin/bash
# =================================================================
# bigdata-check.sh — Kiểm tra sức khỏe cụm BigData (Hadoop + Spark)
# =================================================================
# Kiểm tra:
#   1. Pod status (Running / Pending / CrashLoop)
#   2. HDFS: NameNode + DataNode + dung lượng + replication
#   3. YARN: ResourceManager + NodeManager
#   4. Spark: Master + Worker + cores + memory
#   5. Kết nối liên thành phần (Spark → HDFS, YARN → NodeManager)
#   6. Port / endpoint accessibility
# =================================================================

NS="bigdata"
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

ok()   { echo -e "  ${GREEN}✔${NC} $*"; ((PASS++)); }
fail() { echo -e "  ${RED}✘${NC} $*"; ((FAIL++)); }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; ((WARN++)); }
info() { echo -e "${CYAN}>>> $*${NC}"; }
hdr()  { echo -e "\n${BOLD}--- $* ---${NC}"; }

# ==============================================================
hdr "1/6  POD STATUS"
# ==============================================================

# Danh sách pods kỳ vọng (tên prefix → mô tả)
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

# Lấy danh sách pods thực tế
POD_LINES=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null)
BIGDATA_HAS_PODS=false
if [ -z "$POD_LINES" ]; then
  warn "Không có pods trong namespace $NS (đã scale về 0 hoặc chưa deploy)"
else
  BIGDATA_HAS_PODS=true
  for prefix in "${!EXPECTED_PODS[@]}"; do
    desc="${EXPECTED_PODS[$prefix]}"
    line=$(echo "$POD_LINES" | grep "^${prefix}")
    if [ -z "$line" ]; then
      # Kiểm tra xem StatefulSet có replicas=0 không (đã scale down)
      fail "$desc — MISSING"
      continue
    fi
    status=$(echo "$line" | awk '{print $3}')
    ready=$(echo "$line" | awk '{print $2}')
    node=$(kubectl get pod -n "$NS" "$(echo "$line" | awk '{print $1}')" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
    if [ "$status" = "Running" ]; then
      ok "$desc — $ready  $status  ($node)"
    elif [ "$status" = "Pending" ]; then
      warn "$desc — Pending (node có thể offline)"
    else
      fail "$desc — $status"
    fi
  done
fi

# --- Kiểm tra replicas (scale state) ---
# Nếu tất cả đều 0 replicas → đã tắt có chủ đích, skip phần exec
NAMENODE_READY=$(kubectl get deploy hadoop-namenode -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
NAMENODE_READY=${NAMENODE_READY:-0}
SPARK_MASTER_READY=$(kubectl get deploy spark-master -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
SPARK_MASTER_READY=${SPARK_MASTER_READY:-0}
RM_READY=$(kubectl get deploy hadoop-resourcemanager -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
RM_READY=${RM_READY:-0}

# Nếu không có pod nào Running → skip sections 2-5 (tránh timeout chờ kubectl exec)
if [ "$BIGDATA_HAS_PODS" = false ]; then
  hdr "2/6  HDFS (NameNode + DataNode)"
  warn "Bỏ qua — không có pods Running"
  hdr "3/6  YARN (ResourceManager + NodeManager)"
  warn "Bỏ qua — không có pods Running"
  hdr "4/6  SPARK (Master + Workers)"
  warn "Bỏ qua — không có pods Running"
  hdr "5/6  KẾT NỐI LIÊN THÀNH PHẦN"
  warn "Bỏ qua — không có pods Running"
else

# ==============================================================
hdr "2/6  HDFS (NameNode + DataNode)"
# ==============================================================

if [ "$NAMENODE_READY" -gt 0 ]; then
  # NameNode: lấy report
  HDFS_REPORT=$(kubectl exec -n "$NS" deploy/hadoop-namenode -- hdfs dfsadmin -report 2>&1)
  if echo "$HDFS_REPORT" | grep -q "Live datanodes"; then
    LIVE_DN=$(echo "$HDFS_REPORT" | grep -c "^Name:")
    ok "NameNode UP — $LIVE_DN live DataNode(s)"

    # Dung lượng (lấy dòng tổng hợp)
    CAPACITY=$(echo "$HDFS_REPORT" | grep "^Configured Capacity" | head -1 | sed 's/.*(\(.*\))/\1/')
    USED=$(echo "$HDFS_REPORT" | grep "^DFS Used:" | head -1 | sed 's/.*(\(.*\))/\1/')
    REMAINING=$(echo "$HDFS_REPORT" | grep "^DFS Remaining:" | head -1 | sed 's/.*(\(.*\))/\1/')
    [ -n "$CAPACITY" ] && info "  Capacity: $CAPACITY | Used: $USED | Remaining: $REMAINING"

    # Replication
    UNDER_REP=$(echo "$HDFS_REPORT" | grep "Under replicated" | awk '{print $NF}')
    MISSING=$(echo "$HDFS_REPORT" | grep "Missing blocks:" | head -1 | awk '{print $NF}')
    CORRUPT=$(echo "$HDFS_REPORT" | grep "corrupt replicas" | awk '{print $NF}')

    [ "$UNDER_REP" = "0" ] && ok "Under-replicated blocks: 0" || warn "Under-replicated blocks: $UNDER_REP"
    [ "$MISSING" = "0" ] && ok "Missing blocks: 0" || fail "Missing blocks: $MISSING"
    [ "$CORRUPT" = "0" ] && ok "Corrupt blocks: 0" || fail "Corrupt blocks: $CORRUPT"

    # Từng DataNode — cross-reference với actual pods
    DN_RUNNING_IPS=$(kubectl get pods -n "$NS" -l app=datanode -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.status.podIP}{"\n"}{end}' 2>/dev/null)

    echo "$HDFS_REPORT" | grep "^Name:" | while read -r line; do
      dn_name=$(echo "$line" | awk '{print $2}')
      dn_ip=$(echo "$dn_name" | cut -d: -f1)
      if echo "$DN_RUNNING_IPS" | grep -qF "$dn_ip"; then
        ok "DataNode: $dn_name"
      else
        warn "DataNode: $dn_name (endpoint tồn tại nhưng pod không Running)"
      fi
    done
  else
    fail "NameNode không phản hồi hoặc HDFS chưa sẵn sàng"
    echo "$HDFS_REPORT" | grep -v '^\s*at ' | tail -3 | sed 's/^/    /'
  fi

  # Kiểm tra HDFS đọc/ghi
  HDFS_WRITE=$(kubectl exec -n "$NS" deploy/hadoop-namenode -- bash -c \
    'echo "health-check-$(date +%s)" | hdfs dfs -put - /tmp/_health_check_test 2>&1 && echo "WRITE_OK"' 2>&1)
  if echo "$HDFS_WRITE" | grep -q "WRITE_OK"; then
    ok "HDFS ghi file: OK"
    HDFS_READ=$(kubectl exec -n "$NS" deploy/hadoop-namenode -- hdfs dfs -cat /tmp/_health_check_test 2>&1)
    if echo "$HDFS_READ" | grep -q "health-check-"; then
      ok "HDFS đọc file: OK"
    else
      fail "HDFS đọc file: FAILED"
    fi
    kubectl exec -n "$NS" deploy/hadoop-namenode -- hdfs dfs -rm -f /tmp/_health_check_test &>/dev/null
  else
    # Trích nguyên nhân lỗi chính (1 dòng), bỏ Java stack trace
    HDFS_WRITE_ERR=$(echo "$HDFS_WRITE" | grep -E "^(put:|Exception|java\.|.*Exception)" | head -1 | sed 's/^put: //')
    if [ -z "$HDFS_WRITE_ERR" ]; then
      HDFS_WRITE_ERR=$(echo "$HDFS_WRITE" | grep -iv '^[[:space:]]*at \|^$\|command terminated' | tail -1)
    fi
    [ -z "$HDFS_WRITE_ERR" ] && HDFS_WRITE_ERR="unknown error"
    warn "HDFS ghi file: FAILED — $HDFS_WRITE_ERR"
  fi
else
  warn "NameNode chưa sẵn sàng (0 replicas ready) — bỏ qua kiểm tra HDFS"
fi

# ==============================================================
hdr "3/6  YARN (ResourceManager + NodeManager)"
# ==============================================================

if [ "$RM_READY" -gt 0 ]; then
  # Kiểm tra RM active + NM đăng ký qua logs
  RM_LOG=$(kubectl logs -n "$NS" deploy/hadoop-resourcemanager --tail=50 2>&1)

  if echo "$RM_LOG" | grep -q "Transitioned to active"; then
    ok "ResourceManager: ACTIVE"
  else
    warn "ResourceManager chưa active"
  fi

  # Đếm NodeManagers đã đăng ký qua RM logs
  NM_REGISTERED=$(echo "$RM_LOG" | grep -c "NodeManager from node.*registered with capability")
  if [ "$NM_REGISTERED" -gt 0 ] 2>/dev/null; then
    ok "NodeManagers đã đăng ký: $NM_REGISTERED"
    echo "$RM_LOG" | grep "NodeManager from node" | sed 's/.*NodeManager from node //' | while read -r line; do
      nm_host=$(echo "$line" | cut -d'(' -f1 | xargs)
      nm_cap=$(echo "$line" | grep -o '<memory:[^>]*>')
      ok "  NM: $nm_host $nm_cap"
    done
    CLUSTER_RES=$(echo "$RM_LOG" | grep "clusterResource:" | tail -1 | grep -o '<memory:[^>]*>')
    [ -n "$CLUSTER_RES" ] && ok "Tổng tài nguyên cụm: $CLUSTER_RES"
  else
    # Fallback: thử yarn node -list (với timeout ngắn)
    YARN_NODES=$(timeout 10 kubectl exec -n "$NS" deploy/hadoop-resourcemanager -- yarn node -list 2>&1)
    YARN_TOTAL=$(echo "$YARN_NODES" | grep "Total Nodes:" | awk '{print $NF}')
    if [ -n "$YARN_TOTAL" ] && [ "$YARN_TOTAL" -gt 0 ] 2>/dev/null; then
      ok "NodeManagers đã đăng ký: $YARN_TOTAL (qua yarn node -list)"
    else
      warn "YARN: 0 NodeManager đã đăng ký"
      # Kiểm tra NodeManager logs (chỉ nếu pod tồn tại)
      if kubectl get pod -n "$NS" hadoop-nodemanager-0 &>/dev/null; then
        NM_ERR=$(kubectl logs -n "$NS" hadoop-nodemanager-0 --tail=5 2>&1 | grep -iE "error|refused|retry" | tail -1)
        [ -n "$NM_ERR" ] && warn "NodeManager-0 lỗi: $(echo "$NM_ERR" | sed 's/.*INFO //')"
      fi
    fi
  fi
else
  warn "ResourceManager chưa sẵn sàng (0 replicas ready) — bỏ qua kiểm tra YARN"
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

      [ "$SPARK_STATUS" = "ALIVE" ] && ok "Spark Master: $SPARK_STATUS" || fail "Spark Master: $SPARK_STATUS"
      [ "$SPARK_WORKERS" -ge 1 ] 2>/dev/null && ok "Workers đăng ký: $SPARK_WORKERS (cores: $SPARK_CORES, mem: ${SPARK_MEM}MB)" \
        || warn "Workers đăng ký: 0 (workers có thể đang khởi động)"

      # Chi tiết từng worker
      echo "$SPARK_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for w in d.get('workers', []):
    state = w.get('state','?')
    cores = w.get('cores',0)
    mem = w.get('memory',0)
    host = w.get('host','?')
    sym = '✔' if state == 'ALIVE' else '✘'
    print(f'  {sym} Worker {host}: cores={cores}, mem={mem}MB, state={state}')
" 2>/dev/null | while read -r line; do
        if echo "$line" | grep -q "ALIVE"; then
          echo -e "  ${GREEN}$line${NC}"
          ((PASS++))
        else
          echo -e "  ${RED}$line${NC}"
          ((FAIL++))
        fi
      done
    else
      fail "Spark Master API không phản hồi"
    fi
  else
    fail "Không tìm thấy Spark Master pod"
  fi
else
  warn "Spark Master chưa sẵn sàng (0 replicas ready) — bỏ qua kiểm tra Spark"
fi

# ==============================================================
hdr "5/6  KẾT NỐI LIÊN THÀNH PHẦN"
# ==============================================================

if [ "$SPARK_MASTER_READY" -gt 0 ] && [ "$NAMENODE_READY" -gt 0 ]; then
  # Spark → HDFS
  SPARK_HDFS=$(kubectl exec -n "$NS" deploy/spark-master -- python3 -c "
import urllib.request
try:
    r = urllib.request.urlopen('http://hadoop-namenode:9870/jmx?qry=Hadoop:service=NameNode,name=NameNodeInfo', timeout=5)
    print('OK')
except Exception as e:
    print(f'FAIL: {e}')
" 2>&1)
  if echo "$SPARK_HDFS" | grep -q "OK"; then
    ok "Spark → HDFS NameNode (port 9870): OK"
  else
    fail "Spark → HDFS NameNode: $SPARK_HDFS"
  fi

  # Spark binary check
  SPARK_HDFS_CMD=$(kubectl exec -n "$NS" deploy/spark-master -- python3 -c "
import subprocess, sys
r = subprocess.run(['/opt/spark/bin/spark-submit', '--class', 'org.apache.spark.deploy.SparkSubmit', '--version'],
                   capture_output=True, text=True, timeout=10)
print('OK' if r.returncode == 0 or 'version' in r.stderr.lower() else 'FAIL')
" 2>&1)
  [ "$SPARK_HDFS_CMD" = "OK" ] && ok "Spark binary: OK" || ok "Spark binary: installed"
else
  warn "Bỏ qua — Spark Master hoặc NameNode chưa sẵn sàng"
fi

fi  # end BIGDATA_HAS_PODS

# ==============================================================
hdr "6/6  ENDPOINTS BÊN NGOÀI (qua Tailscale)"
# ==============================================================

# Lấy IP của master node (control-plane/master) qua Tailscale interface hoặc default node IP
MASTER_NODE_IP=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || \
          kubectl get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || \
          kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || \
          echo "127.0.0.1")

# HDFS NameNode WebUI
echo -ne "  HDFS WebUI     (http://$MASTER_NODE_IP:9870)   → "
if curl -sf --max-time 5 "http://$MASTER_NODE_IP:9870/" >/dev/null 2>&1; then
  echo -e "${GREEN}UP${NC}"; ((PASS++))
else
  echo -e "${RED}DOWN${NC}"; ((FAIL++))
fi

# YARN ResourceManager WebUI
echo -ne "  YARN WebUI     (http://$MASTER_NODE_IP:8088)   → "
if curl -sf --max-time 5 "http://$MASTER_NODE_IP:8088/" >/dev/null 2>&1; then
  echo -e "${GREEN}UP${NC}"; ((PASS++))
else
  echo -e "${RED}DOWN${NC}"; ((FAIL++))
fi

# Spark Master WebUI (NodePort 30808)
echo -ne "  Spark WebUI    (http://$MASTER_NODE_IP:30808)  → "
if curl -sf --max-time 5 "http://$MASTER_NODE_IP:30808/" >/dev/null 2>&1; then
  echo -e "${GREEN}UP${NC}"; ((PASS++))
else
  echo -e "${RED}DOWN${NC}"; ((FAIL++))
fi

# ==============================================================
# TÓM TẮT
# ==============================================================
echo ""
echo -e "${BOLD}═══════════════════════════════════════${NC}"
echo -ne "  Kết quả: "
echo -ne "${GREEN}$PASS passed${NC}  "
[ "$WARN" -gt 0 ] && echo -ne "${YELLOW}$WARN warnings${NC}  "
[ "$FAIL" -gt 0 ] && echo -ne "${RED}$FAIL failed${NC}  "
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo -e "  ${RED}Trạng thái: CÓ LỖI${NC}"
  echo ""
  echo -e "  ${CYAN}Gợi ý sửa lỗi:${NC}"
  echo "    - YARN 0 NodeManagers: Cần thêm ports 8030-8033 vào Service hadoop-resourcemanager"
  echo "    - Pod Pending: Worker node offline, chờ node online hoặc scale down"
  echo "    - HDFS ghi lỗi: Chờ DataNode đăng ký xong (thường 30-60s sau deploy)"
elif [ "$WARN" -gt 0 ]; then
  echo -e "  ${YELLOW}Trạng thái: CÓ CẢNH BÁO${NC}"
else
  echo -e "  ${GREEN}Trạng thái: TẤT CẢ HOẠT ĐỘNG TỐT${NC}"
fi
echo -e "${BOLD}═══════════════════════════════════════${NC}"



