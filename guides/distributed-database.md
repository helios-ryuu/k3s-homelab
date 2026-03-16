# Distributed Database — Oracle + MSSQL

> Namespaces: `oracle`, `mssql` | Scripts: `svc-scripts/oracle.sh`, `svc-scripts/mssql.sh`

---

## Node Labels

| Label | Used by |
|-------|---------|
| `node-role.kubernetes.io/database-oracle=true` | Oracle StatefulSet |
| `node-role.kubernetes.io/database-mssql=true` | MSSQL StatefulSet |

```bash
# Oracle nodes
kubectl label node <node> node-role.kubernetes.io/database-oracle=true

# MSSQL nodes
kubectl label node <node> node-role.kubernetes.io/database-mssql=true
```

---

## Helm Charts

### Oracle

```
oracle/
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
mssql/
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
# Via main dispatcher
./k3s.sh deploy oracle
./k3s.sh delete oracle
./k3s.sh check oracle

# Via component script
./svc-scripts/oracle.sh deploy           # Auto-checks node labels, secrets, image availability
./svc-scripts/oracle.sh delete           # Full cleanup (helm + ns + PVC)
./svc-scripts/oracle.sh delete node <n>  # Remove Oracle pod + PVC on a specific node
./svc-scripts/oracle.sh redeploy
./svc-scripts/oracle.sh scale <N>        # Scale via helm upgrade
./svc-scripts/oracle.sh logs
./svc-scripts/oracle.sh check            # Health check (4 sections)
```

### MSSQL

```bash
# Via main dispatcher
./k3s.sh deploy mssql
./k3s.sh delete mssql
./k3s.sh check mssql

# Via component script
./svc-scripts/mssql.sh deploy
./svc-scripts/mssql.sh delete
./svc-scripts/mssql.sh delete node <n>   # Remove MSSQL pod + PVC on a specific node
./svc-scripts/mssql.sh redeploy
./svc-scripts/mssql.sh scale <N>
./svc-scripts/mssql.sh logs
./svc-scripts/mssql.sh check             # Health check (4 sections)
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

## Health Check Sections

### Oracle (`./svc-scripts/oracle.sh check`) — 4 sections

1. **Pod Status** — oracle-db-0, oracle-db-1
2. **Oracle Health** — Listener status (lsnrctl), Instance status (sqlplus → `v$instance`)
3. **Cross-Instance Connectivity** — tnsping both directions, SQL connect both directions
4. **External Access** — NodePort 31521 reachability per pod

### MSSQL (`./svc-scripts/mssql.sh check`) — 4 sections

1. **Pod Status** — mssql-db-0, mssql-db-1, mssql-db-2
2. **MSSQL Health** — Server identity (@@SERVERNAME), Database MSSQLDB existence
3. **Cross-Instance Connectivity** — sqlcmd cross-instance queries (all pairs)
4. **External Access** — NodePort 31433 reachability per pod

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

The deploy script auto-checks image availability and prompts before proceeding if missing.

---

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| Pod MISSING | Not deployed | `./k3s.sh deploy oracle` / `./k3s.sh deploy mssql` |
| Pod Pending | Node offline | Wait for node online or scale down |
| Oracle Listener fails | Oracle needs 3-5 min to start | Retry after startup completes |
| Oracle ErrImageNeverPull | Image not imported on node | `sudo ctr -n k8s.io images import <file>.tar` |
| MSSQL sqlcmd fails | Init sidecar still running | Check `kubectl logs -n mssql mssql-db-X -c mssql-init` |
| Cross-instance fails | DNS or network issue | Verify headless service and pod DNS resolution |
