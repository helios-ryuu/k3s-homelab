# IS405.Q23 — Dữ liệu lớn (Hadoop + Spark)
> K3s namespace: `bigdata`  |  Quản lý cluster: xem `k3s.md`

---

## 0. Node Labels (Yêu cầu)
Để các pods được đặt đúng node, cụm K3s cần được gắn các label sau:
- **Master/Management node**: `node-role.kubernetes.io/bigdata-master: "true"`
- **Worker nodes**: `node-role.kubernetes.io/bigdata-worker: "true"`

Gán label bằng lệnh:
```bash
kubectl label node <node-name> node-role.kubernetes.io/bigdata-master=true
kubectl label node <node-name> node-role.kubernetes.io/bigdata-worker=true
```

---

## 1. Helm Chart

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

- `workers.replicas` mặc định 1, scale: `kubectl scale statefulset hadoop-datanode -n bigdata --replicas=2` (scale các worker khác tương tự)
- `dfs.replication` tự động = `workers.replicas`
- Hard anti-affinity: cấm master, 1 pod/node
- hostPort cho WebUI → truy cập qua Tailscale IP

---

## 2. Deploy / Xóa

```bash
# Cài đặt lần đầu
helm install bigd bigdata -n bigdata --create-namespace --timeout 2m

# Cập nhật khi có thay đổi trong values.yaml
helm upgrade bigd bigdata -n bigdata --timeout 2m

# Xóa
helm uninstall bigd -n bigdata
kubectl delete ns bigdata
```

---

## 3. Web UI

| Service | URL |
|---|---|
| NameNode | http://<master-ip>:9870 |
| ResourceManager | http://<master-ip>:8088 |
| Spark Master | http://<master-ip>:8080 |
| DataNode | http://<worker-ip-1>:9864 \| http://<worker-ip-2>:9864 |
| NodeManager | http://<worker-ip-1>:8042 \| http://<worker-ip-2>:8042 |
| Spark Worker | http://<worker-ip-1>:8081 \| http://<worker-ip-2>:8081 |

---

## 4. Lệnh thực hành

### Lấy Spark Master pod
```bash
MASTER_POD=$(kubectl get pods -n bigdata -l app=spark-master -o jsonpath="{.items[0].metadata.name}")
```

### HDFS cơ bản (Bài TH 1)
```bash
kubectl exec -n bigdata $MASTER_POD -- /bin/bash -c \
  "export HADOOP_USER_NAME=root && \
   /opt/spark/bin/spark-class org.apache.hadoop.fs.FsShell -mkdir -p /user/<username> && \
   /opt/spark/bin/spark-class org.apache.hadoop.fs.FsShell -put -f /opt/hadoop/conf/core-site.xml /user/<username>/input.txt && \
   /opt/spark/bin/spark-class org.apache.hadoop.fs.FsShell -ls /user/<username>/"
```

Các lệnh HDFS khác: `-ls`, `-cat`, `-get`, `-rm`, `-cp`, `-mv`, `-count`

### WordCount — RDD (Bài TH 3)
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

### PySpark Interactive — DataFrame, SQL, MLLib (Bài TH 4, 5, 6)
```bash
kubectl exec -it -n bigdata $MASTER_POD -- /opt/spark/bin/pyspark \
  --master spark://spark-master:7077 \
  --conf spark.driver.host=$MY_POD_IP \
  --conf spark.hadoop.fs.defaultFS=hdfs://hadoop-namenode:9000
```

### GraphFrames (Bài TH 7)
```bash
kubectl exec -it -n bigdata $MASTER_POD -- /opt/spark/bin/pyspark \
  --master spark://spark-master:7077 \
  --conf spark.driver.host=$MY_POD_IP \
  --conf spark.hadoop.fs.defaultFS=hdfs://hadoop-namenode:9000 \
  --packages graphframes:graphframes:0.8.4-spark3.5-s_2.12
```
