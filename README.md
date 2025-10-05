# Local GitOps Playground

Run the full demo with a single command:

```bash
./run.sh
```

The script provisions Minikube, builds the sample Nginx image, applies Terraform (namespaces + ArgoCD via Helm), publishes the application Helm chart into an in-cluster Helm repository, wires staging/production ArgoCD Applications, and updates `/etc/hosts` automatically so the endpoints are ready to browse as soon as the rollout finishes.

## Application Endpoints

- Staging → http://staging.hello.local
- Production → http://prod.hello.local
- ArgoCD UI → http://argocd.local (exposed through the ingress controller)
  - Username: `admin`
  - Password: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 --decode`

`./run.sh` rewrites the host entries with the ingress controller’s external IP (often `127.0.0.1` when using `minikube tunnel`, or `$(minikube ip)` otherwise). If the script cannot modify `/etc/hosts`, manually add:

```
<ingress-ip> staging.hello.local prod.hello.local argocd.local
```

If ingress access is blocked (corporate firewall, VPN, or running without `minikube tunnel`), you can always fall back to port-forwarding:

```bash
# Staging app on http://localhost:8081
kubectl -n staging port-forward svc/nginx-app 8081:80

# Production app on http://localhost:8082
kubectl -n prod port-forward svc/nginx-app 8082:80

# ArgoCD UI on http://localhost:8080
kubectl -n argocd port-forward svc/argocd-server 8080:80
```

### Ingress Access Checklist

1. `minikube addons enable ingress`
2. Keep `minikube tunnel` running in a separate terminal (required so the ingress controller gets an external IP reachable from your host). The script also patches the ingress controller Service to `LoadBalancer` to make this work reliably on macOS/Linux Docker drivers.
3. Confirm you can reach the IP: `curl -I http://<ingress-ip>`
4. Browse to the vanity hosts above. If you still time out, re-check `/etc/hosts` and confirm the tunnel is active.

## Rollout App

Three quick scripts plus the ArgoCD UI cover the full lifecycle.

- `scripts/build.sh` – build a new container tag inside Minikube and print the staging patch command.
  ```bash
  ./scripts/build.sh --tag 1.1.0
  # Builds nginx-demo:1.1.0 in Minikube.
  # Patch staging (command printed) → wait for Sync → promote when ready.
  ```

- `scripts/promote.sh` – promote or roll back a tag for staging or prod. It verifies the image exists locally before patching the ArgoCD Application.
  ```bash
  ./scripts/promote.sh -e staging -t 1.1.0   # set staging to tag 1.1.0
  ./scripts/promote.sh -e prod               # copy the current staging tag into prod
  ./scripts/promote.sh -e prod -t 1.0.0      # roll production back to tag 1.0.0
  ```

- ArgoCD UI – open the application (`nginx-staging` or `nginx-prod`) and:
  1. Click **App Details → PARAMETERS** → edit `image.tag` to promote or roll back.
  2. For rollbacks, **App Details → HISTORY & SYNC** → select a previous revision and press **ROLLBACK**.
  ArgoCD CLI equivalents are available (`argocd app set ...`, `argocd app rollback ...`) if you prefer.


# Monitoring Guardrails (Production-grade)

You don’t need 1000s alerts. You need the right **tripwires**: things that tell you **“users hurt”** or **“infra is about to fall over.”**

Below is a pragmatic baseline.

---

## 1. Application & Ingress — user-facing signals

| Signal | Alert when | Why it matters / first move |
|--------|------------|------------------------------|
| **Deployment replicas unavailable** (`kube_deployment_status_replicas_unavailable`) | `> 0` for 5m | Rollout can’t serve traffic. **Action:** check rollout status, consider rollback. |
| **Pod restarts** (`kube_pod_container_status_restarts_total`) | > 3 in 10m | Crash loops, OOM, config errors. **Action:** inspect logs/events, pause rollout. |
| **HTTP 5xx error rate** (ingress/controller) | > 1% for 5m | Users are failing requests. **Action:** check upstream pods, rollback if release-linked. |
| **p95 latency** (`nginx_ingress_controller_request_duration_seconds`) | > 250ms for 5m | Detect regressions before errors. **Action:** inspect CPU, DB queries, caches. |
| **Availability success rate** (`…{status!~"5.."}`) | < 99% for 10m | Keeps uptime above SLA/SLO. |
| **Queue depth / lag** (Kafka, RabbitMQ, SQS) | Backlog growing > 10m | Users waiting for async jobs. **Action:** scale workers or debug stuck consumers. |
| **Job failure ratio** (batch/cron jobs) | > 1 failure in last 5 runs | Ensures periodic jobs (emails, billing, syncs) don’t silently fail. |
| **App-specific KPIs** (logins, checkouts, API QPS) | Drop > 10% in 5m | Catch business impact even if infra looks “green.” |

