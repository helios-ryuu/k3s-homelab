# BigData — Hadoop + Spark

> Namespace: `bigdata` | ArgoCD App: `bigdata` | Chart: local `services/bigdata/`

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
services/bigdata/
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
# Config changes: edit services/bigdata/values.yaml → git push → ArgoCD auto-syncs

# Manual sync trigger (acd helper — see README.md)
acd app sync bigdata
acd app wait bigdata --health

# Logs
kubectl logs -n bigdata -l app=hadoop-namenode -f
kubectl logs -n bigdata -l app=spark-master -f
```

### Scaling

> **Important:** Scale via `kubectl scale` directly — not via `helm upgrade` — to avoid changing `dfs.replication` which would crash NameNode.

```bash
# Shutdown workers
kubectl scale statefulset hadoop-datanode hadoop-nodemgr spark-worker -n bigdata --replicas=0

# Restore / add workers
kubectl scale statefulset hadoop-datanode hadoop-nodemgr spark-worker -n bigdata --replicas=2
```

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

## Health Check

```bash
./ck.sh   # section: Resources → bigdata namespace

# Pod status
kubectl get pods -n bigdata

# HDFS report
kubectl exec -n bigdata deploy/hadoop-namenode -- hdfs dfsadmin -report

# YARN nodes
kubectl exec -n bigdata deploy/hadoop-rmgr -- yarn node -list
```

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
| Pod Pending | Worker node offline | Wait for node or scale down replicas |
| HDFS write fails | DataNodes not yet registered (30-60s after deploy) | Wait and retry |
| NameNode crash on upgrade | `dfs.replication` changed via helm upgrade | Use `kubectl scale` instead |
