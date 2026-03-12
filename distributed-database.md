# IS211.Q22 — Cơ sở dữ liệu phân tán (Oracle + MSSQL)
> K3s namespaces: `oracle`, `mssql`  |  Quản lý cluster: xem `k3s.md`

---

## 0. Node Labels (Yêu cầu)
Cả Oracle và MSSQL đều sử dụng label sau để định danh các node có thể chạy database:
- **Database nodes**: `node-role.kubernetes.io/database: "true"`

Gán label bằng lệnh:
```bash
kubectl label node <node-name> node-role.kubernetes.io/database=true
```

---

## 1. Helm Charts

### Oracle
```
oracle/
├── Chart.yaml
├── values.yaml        ← replicas, password, resources, nodePort
└── templates/
    ├── oracle-config.yaml   ConfigMap (tnsnames.ora + startup script)
    └── oracle-db.yaml       Headless Svc + NodePort Svc + StatefulSet
```
- Image: `oracle-database-19c:latest` (`imagePullPolicy: Never`, import thủ công)
- NodePort: `31521` → truy cập từ ngoài
- hostPort: `1521` → truy cập qua Tailscale IP worker
- Startup script tự cập nhật `tnsnames.ora` từ ConfigMap
- `replicas` mặc định 2 (primary + standby)

### MSSQL
```
mssql/
├── Chart.yaml
├── values.yaml        ← replicas, password, tasksetCores, resources
└── templates/
    ├── mssql-config.yaml    ConfigMap (setup.sql)
    └── mssql-db.yaml        Headless Svc + StatefulSet (+ sidecar init)
```
- Image: `mcr.microsoft.com/mssql/server:2025-latest`
- Sidecar `mssql-init`: chờ SQL Server sẵn sàng → chạy `setup.sql`
- `taskset` workaround cho P-core/E-core
- hostPort: `1433` → truy cập qua Tailscale IP worker
- `replicas` mặc định 2

### Thiết kế chung
- Hard anti-affinity: cấm master, 1 pod/node
- PVC `local-path` cho mỗi instance
- Scale Oracle: `helm upgrade ora oracle -n oracle --set replicas=2 --timeout 2m`

---

## 2. Deploy / Xóa

### Oracle
```bash
# Cài đặt lần đầu
helm install ora oracle -n oracle --create-namespace --timeout 2m

# Cập nhật
helm upgrade ora oracle -n oracle --timeout 2m

# Xóa
helm uninstall ora -n oracle
kubectl delete ns oracle
```

### MSSQL
```bash
# Cài đặt lần đầu
helm install mssql mssql -n mssql --create-namespace --timeout 2m

# Cập nhật
helm upgrade mssql mssql -n mssql --timeout 2m

# Xóa
helm uninstall mssql -n mssql
kubectl delete ns mssql
```

---

## 3. Kết nối

### Oracle
| Instance | DNS nội bộ | Tailscale |
|---|---|---|
| oracle-db-0 | `oracle-db-0.oracle-svc.oracle.svc.cluster.local:1521` | `<node-ip-1>:1521` |
| oracle-db-1 | `oracle-db-1.oracle-svc.oracle.svc.cluster.local:1521` | `<node-ip-2>:1521` |
| NodePort | `<any-node-ip>:31521` | |

### MSSQL
| Instance | DNS nội bộ | Tailscale |
|---|---|---|
| mssql-db-0 | `mssql-db-0.mssql-svc.mssql.svc.cluster.local:1433` | `<node-ip-2>:1433` |
| mssql-db-1 | `mssql-db-1.mssql-svc.mssql.svc.cluster.local:1433` | `<node-ip-1>:1433` |

---

## 4. Kiểm tra phân tán

### Oracle: tnsping
```bash
kubectl exec -n oracle oracle-db-0 -- /opt/oracle/product/19c/dbhome_1/bin/tnsping ORACLE_DB_1
kubectl exec -n oracle oracle-db-1 -- /opt/oracle/product/19c/dbhome_1/bin/tnsping ORACLE_DB_0
```

### Oracle: SQL cross-instance
```bash
kubectl exec -n oracle oracle-db-0 -- bash -c '
  /opt/oracle/product/19c/dbhome_1/bin/sqlplus -s /nolog <<EOF
CONNECT sys/"Oracle@2026"@ORACLE_DB_1 as sysdba
SELECT instance_name, host_name, status FROM v\$instance;
EOF
'
```

### MSSQL: cross-instance query
```bash
# MSSQL-0 → MSSQL-1
kubectl exec -n mssql mssql-db-0 -c mssql-init -- /opt/mssql-tools/bin/sqlcmd \
  -S "mssql-db-1.mssql-svc.mssql.svc.cluster.local" -U sa -P "MSSQLServer@2026" \
  -Q "SELECT @@SERVERNAME AS [RemoteServer]"

# MSSQL-1 → MSSQL-0
kubectl exec -n mssql mssql-db-1 -c mssql-init -- /opt/mssql-tools/bin/sqlcmd \
  -S "mssql-db-0.mssql-svc.mssql.svc.cluster.local" -U sa -P "MSSQLServer@2026" \
  -Q "SELECT @@SERVERNAME AS [RemoteServer]"
```

### Credentials

| DB | User | Password |
|---|---|---|
| Oracle | `sys` (sysdba) | `Oracle@2026` |
| MSSQL | `sa` | `MSSQLServer@2026` |
