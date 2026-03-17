# Headlamp — K8s Dashboard

> Namespace: `kube-system` | ArgoCD App: `headlamp` | Chart: `kubernetes-sigs/headlamp` v0.39.0

---

## Access

| Endpoint | URL |
|----------|-----|
| Via Cloudflare Tunnel | `https://headlamp.helios.id.vn` |
| In-cluster | `http://headlamp.kube-system.svc.cluster.local:80` |

> Headlamp uses `ClusterIP` — exposed externally via Cloudflare Tunnel (see `guides/cloudflared.md`).

---

## Operations

```bash
# Config changes: edit services/headlamp/values.yaml or argocd-apps/headlamp.yaml → git push

# Manual sync trigger
argocd app sync headlamp --grpc-web
argocd app wait headlamp --health --grpc-web

# Logs
kubectl logs -n kube-system -l app.kubernetes.io/name=headlamp -f
```

---

## Authentication Token

The Helm chart creates SA `headlamp` in `kube-system` and binds it to `cluster-admin` via `ClusterRoleBinding/headlamp-admin`. Generate a **permanent** (non-expiring) token for that SA:

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: headlamp-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: headlamp
type: kubernetes.io/service-account-token
EOF

kubectl get secret headlamp-token -n kube-system \
  -o jsonpath='{.data.token}' | base64 -d
```

Paste the token into the Headlamp login screen.

---

## Configuration

| Setting | Value |
|---------|-------|
| Chart | `kubernetes-sigs.github.io/headlamp/` v0.39.0 |
| Replicas | 1 |
| Mode | In-cluster |
| Service | ClusterIP:80 |
| Node affinity | Prefers control-plane nodes |
| Tolerations | Tolerates `control-plane` NoSchedule taint |
| Resources | 50-100m CPU, 64-128Mi RAM |

> Chart version is pinned to `0.39.0`. Chart `0.40.x` introduced `-session-ttl` which is unsupported by the headlamp binary and causes CrashLoopBackOff.

---

## ArgoCD Helm Repo

The headlamp Helm repo must be registered in ArgoCD (one-time, already in `SETUP.md`):

```bash
argocd repo add https://kubernetes-sigs.github.io/headlamp/ \
  --type helm --name headlamp --grpc-web
```
