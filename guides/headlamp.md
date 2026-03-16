# Headlamp — K8s Dashboard

> Namespace: `kube-system` | Script: `svc-scripts/headlamp.sh` | Chart: `headlamp/headlamp`

---

## Operations

```bash
# Via main dispatcher
./k3s.sh deploy headlamp
./k3s.sh delete headlamp
./k3s.sh redeploy headlamp

# Via component script
./svc-scripts/headlamp.sh deploy          # Deploys with cluster-admin RBAC
./svc-scripts/headlamp.sh delete
./svc-scripts/headlamp.sh redeploy
./svc-scripts/headlamp.sh token           # Create/retrieve permanent auth token
```

---

## Access

| Endpoint | URL |
|----------|-----|
| Via Cloudflare Tunnel | `https://headlamp.<your-domain>` |
| In-cluster | `http://headlamp.kube-system.svc.cluster.local:80` |

> Headlamp uses `ClusterIP` — exposed externally via Cloudflare Tunnel (see `guides/cloudflared.md`).

---

## Authentication Token

Headlamp requires a ServiceAccount token to authenticate. Generate a **permanent** (non-expiring) token:

```bash
./svc-scripts/headlamp.sh token
```

This creates a `kubernetes.io/service-account-token` Secret (static, no TTL) and prints the token. Paste it into the Headlamp login screen.

---

## Configuration

| Setting | Value |
|---------|-------|
| Replicas | 1 |
| Mode | In-cluster |
| Service | ClusterIP:80 |
| Node affinity | Prefers control-plane nodes |
| Tolerations | Tolerates `control-plane` NoSchedule taint |
| Resources | 50-100m CPU, 64-128Mi RAM |

---

## RBAC

On first deploy, a `ClusterRoleBinding` `headlamp-admin` is created, binding the `headlamp` ServiceAccount to `cluster-admin`. This gives the dashboard full read/write access to all cluster resources.

---

## Helm Repo Setup (one-time)

```bash
helm repo add headlamp https://headlamp-k8s.github.io/headlamp/
helm repo update
```
