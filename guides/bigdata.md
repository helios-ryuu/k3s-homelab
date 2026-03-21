# BigData — Hadoop + Spark

> Namespace: `bigdata` | ArgoCD App: `bigdata` | Chart: local `services/bigdata/`

---

## Nhãn Node

| Nhãn | Vai trò |
|------|---------|
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

- `workers.replicas` mặc định 1; `dfs.replication` tự khớp với số worker
- Hard anti-affinity: pod master không chạy trên node worker, 1 pod/node
- hostPort cho WebUI — truy cập qua Tailscale IP

---

## Vận hành

```bash
# Thay đổi config: sửa services/bigdata/values.yaml → git push → ArgoCD tự đồng bộ

# Kích hoạt đồng bộ thủ công (helper acd — xem README.md)
acd app sync bigdata
acd app wait bigdata --health

# Logs
kubectl logs -n bigdata -l app=hadoop-namenode -f
kubectl logs -n bigdata -l app=spark-master -f
```

### Scale (Tăng/Giảm replicas)

> **Lưu ý quan trọng:** Scale bằng `kubectl scale` trực tiếp — không dùng `helm upgrade` — để tránh thay đổi `dfs.replication` làm crash NameNode.

```bash
# Tắt worker
kubectl scale statefulset hadoop-datanode hadoop-nodemgr spark-worker -n bigdata --replicas=0

# Khôi phục / thêm worker
kubectl scale statefulset hadoop-datanode hadoop-nodemgr spark-worker -n bigdata --replicas=1
```

---

## Giao diện Web

| Dịch vụ | URL |
|---------|-----|
| HDFS NameNode | `http://<master-ip>:9870` |
| YARN ResourceManager | `http://<master-ip>:8088` |
| Spark Master | `http://<any-node-ip>:30808` (NodePort) |
| DataNode | `http://<worker-ip>:9864` |
| NodeManager | `http://<worker-ip>:8042` |
| Spark Worker | `http://<worker-ip>:8081` |

---

## Kiểm tra sức khỏe hệ thống

```bash
./ck.sh   # mục: Resources → namespace bigdata

# Trạng thái pod
kubectl get pods -n bigdata

# Báo cáo HDFS
kubectl exec -n bigdata deploy/hadoop-namenode -- hdfs dfsadmin -report

# Danh sách node YARN
kubectl exec -n bigdata deploy/hadoop-rmgr -- yarn node -list
```

---

## Lệnh thực hành (Lab)

### Bước 0 — Vào shell trong pod (K3S, làm một lần mỗi phiên)

Có hai pod khác nhau tùy mục đích:

| Mục đích | Pod | Lệnh vào shell |
|----------|-----|----------------|
| Thao tác HDFS (`hdfs dfs`) | `hadoop-namenode` | `kubectl exec -it -n bigdata deploy/hadoop-namenode -- bash` |
| Chạy Spark (`pyspark`, `spark-submit`) | `spark-master` | `kubectl exec -it -n bigdata deploy/spark-master -- /bin/bash` |

> **Lý do:** Image `apache/spark` (spark-master) không có Hadoop CLI. Lệnh `hdfs` chỉ có trong image `bde2020/hadoop-namenode`.

**Vào NameNode để thao tác HDFS:**

```bash
kubectl exec -it -n bigdata deploy/hadoop-namenode -- bash
# hdfs dfs -mkdir, -put, -ls, v.v. dùng ở đây
```

**Vào Spark Master để chạy Spark:**

```bash
kubectl exec -it -n bigdata deploy/spark-master -- /bin/bash
export HADOOP_USER_NAME=root   # để Spark ghi HDFS với quyền root
# pyspark, spark-submit dùng ở đây
```

> Từ đây, các lệnh HDFS bên dưới chạy **trong shell của namenode pod**, lệnh Spark chạy **trong shell của spark-master pod** — cú pháp giống hệt cài đặt truyền thống.

---

### Tạo thư mục trên HDFS (`mkdir`)

```bash
hdfs dfs -mkdir -p ~/lab2
```

> HDFS `~` = `/user/root` (vì `HADOOP_USER_NAME=root`)

---

### Đưa file lên HDFS (`put` / `copyFromLocal`)

```bash
hdfs dfs -put ~/lab2/file.txt ~/lab2/input.txt
```

