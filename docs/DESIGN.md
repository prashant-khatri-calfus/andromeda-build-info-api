# Design decisions

The brief is deliberately light, so the goal was: **smallest thing that is still
production-shaped**. Each decision below states what was chosen, why, and what
was traded away. The "Next steps" section is what I would add for a real
production service.

---

## 1. Application

**Decision: Node.js 22 LTS + Fastify, build info baked into the image at build time.**

- *Where does "build information" come from?* Three options:
  1. Computed at runtime (e.g. reading `.git`) – wrong: the image shouldn't contain `.git`, and runtime ≠ build.
  2. Injected at deploy time (ConfigMap/env in the manifest) – drifts: someone can change the manifest without changing the image.
  3. **Baked in at build time** (Docker `ARG` → `ENV` + OCI labels) – the image *is* the source of truth; a given digest always reports the same commit. ✅
- Runtime facts (pod, namespace, node) come from the **Downward API**, so the response also shows *which replica* answered – useful for proving load balancing and rollouts.
- Response has a **JSON schema** → Fastify validates and serialises output (fast-json-stringify) and the contract is explicit. Unknown fields can never leak into the response.
- Missing/blank metadata degrades to `"unknown"` instead of erroring – the endpoint must never fail just because a build arg wasn't passed (e.g. local runs).
- Separate **liveness** (`/healthz`) and **readiness** (`/readyz`) – a dependency failure should take a pod out of rotation, not restart it.
- JSON-structured logs (pino) to stdout with `severity`/`message` keys → parsed natively by Cloud Logging with correct log levels. Probe requests are logged only at warn+ so they don't flood logs.
- Graceful shutdown: on `SIGTERM`, `app.close()` stops accepting connections and drains in-flight requests, with a hard timeout below the pod grace period.
- Tests use the built-in `node:test` runner and Fastify's `inject()` (no network, no extra test framework).
- Stateless, no dependencies: scales horizontally with no coordination.

*Why Fastify over Express?* Built-in schema validation/serialisation, structured logging out of the box, faster, actively maintained, first-class async. Express would also be fine for one endpoint.

*Trade-off:* Go would give a smaller image and faster cold start; Node.js was chosen for readability, ecosystem and team familiarity. For this workload the difference is negligible.

## 2. Container image

- **Multi-stage** build: `npm ci --omit=dev --ignore-scripts` from the lockfile in a deps stage; only production `node_modules` + `src/` copied into the runtime stage (no dev deps, no npm cache, no tests).
- **Non-root** (UID 10001), works with `readOnlyRootFilesystem` (a small `emptyDir` on `/tmp`).
- Exec-form `CMD ["node", "src/server.js"]` (not `npm start`) so Node is PID 1 and receives `SIGTERM`; graceful shutdown timeout set below the pod's `terminationGracePeriodSeconds`.
- OCI labels (`revision`, `version`, `created`) mean the same metadata is visible in Artifact Registry without running the image.
- `package-lock.json` + `npm ci` for reproducible builds; `npm audit` gate in CI.

*Next step:* distroless/Chainguard Node base (needs replacing the `sleep` preStop with the native `sleep` lifecycle action and the exec-based verify step), SBOM + provenance (SLSA) attestation.

## 3. Platform: GKE Autopilot

**Why Autopilot over Standard?**

| | Autopilot | Standard |
|---|---|---|
| Node management | Google (patching, scaling, sizing) | Me |
| Billing | Per pod request | Per node (pay for idle) |
| Security baseline | Hardened by default (no privileged pods, Workload Identity, Shielded nodes, Dataplane V2) | Opt-in |
| Flexibility | No node SSH / DaemonSet limits / some restrictions | Full control |

For a stateless HTTP service there is nothing Standard gives me that I need, and
Autopilot removes a whole class of operational work. It's also cheapest for a
small, bursty workload because idle node capacity isn't billed.

