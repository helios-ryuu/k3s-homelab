# Database — Oracle

> Namespace: `oracle` | ArgoCD App: `oracle` | Chart: local `services/oracle/`

---

## Node Labels

| Label | Used by |
|-------|---------|
| `node-role.kubernetes.io/database-oracle=true` | Oracle StatefulSet |

```bash
kubectl label node <node> node-role.kubernetes.io/database-oracle=true
```

---

## Helm Chart

```
services/oracle/
├── Chart.yaml
├── values.yaml        ← replicas, resources, nodePort
└── templates/
    ├── oracle-config.yaml   ConfigMap (tnsnames.ora + startup scripts)
    └── oracle-db.yaml       Headless Svc + NodePort Svc + StatefulSet
```

- Image: `oracle-database-19c:latest` (`imagePullPolicy: Never` — must import manually)
- NodePort `31521`, hostPort `1521`
- Startup scripts: inject `tnsnames.ora` + tự động tạo PDBs (LAB11PDB, LAB12PDB)
- `replicas: 2` — 2 instances độc lập, mỗi instance có đầy đủ LAB11PDB và LAB12PDB

---

## Operations

```bash
# Config changes: edit services/oracle/values.yaml → git push → ArgoCD auto-syncs
acd app sync oracle
acd app wait oracle --health

# Scale
kubectl scale statefulset oracle-db -n oracle --replicas=<N>

# Logs
kubectl logs -n oracle oracle-db-0 -f

# Remove a single instance + its PVC
kubectl delete pod oracle-db-<N> -n oracle
kubectl delete pvc oracle-data-oracle-db-<N> -n oracle
```

---

## Connection

| Instance | In-cluster DNS | Tailscale |
|----------|---------------|-----------|
| oracle-db-0 | `oracle-db-0.oracle-svc.oracle.svc.cluster.local:1521` | `<node-ip>:1521` |
| oracle-db-1 | `oracle-db-1.oracle-svc.oracle.svc.cluster.local:1521` | `<node-ip>:1521` |
| NodePort | `<any-node-ip>:31521` | |

Kết nối ngoài (DataGrip / SQL Developer):
- Host: `<Tailscale IP>` Port: `31521`
- SID: `ORCLCDB` | User: `sys as sysdba`

---

## Health Check

```bash
kubectl get pods -n oracle
./ck.sh res oracle
```

---

## Oracle Image Import

Oracle dùng `imagePullPolicy: Never`. Phải import image trên mỗi node chạy Oracle:

```bash
# Trên từng Oracle node
sudo ctr -n k8s.io images import oracle-database-19c.tar
```

Deploy thất bại với `ErrImageNeverPull` nếu image chưa được import.

---

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| Pod Pending | Node offline | Đợi node hoặc scale down |
| Oracle Listener fails | Oracle cần 3-5 phút để start | Retry sau khi startup hoàn tất |
| ErrImageNeverPull | Image chưa import trên node | `sudo ctr -n k8s.io images import <file>.tar` |