---

## 2. Platform & Cluster Health — the boring foundation

| Signal | Alert when | Why it matters / first move |
|--------|------------|------------------------------|
| **Node readiness** | Not Ready immediately | Losing a node reduces capacity. **Action:** drain or replace. |
| **Node pressure** (Disk/Memory/Network) | true for > 5m | Prevents evictions/scheduling issues. |
| **Filesystem usage** (`node_filesystem_usage`) | Warn at 80%, alert 90% | Avoid kubelet/runtime crashes. |
| **CPU saturation** (`node_cpu_seconds_total`) | > 90% for 5m | Headroom gone. Scale nodes or workloads. |
| **Memory saturation** (`node_memory_working_set_bytes`) | > 90% for 5m | OOM kills incoming. |
| **API server latency** (`apiserver_request_duration_seconds` p99) | > 1s writes | Deploys/scale lag. |
| **API server errors** (`apiserver_request_total{code!~"2.."}`) | > 1% for 5m | Control plane unstable. |
| **etcd leader changes** | > 3/hr | Quorum flapping → instability. |
| **etcd size** | > 70% quota | Prevent stalls. Compaction/defrag or increase disk. |
| **CNI restarts** (calico, cilium, flannel) | > 2 in 10m | Network plane instability. |
| **Ingress controller health** | Pod not Ready, restart bursts | No ingress = outage. |
| **Certificate expiry** | Warn 14d, alert 7d | Expired TLS = outage. |
| **Cluster autoscaler failures** | Any scaling error > 5m | Prevents workloads from stabilizing. |

---

## 3. Supporting Systems — hidden dependencies

| Signal | Alert when | Why it matters |
|--------|------------|----------------|
| **DNS error rate** (`coredns_dns_request_count`, error codes) | > 1% for 5m | DNS issues = everything looks broken. |
| **Registry/repo reachability** (container pulls, Helm repo HTTP probe) | > 1 failed probe in 5m | ArgoCD / Kubelet can’t pull images or charts. |
| **CI/CD pipeline failures** | > 1 failure in critical branch deploys | Stops changes shipping; usually noticed too late. |
| **External dependency SLIs** (DB, cache, 3rd-party APIs) | p95 latency > 250ms or 5xx > 1% | Your uptime = their uptime. |

---

## 4. Security & Compliance guardrails

| Signal | Alert when | Why it matters |
|--------|------------|----------------|
| **Audit log volume** | Sudden spikes/drops | Attackers hide in noise. |
| **Unauthorized attempts** (`kube_audit` events) | > N/min | Brute force or misconfig. |
| **Image vulnerability scans** | Critical vulns > 0 | Block deploys or alert security. |
| **RBAC misuses** (deny events) | Repeated in 5m | Broken perms, or probing. |

---

## 5. Principles

- **Page only on user pain.** Warnings → tickets/dashboards. Alerts → wake someone up.  
- **Every alert has a runbook.** First move should be obvious.  
- **Label and route.** Alerts tagged with `env=`, `service=`, `team=`.  
- **Test your alerts.** Fire drills catch gaps before prod does.  
- **Iterate.** Start simple, cut noise, expand coverage as system grows.  

---

## Example PromQL sketches

```promql
# 5xx error rate (>1%)
sum(rate(nginx_ingress_controller_requests{status=~"5.."}[5m]))
/
sum(rate(nginx_ingress_controller_requests[5m])) > 0.01

# p95 request latency (>250ms)
histogram_quantile(0.95,
  sum by (le) (rate(nginx_ingress_controller_request_duration_seconds_bucket[5m]))
) > 0.25

# Pod restart bursts (>3 in 10m)
increase(kube_pod_container_status_restarts_total[10m]) > 3

# ArgoCD not synced/healthy (pseudo – depends on your exporter)
argocd_app_sync_status != 1 OR argocd_app_health_status != 1
```

---
# Cleanup

```bash
terraform -chdir=terraform destroy -auto-approve
minikube delete
sudo sed -i '' '/hello-local/d' /etc/hosts  # macOS
# or sudo sed -i '/hello-local/d' /etc/hosts  # Linux
rm -rf dist
```

After cleanup, remove any leftover host entries containing `hello-local` if you prefer to reset `/etc/hosts` manually.
