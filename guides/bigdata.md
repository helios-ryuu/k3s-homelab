# BigData — Hadoop + Spark

> Namespace: `bigdata` | Script: `svc-scripts/bigdata.sh` | Chart: local `bigdata/`

---

## Node Labels

| Label | Role |
|-------|------|
| `node-role.kubernetes.io/bigdata-master=true` | NameNode, ResourceManager, Spark Master |
| `node-role.kubernetes.io/bigdata-worker=true` | DataNode, NodeManager, Spark Worker |

```bash
kubectl label node <node> node-role.kubernetes.io/bigdata-master=true
kubectl label node <node> node-role.kubernetes.io/bigdata-worker=true
```

---

## Helm Chart

```
bigdata/
├── Chart.yaml
├── values.yaml             ← workers.replicas, images, resources
└── templates/
    ├── hadoop-config.yaml    ConfigMap (core/hdfs/yarn/mapred XML)
    ├── hadoop-namenode.yaml  Service + PVC + Deployment (master)
    ├── hadoop-rmgr.yaml      ResourceManager (master)
    ├── hadoop-datanode.yaml  StatefulSet (workers)
    ├── hadoop-nodemgr.yaml   NodeManager StatefulSet (workers)
    ├── spark-config.yaml     ConfigMap (spark-env + defaults.conf)
    ├── spark-master.yaml     Deployment (master)
    └── spark-worker.yaml     StatefulSet (workers)
```

- `workers.replicas` default 2; `dfs.replication` auto-matches worker count
- Hard anti-affinity: master pods excluded from worker nodes, 1 pod/node
- hostPort for WebUI — access via Tailscale IP

---

## Operations

```bash
# Via main dispatcher
./k3s.sh deploy bigdata
./k3s.sh delete bigdata
./k3s.sh redeploy bigdata
./k3s.sh check bigdata

# Via component script directly
./svc-scripts/bigdata.sh deploy
./svc-scripts/bigdata.sh delete
./svc-scripts/bigdata.sh redeploy
./svc-scripts/bigdata.sh scale <N>      # Scale workers (0 = shutdown all)
./svc-scripts/bigdata.sh logs           # Tail NameNode logs
./svc-scripts/bigdata.sh check          # Health check (6 sections)
```

### Scaling

```bash
./svc-scripts/bigdata.sh scale 0    # Shutdown: workers first, then masters
./svc-scripts/bigdata.sh scale 2    # Restore: masters first, then workers
./svc-scripts/bigdata.sh scale 3    # Add a third worker
```

> **Important:** Scaling uses `kubectl scale` directly (not `helm upgrade`) to avoid changing `dfs.replication` which would crash NameNode.

---

## Web UI

| Service | URL |
|---------|-----|
| HDFS NameNode | `http://<master-ip>:9870` |
| YARN ResourceManager | `http://<master-ip>:8088` |
| Spark Master | `http://<any-node-ip>:30808` (NodePort) |
| DataNode | `http://<worker-ip>:9864` |
| NodeManager | `http://<worker-ip>:8042` |
| Spark Worker | `http://<worker-ip>:8081` |

---

## Health Check Sections

`./svc-scripts/bigdata.sh check` runs 6 checks:

1. **Pod Status** — all 9 expected pods (3 masters + 6 workers)
2. **HDFS** — NameNode report, live DataNodes, capacity, under-replicated/missing/corrupt blocks, read/write test
3. **YARN** — ResourceManager active status, registered NodeManagers, cluster resources
4. **Spark** — Master API status, registered workers (cores/mem/state)
5. **Cross-Component** — Spark → HDFS NameNode connectivity, Spark binary check
6. **External Endpoints** — HDFS WebUI, YARN WebUI, Spark WebUI reachability via Tailscale

---

## Lab Commands

### Get Spark Master pod

```bash
MASTER_POD=$(kubectl get pods -n bigdata -l app=spark-master -o jsonpath="{.items[0].metadata.name}")
```

### HDFS basics

```bash
kubectl exec -n bigdata $MASTER_POD -- /bin/bash -c \
  "export HADOOP_USER_NAME=root && \
   /opt/spark/bin/spark-class org.apache.hadoop.fs.FsShell -mkdir -p /user/<username> && \
   /opt/spark/bin/spark-class org.apache.hadoop.fs.FsShell -put -f /opt/hadoop/conf/core-site.xml /user/<username>/input.txt && \
   /opt/spark/bin/spark-class org.apache.hadoop.fs.FsShell -ls /user/<username>/"
```

HDFS commands: `-ls`, `-cat`, `-get`, `-rm`, `-cp`, `-mv`, `-count`

### WordCount — RDD

```bash
kubectl exec -it -n bigdata $MASTER_POD -- /bin/bash -c \
  "export HADOOP_USER_NAME=root && \
   /opt/spark/bin/spark-submit \
     --master spark://spark-master:7077 \
     --conf spark.hadoop.fs.defaultFS=hdfs://hadoop-namenode:9000 \
     --conf spark.driver.host=\$MY_POD_IP \
     /opt/spark/examples/src/main/python/wordcount.py \
     hdfs://hadoop-namenode:9000/user/<username>/input.txt"
```

### Pi Estimation

```bash
kubectl exec -it -n bigdata $MASTER_POD -- /bin/bash -c \
  "export HADOOP_USER_NAME=root && \
   /opt/spark/bin/spark-submit \
     --master spark://spark-master:7077 \
     --conf spark.driver.host=\$MY_POD_IP \
     /opt/spark/examples/src/main/python/pi.py 100"
```

### PySpark Interactive — DataFrame, SQL, MLLib

```bash
kubectl exec -it -n bigdata $MASTER_POD -- /opt/spark/bin/pyspark \
  --master spark://spark-master:7077 \
  --conf spark.driver.host=$MY_POD_IP \
  --conf spark.hadoop.fs.defaultFS=hdfs://hadoop-namenode:9000
```

### GraphFrames

```bash
kubectl exec -it -n bigdata $MASTER_POD -- /opt/spark/bin/pyspark \
  --master spark://spark-master:7077 \
  --conf spark.driver.host=$MY_POD_IP \
  --conf spark.hadoop.fs.defaultFS=hdfs://hadoop-namenode:9000 \
  --packages graphframes:graphframes:0.8.4-spark3.5-s_2.12
```

---

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| YARN 0 NodeManagers | Missing ports 8030-8033 on RM Service | Check `hadoop-rmgr.yaml` service ports |
| Pod Pending | Worker node offline | Wait for node or `./svc-scripts/bigdata.sh scale` down |
| HDFS write fails | DataNodes not yet registered (30-60s after deploy) | Wait and retry |
| NameNode crash on upgrade | `dfs.replication` changed via helm upgrade | Use `./svc-scripts/bigdata.sh scale` instead |
