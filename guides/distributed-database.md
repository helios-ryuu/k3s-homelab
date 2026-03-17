# Distributed Database — Oracle + MSSQL

> Namespaces: `oracle`, `mssql` | ArgoCD Apps: `oracle`, `mssql` | Charts: local `services/oracle/`, `services/mssql/`

---

## Node Labels

| Label | Used by |
|-------|---------|
| `node-role.kubernetes.io/database-oracle=true` | Oracle StatefulSet |
| `node-role.kubernetes.io/database-mssql=true` | MSSQL StatefulSet |

```bash
kubectl label node <node> node-role.kubernetes.io/database-oracle=true
kubectl label node <node> node-role.kubernetes.io/database-mssql=true
```

---

## Helm Charts

### Oracle

```
services/oracle/
├── Chart.yaml
├── values.yaml        ← replicas, password, resources, nodePort
└── templates/
    ├── oracle-config.yaml   ConfigMap (tnsnames.ora + startup script)
    └── oracle-db.yaml       Headless Svc + NodePort Svc + StatefulSet
```

- Image: `oracle-database-19c:latest` (`imagePullPolicy: Never` — must import manually)
- NodePort `31521`, hostPort `1521`
- Startup script auto-updates `tnsnames.ora` from ConfigMap
- Default `replicas: 2` (primary + standby)

### MSSQL

```
services/mssql/
├── Chart.yaml
├── values.yaml        ← replicas, password, tasksetCores, resources
└── templates/
    ├── mssql-config.yaml    ConfigMap (setup.sql)
    └── mssql-db.yaml        Headless Svc + StatefulSet (+ sidecar init)
```

- Image: `mcr.microsoft.com/mssql/server:2025-latest`
- Sidecar `mssql-init`: waits for SQL Server ready, then runs `setup.sql`
- `taskset` workaround for P-core/E-core
- hostPort `1433`, NodePort `31433`
- Default `replicas: 3`

### Common design

- Hard anti-affinity: excluded from masters, 1 pod/node
- PVC `local-path` per instance
- Secrets via `infra-secrets` (`oracle-password`, `mssql-password`)

---

## Operations

### Oracle

```bash
# Config changes: edit services/oracle/values.yaml → git push → ArgoCD auto-syncs
argocd app sync oracle --grpc-web
argocd app wait oracle --health --grpc-web

# Scale
kubectl scale statefulset oracle-db -n oracle --replicas=<N>

# Logs
kubectl logs -n oracle oracle-db-0 -f

# Remove a single instance + its PVC
kubectl delete pod oracle-db-<N> -n oracle
kubectl delete pvc oracle-data-oracle-db-<N> -n oracle
```

### MSSQL

```bash
# Config changes: edit services/mssql/values.yaml → git push → ArgoCD auto-syncs
argocd app sync mssql --grpc-web
argocd app wait mssql --health --grpc-web

# Scale
kubectl scale statefulset mssql-db -n mssql --replicas=<N>

# Logs
kubectl logs -n mssql mssql-db-0 -c mssql-engine -f

# Remove a single instance + its PVC
kubectl delete pod mssql-db-<N> -n mssql
kubectl delete pvc mssql-data-mssql-db-<N> -n mssql
```

---

## Connection

### Oracle

| Instance | In-cluster DNS | Tailscale |
|----------|---------------|-----------|
| oracle-db-0 | `oracle-db-0.oracle-svc.oracle.svc.cluster.local:1521` | `<node-ip>:1521` |
| oracle-db-1 | `oracle-db-1.oracle-svc.oracle.svc.cluster.local:1521` | `<node-ip>:1521` |
| NodePort | `<any-node-ip>:31521` | |

### MSSQL

| Instance | In-cluster DNS | Tailscale |
|----------|---------------|-----------|
| mssql-db-0 | `mssql-db-0.mssql-svc.mssql.svc.cluster.local:1433` | `<node-ip>:1433` |
| mssql-db-1 | `mssql-db-1.mssql-svc.mssql.svc.cluster.local:1433` | `<node-ip>:1433` |
| mssql-db-2 | `mssql-db-2.mssql-svc.mssql.svc.cluster.local:1433` | `<node-ip>:1433` |
| NodePort | `<any-node-ip>:31433` | |

---

## Health Check

```bash
./ck.sh   # section: Resources → oracle / mssql namespace

kubectl get pods -n oracle
kubectl get pods -n mssql
```

---

## Cross-Instance Verification

### Oracle: tnsping

```bash
kubectl exec -n oracle oracle-db-0 -- /opt/oracle/product/19c/dbhome_1/bin/tnsping ORACLE_DB_1
kubectl exec -n oracle oracle-db-1 -- /opt/oracle/product/19c/dbhome_1/bin/tnsping ORACLE_DB_0
```

### Oracle: SQL cross-instance

```bash
kubectl exec -n oracle oracle-db-0 -- bash -c '
  /opt/oracle/product/19c/dbhome_1/bin/sqlplus -s /nolog <<EOF
CONNECT sys/"<password>"@ORACLE_DB_1 as sysdba
SELECT instance_name, host_name, status FROM v\$instance;
EOF
'
```

### MSSQL: cross-instance query

```bash
kubectl exec -n mssql mssql-db-0 -c mssql-engine -- /opt/mssql-tools18/bin/sqlcmd \
  -S "mssql-db-1.mssql-svc.mssql.svc.cluster.local" -U sa -P "<password>" -No \
  -Q "SELECT @@SERVERNAME AS [RemoteServer]"
```

---

## Oracle Image Import

Oracle uses `imagePullPolicy: Never`. The image must be imported on every node that runs Oracle pods:

```bash
# On each Oracle node
sudo ctr -n k8s.io images import oracle-database-19c.tar
```

Deploy will fail with `ErrImageNeverPull` if the image is missing on the scheduled node.

---

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| Pod Pending | Node offline | Wait for node or scale down |
| Oracle Listener fails | Oracle needs 3-5 min to start | Retry after startup completes |
| Oracle ErrImageNeverPull | Image not imported on node | `sudo ctr -n k8s.io images import <file>.tar` |
| MSSQL sqlcmd fails | Init sidecar still running | Check `kubectl logs -n mssql mssql-db-X -c mssql-init` |
| Cross-instance fails | DNS or network issue | Verify headless service and pod DNS resolution |
