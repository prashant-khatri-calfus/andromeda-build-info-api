# Interview walkthrough

A ~20 minute storyline, a live demo script, and likely questions.

## 1. Storyline (5 min)

1. **Interpretation of the brief** – "An endpoint that tells you *exactly what is running*. The interesting part isn't the endpoint, it's guaranteeing the answer is true – so build info is baked into the immutable image, and the pipeline uses the endpoint to verify its own deployment."
2. **Shape of the solution** – show the README diagram: GitHub → Cloud Build → Artifact Registry → private GKE Autopilot → L4 LB on a static IP.
3. **Principles** – least privilege everywhere, nothing public that doesn't need to be, everything as code, immutable artifacts deployed by digest, zero-downtime rollouts.
4. **Deliberate simplifications** – L4 LB over HTTP, single environment. Explain the upgrade path (DESIGN §4, §10). Showing you *know* the gaps matters more than closing all of them.

## 2. Code tour (5 min)

| File | Point to make |
|---|---|
| `src/app.js` | build vs runtime info; Downward API; response JSON schema; liveness ≠ readiness; `"unknown"` fallback; Cloud Logging-friendly pino config |
| `src/server.js` | SIGTERM → `app.close()` drains in-flight requests |
| `Dockerfile` | intentionally short: layer caching order, `npm ci --omit=dev`, ARG→ENV build info, `USER node`, `node` as PID 1 (not `npm start`) |
| `k8s/base/deployment.yaml` | `maxUnavailable: 0`, probes, preStop, securityContext, zone spread |
| `k8s/base/networkpolicy.yaml` | default deny incl. egress |
| `k8s/base/service.yaml` | static IP by name, `loadBalancerSourceRanges` |
| `terraform/gke.tf` | private nodes + **DNS endpoint** (the CI-to-private-cluster problem) |
| `terraform/cloudbuild.tf` | dedicated SA, repo-scoped write |
| `cloudbuild.yaml` | deploy by digest + verify step |

## 3. Live demo (5 min)

```bash
# What's running?
curl -s http://$IP/build-info | jq
git log -1 --oneline                                   # commit matches

# Load balanced across replicas / zones
for i in $(seq 8); do curl -s http://$IP/build-info | jq -r '.runtime.pod_name'; done

# Ship a change
sed -i 's/1.0.0/1.1.0/' VERSION && git commit -am "bump to 1.1.0" && git push
# Cloud Build console: test → build → push → deploy → verify

# Zero downtime during rollout (second terminal, before pushing)
while true; do curl -s -o /dev/null -w "%{http_code} " http://$IP/build-info; sleep 0.2; done
# expect only 200s while .build.version flips from 1.0.0 to 1.1.0

# Self-healing / readiness
kubectl -n build-info delete pod -l app.kubernetes.io/name=build-info-api --wait=false
kubectl -n build-info get po -w
```

**Before the interview:** run the full pipeline once end to end, record the IP, and keep a screenshot/recording of a green Cloud Build run in case of live-demo issues.

## 4. Likely questions and short answers

**Why Autopilot?** Stateless HTTP workload; no need for node-level control; Google handles patching/scaling; hardened defaults; pay per pod request. Would choose Standard for GPUs with specific drivers, privileged DaemonSets, or heavy bin-packing optimisation.

**How does Cloud Build reach a private cluster?** DNS-based control plane endpoint: IAM-authenticated, no IP allow-listing, no private pool. Alternatives: private worker pool peered into the VPC + private endpoint; or Connect Gateway (Fleet).

**Why not Ingress/Gateway?** Scope. L4 LB is one object and HA out of the box. For production: Gateway API + managed certs + Cloud Armor; the app doesn't change, only the Service type plus a Gateway/HTTPRoute.

**What happens during a node upgrade?** Nodes are drained; PDB keeps ≥1 pod; zone spread + `maxUnavailable: 0` means capacity never drops; `preStop` + readiness avoid sending requests to terminating pods.

**How do you roll back?** `kubectl rollout undo deployment/build-info-api` (instant, previous ReplicaSet) or re-run the Cloud Build for the previous commit (re-deploys that digest). With Cloud Deploy: one-click rollback to a previous release.

**How do you know which version is in prod?** `GET /build-info` – and the pipeline asserts it. Also the image digest pinned in the Deployment spec.

**Why deploy by digest?** Tags are mutable; a re-pushed tag could change what runs without a manifest change. Digest = content address = exactly the bytes that were tested and scanned. Also a prerequisite for Binary Authorization.

**Secrets?** None needed. If needed: Secret Manager accessed via Workload Identity (KSA → GSA binding) or the Secret Manager CSI add-on – never in the image or plain K8s Secrets in Git.

**Workload Identity?** Enabled by default on Autopilot. The app doesn't call GCP APIs so no KSA→GSA binding is needed; would add one with least-privilege roles if it did.

**Multi-environment?** More overlays (`staging`, `prod`), separate GCP projects per environment, Cloud Deploy to promote the *same digest* through them with approvals.

**Scaling?** HPA on CPU 2–6; Autopilot provisions nodes automatically. For latency-driven scaling: custom metrics (RPS) via Managed Prometheus.

**Cost?** Autopilot free-tier credit covers the cluster fee; billed on pod requests; one forwarding rule + NAT. Destroy when idle.

**What would you monitor?** Golden signals at the LB and pod level; SLO on availability and latency with burn-rate alerts; deployment events correlated with error rate.

**Why `node` and not `npm start` as CMD?** npm doesn't forward `SIGTERM` reliably to the child, so the app wouldn't shut down gracefully and would be SIGKILLed after the grace period.

**Node is single-threaded – how does it scale?** Horizontally: one process per pod, small CPU request, HPA adds pods. Simpler and more observable than the cluster module inside a container.

**What did you not do and why?** HTTPS/WAF, Binary Authorization, multi-env, Terraform CI – each listed with its upgrade path in DESIGN.md §10. Kept the scope to what can be explained end-to-end in an interview.