**Cluster settings**
- **Regional** → control plane and pods spread across 3 zones; `topologySpreadConstraints` spread replicas across zones.
- **Private nodes** → no node has a public IP. Inbound only via the load balancer; outbound via **Cloud NAT**; Google APIs (Artifact Registry, Logging) via **Private Google Access**.
- **Control plane access** – this is the interesting bit:
  - A private cluster normally forces a choice: expose the public IP endpoint (to CI's unpredictable IPs) or run a private Cloud Build worker pool + VPC peering/VPN.
  - Instead I use GKE's **DNS-based control plane endpoint**. Every request is authenticated and authorised by **IAM** (`container.clusters.connect`) *before* reaching the API server, works from anywhere (including Cloud Build's default pool), and needs no IP allow-listing.
  - The legacy IP endpoint is locked to `admin_cidrs` (empty by default = closed).
- **Dedicated node service account** with only `roles/container.defaultNodeServiceAccount` + read on the one AR repo, instead of the default Compute SA (which has Editor).
- **Release channel REGULAR** + weekend maintenance window; PDB ensures upgrades don't take the service down.
- Image **vulnerability scanning** in Artifact Registry (Container Scanning API) on every push.

## 4. Network & exposure

**Decision: `Service type=LoadBalancer` → regional external passthrough Network Load Balancer (L4).**

Why this for the assignment:
- Simplest thing that gives a stable, public, highly available endpoint — one manifest, no extra controllers or certificates.
- **Static IP** reserved in Terraform and bound by name (`networking.gke.io/load-balancer-ip-addresses`), so the endpoint survives Service re-creation and can go in DNS.
- `loadBalancerClass: networking.gke.io/l4-regional-external` → backend-service-based NLB (the current GKE implementation, required for binding the reserved IP by name).
- `loadBalancerSourceRanges` → GKE programs VPC firewall rules so only listed CIDRs reach the LB. Open (`0.0.0.0/0`) for the demo; set per environment in the overlay.

Defence in depth inside the cluster:
- **NetworkPolicy** default-deny ingress *and* egress for the namespace; the API may only receive TCP/8080 and resolve DNS. It has no outbound dependencies, so a compromised pod can't call out.
- **Pod Security Admission `restricted`** on the namespace; pods run non-root, no privilege escalation, all capabilities dropped, seccomp `RuntimeDefault`, read-only rootfs.
- No Kubernetes API token mounted (`automountServiceAccountToken: false`).

**Trade-offs I'm consciously accepting (and the upgrade path):**

| Gap with L4 LoadBalancer | Production upgrade |
|---|---|
| Plain HTTP, no TLS | **Gateway API** (`gke-l7-global-external-managed`) + Google-managed certificate / Certificate Manager |
| No WAF / DDoS L7 rules / rate limiting | **Cloud Armor** policy attached via `GCPBackendPolicy` |
| Regional only | Global external Application LB, anycast IP, multi-region backends |
| No CDN | Cloud CDN (build info is cacheable for a few seconds) |
| No auth | IAP or API Gateway/Apigee with API keys/JWT if not public |

The app and manifests don't change for that upgrade — only the Service type
(→ `ClusterIP`) and a new `Gateway` + `HTTPRoute`. That is the main reason I
was comfortable starting with L4.

## 5. CI/CD: Cloud Build

Pipeline (`cloudbuild.yaml`):

1. **test** – `npm ci`, eslint, `node --test`, `npm audit` (high+ in prod deps). Fail before building anything.
2. **build** – inject `VERSION`, commit, branch, build time, Cloud Build `BUILD_ID` as build args.
3. **push** – tags `<sha>` and `<version>-<sha>`; capture the **digest**.
4. **deploy** – `get-credentials --dns-endpoint`, pin the image **by digest** in the Kustomize overlay, `kubectl apply -k`, wait for `rollout status`. Tags are mutable; digests are not, so what was tested is exactly what runs.
5. **verify** – exec into every pod of the new ReplicaSet and assert `/build-info` reports *this* commit. Rollout success only proves the pods are healthy; this proves they're the *right* pods. It's the assignment's own endpoint used as a deployment check.

