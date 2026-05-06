# PowerSync Helm Chart

This Helm chart deploys [PowerSync](https://www.powersync.com/) services on a Kubernetes cluster.

## Prerequisites

- Kubernetes 1.21+
- Helm 3.0+
- A bucket-storage database (MongoDB or Postgres) and a source database
- An NGINX-compatible Ingress controller (or any L7 controller with HTTP/2 + WebSockets)
- For autoscaling on `powersync_concurrent_connections`: Prometheus + [prometheus-adapter](https://github.com/kubernetes-sigs/prometheus-adapter), or [KEDA](https://keda.sh/)

## Installing the Chart

```bash
# Copy the default values and customize them
cp values.yaml my-values.yaml
# Edit my-values.yaml with your specific configuration

helm install powersync ./powersync-helm-chart -f my-values.yaml
```

## What gets deployed

| Workload | Kind | Notes |
|---|---|---|
| `*-api` | Deployment | Sync API. Behind a Service + Ingress. HPA + PDB. |
| `*-replication` | Deployment | **Warm-standby (2 replicas)** — only one actively replicates; the other waits for the replication lock and takes over on failure. PDB + anti-affinity included. |
| `*-compact` | CronJob | Daily bucket-storage compaction. |
| `*-migrate` | Job | Pre-install/pre-upgrade hook running `migrate up`. |
| `*-config` | Secret | Renders `powersyncConfig` to JSON. |
| `*-sync-streams` | ConfigMap | Sync Stream definitions (edition 3 sync config). |
| `*` Ingress | Ingress | TLS + NGINX streaming annotations. |
| `*-api` HPA | HPA | Scales on `powersync_concurrent_connections` + CPU. |
| `*-api` PDB | PodDisruptionBudget | `minAvailable: 1`. |
| `*-api` NetworkPolicy | NetworkPolicy | Optional, off by default. |

## PowerSync specifications

Numbers and constraints from the [PowerSync deployment-architecture docs](https://docs.powersync.com/maintenance-ops/self-hosting/deployment-architecture). The chart defaults follow these.

### Per-pod limits

| Pod | Limit | What happens at the limit |
|---|---|---|
| API | **~100 target / 200 hard cap** concurrent client connections per pod | Pod returns error code `PSYNC_S2304` (max concurrent connections reached). Scale out before you hit 200. |
| Replication | **1 active replicator at any time** (warm-standby pattern, default 2 pods) | The lock holder actively replicates; the standby pod blocks on `PSYNC_S1003` and takes over instantly if the leader exits. Mirrors the PowerSync Cloud paid-plan default. Older service versions log noisily on the standby — set `replication.replicas: 1` + `strategy: Recreate` if needed. |

### Sizing baseline

| Component | Replicas | Memory (req / limit) | CPU | Notes |
|---|---|---|---|---|
| API | 2+ (HPA) | 1Gi / 2Gi | 1 vCPU | Stateless. Scale horizontally on connection count. |
| Replication | 2 (1 active + 1 warm standby) | 1Gi / 2Gi | 1 vCPU | Lock arbitration ensures only one replicates at a time. Standby is idle (low CPU) but takes over instantly on leader failure. |
| Compact (CronJob) | 1× daily | 512Mi / 1Gi | 100m / 1 | Off-peak. |
| Bucket storage (Postgres) | 3 (1 primary + 2 replicas) | 2Gi+ | 1+ vCPU | Out of scope for this chart — deploy via [CloudNativePG](https://cloudnative-pg.io/). |

**Scaling rules:**
- API → add 1 pod per ~100 concurrent client connections. HPA does this automatically using `powersync_concurrent_connections`.
- Replication → vertical only. Scales with **source-database write throughput**, not client count.
- For larger rows / heavier load, double API + replication to **2Gi / 2 vCPU**.

### Heap sizing

`NODE_OPTIONS=--max-old-space-size-percentage=80` — the V8 old-generation heap is sized as 80% of the container memory limit, so it auto-tracks `resources.limits.memory`. No manual recalculation when you change limits. (Older PowerSync deployment guides hard-code `--max-old-space-size=800` for a 1Gi container; the percentage flag is the same idea, just dynamic.)

### When you need more than one PowerSync instance

A single PowerSync instance (one replicator + horizontally-scaled API pods) can handle roughly **50,000–100,000 concurrent client connections**, depending on the size of the rows being synced from the source database. Beyond that, configure a [second instance](https://docs.powersync.com/maintenance-ops/self-hosting/multiple-instances) — a separate deployment with its own bucket-storage database, sharing the same source DB.

**Critical client-side constraint:** each instance maintains its own copy of the bucket data, so a client **must always connect to the same instance** every time. Switching instances forces a full resync from scratch. Multiple instances cannot be load-balanced behind the same subdomain. Recommended routing: have the client fetch its endpoint from your backend (or compute it deterministically, e.g. `hash(user_id) % n`) and pin it.

This chart deploys one instance; for multi-instance, install the chart multiple times under different release names, ingress hosts, and bucket-storage configs.

### Health probe endpoints

Defaults use file-system probes (`MICRO_PROBE_TYPE=fs`, reading `/app/.probes/{startup,poll,ready}`). HTTP equivalents are also available on port 8080:

| Probe | HTTP path | File path |
|---|---|---|
| Startup | `GET /probes/startup` | `/app/.probes/startup` |
| Liveness | `GET /probes/liveness` | `/app/.probes/poll` |
| Readiness | `GET /probes/readiness` | `/app/.probes/ready` |

To switch to HTTP probes, set `env.MICRO_PROBE_TYPE: "http"` and edit the deployment templates.

### Prometheus metrics

Exposed on container port `9464`. Enable in `powersyncConfig.telemetry`. Key metrics:

| Metric | Type | Use |
|---|---|---|
| `powersync_concurrent_connections` | Gauge | HPA scaling signal; alert when nearing 200/pod |
| `powersync_replication_lag_seconds` | Gauge | Alert when lag spikes |
| `powersync_operations_synced_total` | Counter | Sync throughput |
| `powersync_data_synced_bytes_total` | Counter | Egress volume (uncompressed) |
| `powersync_data_sent_bytes_total` | Counter | Egress volume (compressed) |
| `powersync_data_replicated_bytes_total` | Counter | Source-DB → bucket-storage volume |
| `powersync_rows_replicated_total` | Counter | Replication throughput |
| `powersync_transactions_replicated_total` | Counter | Replication throughput |
| `powersync_replication_storage_size_bytes` | Gauge | Bucket-storage growth |
| `powersync_operation_storage_size_bytes` | Gauge | Bucket-storage growth |

### Network requirements

| From | To | Protocol | Why |
|---|---|---|---|
| Client | Ingress → API | HTTPS (long-lived) | Sync stream — needs `proxy-buffering: off` |
| API pods | Bucket-storage DB | TCP | Read materialised buckets |
| API pods | JWKS endpoint | HTTPS (egress) | Verify client JWTs |
| Replication pod | Source DB | TCP (logical replication / oplog) | CDC stream |
| Replication pod | Bucket-storage DB | TCP | Write materialised buckets |
| Compact CronJob | Bucket-storage DB | TCP | Daily compaction |

## Autoscaling on concurrent connections

The chart ships with an HPA disabled by default. Enable with:

```yaml
api:
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 10
    targetConnectionsPerPod: 100
    targetCPUUtilizationPercentage: 70
```

The HPA reads the `powersync_concurrent_connections` Prometheus gauge as a `Pods`-type metric. To make this metric visible to Kubernetes, deploy [prometheus-adapter](https://github.com/kubernetes-sigs/prometheus-adapter) with a rule that maps the metric to the `custom.metrics.k8s.io` API. Sample rule:

```yaml
rules:
  custom:
    - seriesQuery: 'powersync_concurrent_connections{namespace!="",pod!=""}'
      resources:
        overrides:
          namespace: { resource: namespace }
          pod: { resource: pod }
      name:
        matches: "^(.*)$"
        as: "$1"
      metricsQuery: 'avg_over_time(<<.Series>>{<<.LabelMatchers>>}[2m])'
```

Verify it's working:

```bash
kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1/namespaces/<ns>/pods/*/powersync_concurrent_connections"
```

Alternatively, use KEDA's `prometheus` scaler — set `autoscaling.enabled: false` and define a `ScaledObject` outside this chart.

## Ingress

The chart sets these NGINX annotations by default — **without them, HTTP streaming sync breaks**:

```yaml
nginx.ingress.kubernetes.io/proxy-buffering: "off"
nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
```

Use a **dedicated subdomain** for the API (e.g. `powersync.example.com`). PowerSync cannot share a subdomain with another service.

## Secrets

`powersyncConfig` is rendered into a Kubernetes Secret. Storing real credentials in `values.yaml` is fine for a demo, but for production prefer:

- Helm `--set-file` for individual values
- [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets)
- [External Secrets Operator](https://external-secrets.io/) backed by Vault, AWS Secrets Manager, etc.

The chart's example `client_auth.jwks` uses a shared-secret HS256 key for demo purposes only. **For production, use asymmetric keys (RS256, EdDSA, ECDSA)** via `jwks_uri`.

## Migrations

`powersyncConfig.migrations.disable_auto_migration: true` is set by default. The `*-migrate` Job runs `migrate up` as a Helm `pre-install` and `pre-upgrade` hook so migrations execute before pods start. To disable, set `migration.enabled: false`.

## Common values

| Parameter | Description | Default |
|-----------|-------------|---------|
| `namespace` | Kubernetes namespace | `powersync-poc` |
| `image.repository` | Image repository | `journeyapps/powersync-service` |
| `image.tag` | Image tag | `1.20.5` |
| `api.replicas` | API replicas (when HPA disabled) | `2` |
| `api.autoscaling.enabled` | Enable HPA | `false` |
| `replication.replicas` | Replication pods (warm-standby pattern) | `2` |
| `replication.podAntiAffinity.enabled` | Spread replication pods across nodes | `true` |
| `api.autoscaling.targetConnectionsPerPod` | HPA target | `100` |
| `api.pdb.enabled` | Enable PodDisruptionBudget | `true` |
| `compact.enabled` | Enable daily compact CronJob | `true` |
| `compact.schedule` | Cron schedule | `0 3 * * *` |
| `migration.enabled` | Run migrate-up as a Helm hook | `true` |
| `networkPolicy.enabled` | Restrict API ingress | `false` |
| `ingress.host` | Ingress hostname | `YOUR_FQDN_HERE.example.com` |

## Troubleshooting

```bash
# Pod logs
kubectl logs -n powersync-poc -l app=<release>-api
kubectl logs -n powersync-poc -l app=<release>-replication

# Pod status
kubectl get pods -n powersync-poc

# HPA status (when enabled)
kubectl get hpa -n powersync-poc
kubectl describe hpa -n powersync-poc

# Migration job output
kubectl logs -n powersync-poc job/<release>-migrate
```

## References

- [PowerSync — Deployment Architecture](https://docs.powersync.com/maintenance-ops/self-hosting/deployment-architecture)
- [PowerSync — Health Checks](https://docs.powersync.com/maintenance-ops/self-hosting/healthchecks)
- [PowerSync — Self-Hosted Configuration](https://docs.powersync.com/configuration/powersync-service/self-hosted-instances)
- [PowerSync — Multiple Instances (scale-out)](https://docs.powersync.com/maintenance-ops/self-hosting/multiple-instances)