> `-put` và `copyFromLocal` giữ file gốc; `-moveFromLocal` xóa file gốc sau khi đưa lên.

---

### Liệt kê file/thư mục (`ls`)

```bash
hdfs dfs -ls ~/lab2/
```

---

### Xem nội dung file (`cat`)

```bash
hdfs dfs -cat ~/lab2/input.txt
```

---

### Tải file về local (`get` / `copyToLocal`)

```bash
hdfs dfs -get ~/lab2/output ~/lab2/output-local
```

> `-get` và `copyToLocal` giống nhau; `-moveToLocal` xóa file trên HDFS sau khi tải về.

---

### Sao chép / Di chuyển trong HDFS (`cp` / `mv`)

```bash
hdfs dfs -cp ~/lab2/a.txt ~/lab2/b.txt
hdfs dfs -mv ~/lab2/a.txt ~/lab2/b.txt
```

---

### Đếm file và dung lượng (`count`)

```bash
hdfs dfs -count ~/lab2/
```

> Kết quả trả về: `<số thư mục>  <số file>  <tổng dung lượng byte>  <đường dẫn>`

---

### Xóa file / thư mục (`rm` / `rmdir`)

```bash
hdfs dfs -rm ~/lab2/input.txt            # xóa file
hdfs dfs -rmdir ~/lab2/thu_muc_rong      # xóa thư mục rỗng
hdfs dfs -rm -r ~/lab2/output            # xóa đệ quy
```

---

### WordCount — RDD (Spark Submit)

```bash
/opt/spark/bin/spark-submit \
  --master spark://spark-master:7077 \
  --conf spark.hadoop.fs.defaultFS=hdfs://hadoop-namenode:9000 \
  --conf spark.driver.host=$MY_POD_IP \
  /opt/spark/examples/src/main/python/wordcount.py \
  hdfs://hadoop-namenode:9000/user/root/lab2/input.txt
```

> Truyền thống: `bin/hadoop jar <wordcount.jar> wordcount /user/root/lab2/input.txt /user/root/lab2/output`

---

### Ước lượng Pi (Spark Submit)

```bash
/opt/spark/bin/spark-submit \
  --master spark://spark-master:7077 \
  --conf spark.driver.host=$MY_POD_IP \
  /opt/spark/examples/src/main/python/pi.py 100
```

> Truyền thống: `bin/hadoop jar <spark-examples.jar> org.apache.spark.examples.SparkPi 100`

---

### PySpark tương tác — DataFrame, SQL, MLLib

```bash
/opt/spark/bin/pyspark \
  --master spark://spark-master:7077 \
  --conf spark.driver.host=$MY_POD_IP \
  --conf spark.hadoop.fs.defaultFS=hdfs://hadoop-namenode:9000
```

> Truyền thống: `bin/pyspark --master yarn`

---

### GraphFrames

```bash
/opt/spark/bin/pyspark \
  --master spark://spark-master:7077 \
  --conf spark.driver.host=$MY_POD_IP \
  --conf spark.hadoop.fs.defaultFS=hdfs://hadoop-namenode:9000 \
  --packages graphframes:graphframes:0.8.4-spark3.5-s_2.12
```

> Truyền thống: `bin/pyspark --master yarn --packages graphframes:graphframes:0.8.4-spark3.5-s_2.12`

---

## Xử lý sự cố

| Vấn đề | Nguyên nhân | Cách xử lý |
|--------|-------------|------------|
| YARN 0 NodeManager | Thiếu port 8030-8033 trên RM Service | Kiểm tra service ports trong `hadoop-rmgr.yaml` |
| Pod Pending | Node worker offline | Chờ node hoạt động lại hoặc giảm replicas |
| Ghi HDFS thất bại | DataNode chưa đăng ký xong (30-60s sau deploy) | Chờ và thử lại |
| NameNode crash khi nâng cấp | `dfs.replication` bị thay đổi qua helm upgrade | Dùng `kubectl scale` thay thế |

---

## Tham khảo: Hướng dẫn cài đặt trực tiếp trên máy (cách truyền thống)

> Phần này ánh xạ nội dung từ tài liệu gốc của môn học (cài Hadoop trực tiếp trên máy), giúp sinh viên đối chiếu với môi trường K3S đang dùng trong homelab.

### III. Thao tác với HDFS