Security of the pipeline:
- Runs as a **dedicated user-managed SA** (not the legacy Cloud Build SA): `logging.logWriter`, `container.developer`, and `artifactregistry.writer` **scoped to the one repository**.
- No long-lived keys anywhere. GitHub connects via the Cloud Build GitHub App.
- `included_files` on the trigger: docs/Terraform-only changes don't redeploy the app.

Zero-downtime rollouts: `maxUnavailable: 0`, `maxSurge: 1`, readiness gate, `preStop` sleep so the LB stops sending traffic before the process exits, graceful Node shutdown (`app.close()`).

*Why Cloud Build instead of GitHub Actions?* GCP-native, IAM-native identity (no Workload Identity Federation setup), logs in Cloud Logging, one less external system. GitHub Actions + WIF is an equally valid choice if the team already standardises on it.

*Next steps:* Binary Authorization (only signed/attested images run), Cloud Deploy for promotion dev → staging → prod with approvals and canaries, Terraform plan/apply in its own pipeline with policy checks.

## 6. Infrastructure as Code: Terraform

- Everything except the Terraform state bucket and the one-time GitHub App install is code.
- **GCS backend** – versioned bucket, built-in locking.
- Provider `default_labels` → every resource carries `app`, `env`, `managed-by` for cost allocation.
- `deletion_protection` variable – on by default, off for throwaway demos.
- Infra (Terraform) and app delivery (Cloud Build + Kustomize) are deliberately separate lifecycles: infrastructure changes rarely and needs review of a `plan`; the app ships many times a day.

*Next steps:* split into modules (network / cluster / registry) and per-env directories or workspaces; Terraform in CI with `plan` on PR and `apply` on merge; `tflint`, `checkov`.

## 7. Kubernetes configuration: Kustomize

- Base + overlay keeps environments DRY with no templating language.
- `configMapGenerator` → hash-suffixed ConfigMap, so a config change triggers a rolling restart automatically.
- HPA (2–6 replicas, CPU 70%) owns the replica count (no `replicas:` in the Deployment, so `apply` never fights the autoscaler), PDB (`minAvailable: 1`), zone spread → survives a zone loss and node upgrades.
- Requests = limits (Autopilot semantics) – Guaranteed QoS, predictable billing.

*Alternative:* Helm. Better if the chart is shipped to other teams; for one internal service Kustomize is simpler and built into `kubectl`.

## 8. Observability

Present today: structured JSON logs → Cloud Logging; GKE system metrics + Managed Prometheus collection available on Autopilot; LB metrics in Cloud Monitoring; build-info endpoint itself shows what's deployed where.

*Next steps:* `/metrics` via `fastify-metrics` (prom-client) + `PodMonitoring`; SLO (e.g. 99.9% of `/build-info` < 300 ms) with burn-rate alerting; OpenTelemetry traces to Cloud Trace; uptime check against the public IP.

## 9. Cost (rough, demo scale)

- Autopilot cluster fee is covered by the GKE free-tier credit for one cluster per billing account.
- Pods: 2 × (250m CPU, 256Mi) billed per second of request.
- One regional forwarding rule + static IP, Cloud NAT gateway, Artifact Registry storage.

Low tens of USD per month if left running; `terraform destroy` when idle. (Check current pricing — figures change.)

## 10. What I'd do differently for production (summary)

1. Gateway API + HTTPS + Cloud Armor; DNS name via Cloud DNS.
2. Binary Authorization + SBOM/provenance; distroless base image.
3. Cloud Deploy promotion pipeline with canary and automatic rollback on SLO burn.
4. Separate projects per environment (dev/stage/prod) under a folder with org policies; Shared VPC.
5. Terraform modules, CI for infra, policy-as-code.
6. Namespace-scoped RBAC for the deployer instead of project-level `container.developer`.
7. SLOs, alerting, tracing.