Trong môi trường dòng lệnh truyền thống, có hai cú pháp tương đương để thao tác với HDFS:

```bash
bin/hadoop fs <lệnh> [<tùy chọn>] [<đối số>]
bin/hdfs dfs <lệnh> [<tùy chọn>] [<đối số>]
```

Các lệnh cơ bản:

| Lệnh | Chức năng |
|------|-----------|
| `cat` | Xem nội dung file trên HDFS |
| `copyFromLocal` / `moveFromLocal` / `put` | Đưa file từ local lên HDFS (`copy` giữ file gốc, `move` xóa file gốc) |
| `copyToLocal` / `moveToLocal` / `get` | Tải file từ HDFS về local |
| `cp` / `mv` | Sao chép / di chuyển file trong HDFS |
| `count` | Đếm số thư mục, file và tổng dung lượng |
| `find` | Tìm kiếm file/thư mục trong HDFS |
| `help` | Hiển thị trợ giúp cho một lệnh |
| `ls` / `lsr` | Liệt kê file/thư mục (`lsr` là đệ quy) |
| `mkdir` | Tạo thư mục trên HDFS |
| `rm` / `rmdir` / `rmr` | Xóa file / thư mục rỗng / thư mục đệ quy |

> **Trong K3S homelab:** Thay `bin/hadoop fs` bằng lệnh `kubectl exec` vào pod `hadoop-namenode` hoặc `spark-master` rồi gọi `hdfs dfs <lệnh>`. Xem ví dụ ở phần [Thao tác HDFS cơ bản](#thao-tác-hdfs-cơ-bản) bên trên.

---

### IV. Lập trình MapReduce bằng Java

#### 1. Thêm thư viện Hadoop vào project Java

```
${HADOOP_HOME}/share/hadoop/*/*.jar
${HADOOP_HOME}/share/hadoop/*/lib/*.jar
```

#### 2. Kiểu dữ liệu đặc biệt trong Apache Hadoop

MapReduce hoạt động trên các cặp `<key, value>`. Luồng xử lý:

```
(input) <k1, v1> → map → <k2, v2> → combine → <k2, v2> → reduce → <k3, v3> (output)
```

Các kiểu dữ liệu cơ bản (dùng làm key hoặc value):

| Kiểu | Tương đương Java |
|------|-----------------|
| `IntWritable` | `int` |
| `LongWritable` | `long` |
| `FloatWritable` | `float` |
| `DoubleWritable` | `double` |
| `Text` | `String` |
| `NullWritable` | không có key/value |

Tham khảo đầy đủ: https://hadoop.apache.org/docs/stable/api/org/apache/hadoop/io/package-summary.html

#### 3. Tạo kiểu dữ liệu tùy chỉnh

Để tạo kiểu key mới, implement interface `WritableComparable`:

```java
public class TenLop implements WritableComparable<TenLop> {
    // Bắt buộc định nghĩa đủ 5 phương thức:
    public TenLop(/* args */) { ... }         // Constructor
    public void readFields(DataInput in) { ... }   // Đọc từ stream
    public void write(DataOutput out) { ... }      // Ghi ra stream
    public String toString() { ... }               // Framework dùng khi ghi ra file
    public int compareTo(TenLop other) { ... }     // So sánh key (shuffle/sort)
}
```

> Nếu chỉ làm value (không cần sort), chỉ cần implement `Writable` (bỏ `compareTo`).

#### 4. Biên dịch phần mềm

```bash
# Thêm vào hadoop-env.sh
export HADOOP_CLASSPATH=${JAVA_HOME}/lib/tools.jar

# Biên dịch .java → .class
bin/hadoop com.sun.tools.javac.Main -d <thư_mục_class> <đường_dẫn_file.java>

# Đóng gói thành .jar
jar cvf <tên>.jar -C <thư_mục_class> .
```

#### 5. Chạy phần mềm trên Hadoop

```bash
# Khởi động hệ thống
start-dfs.sh && start-yarn.sh

# Chạy job MapReduce
bin/hadoop jar <đường_dẫn.jar> <package.MainClass> <args>
```

> **Trong K3S homelab:** Không cần biên dịch thủ công. Dùng `spark-submit` với file `.py` hoặc `.jar` qua `kubectl exec` vào pod `spark-master`. Xem phần [WordCount — RDD](#wordcount--rdd) bên trên.
