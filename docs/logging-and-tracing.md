# Loki and Alloy Logging and Tracing

## Purpose and Architecture

The stack collects Kubernetes container stdout/stderr and displays it in Grafana Explore:

```text
pod logs -> Alloy DaemonSet (one per node) -> Loki -> Grafana Explore
```

All components are in the `monitoring` namespace. Loki is not published externally; Grafana accesses its in-cluster ClusterIP Service.

Logging is unchanged when tracing is added. The additional trace flow is:

```text
Online Boutique (OTLP) -> Alloy Service/DaemonSet -> Tempo -> Grafana Explore
```

Alloy exposes internal ClusterIP ports `4317` (OTLP gRPC) and `4318` (OTLP HTTP). The existing log flow `pod -> Alloy -> Loki -> Grafana Explore` remains unchanged.

### Why Monolithic

For this small cluster, Loki `Monolithic` (SingleBinary) mode is used: one pod receives, indexes, and reads data at the same time. This is simpler to operate, does not require distributed components, MinIO, memcached, or replica coordination, and one instance is sufficient for the current log volume. Distributed/SimpleScalable modes would add separate read/write/backend components and operational overhead without providing this cluster with the fault tolerance or throughput it needs.

## Actual Configuration

| Parameter | Current value |
|---|---|
| Loki chart / app | `18.7.6` / `3.7.6` |
| Alloy chart / app | `1.12.1` / `v1.19.2` |
| Namespace | `monitoring` |
| Loki mode | `Monolithic`, `singleBinary.replicas: 1` |
| Other Loki replicas | `read: 0`, `write: 0`, `backend: 0` |
| Loki resources | requests `200m` CPU / `512Mi`; limits `1` CPU / `1Gi` |
| Loki storage | filesystem; PVC `10Gi`, StorageClass `hcloud-volumes` |
| PVC lifecycle | `enableStatefulSetAutoDeletePVC: false` |
| Retention | `168h` (7 days), compactor retention enabled |
| Schema/store | `boltdb-shipper`, `filesystem`, schema `v12`, index `index_`, period `24h`, starting on `2024-01-01` |
| Loki auth | `auth_enabled: false` |
| Replication factor | `1` |
| Loki endpoint | `http://loki.monitoring.svc.cluster.local:3100`; push: `/loki/api/v1/push` |
| Gateway/MinIO/cache | Gateway, MinIO, memcached, chunks/results cache disabled |
| Alloy controller | DaemonSet, including control-plane nodes through the toleration `node-role.kubernetes.io/control-plane:NoSchedule` |
| Alloy resources | requests `100m` CPU / `128Mi`; limits `500m` CPU / `512Mi` |
| Alloy Service | internal `ClusterIP`, OTLP gRPC `4317`, and OTLP HTTP `4318` |

Explicit `securityContext`, `nodeSelector`, affinity, and host mounts are not set in the final values. Alloy reads logs through the Kubernetes API; `/var/log` and the Docker socket are not mounted. Alloy creates a ServiceAccount, RBAC, and ClusterRoleBinding.

## Alloy Log Collection

The configuration is in `helm/alloy/values-final-work.yaml`:

1. `discovery.kubernetes "pods"` discovers pod targets.
2. `discovery.relabel "pods"` keeps only targets whose `__meta_kubernetes_pod_node_name` matches `K8S_NODE_NAME`.
3. `K8S_NODE_NAME` is obtained from `spec.nodeName` through the Downward API. Each DaemonSet therefore collects only logs from its own node and does not duplicate neighboring nodes.
4. The labels `namespace`, `pod`, `container`, `node_name`, and `app_kubernetes_io_name` are carried over; `job` is built as `namespace/app`.
5. `loki.source.kubernetes` reads pod logs through the API, `loki.process` adds `collector="alloy"` and `cluster="final-work-k8s"`, and `loki.write` sends them to Loki.

The main RBAC permissions are `get/list/watch` for `pods`, `pods/log`, `namespaces`, `services`, `endpoints`, `endpointslices`, and `nodes`. Extra labels increase Loki cardinality. Do not add unique values such as request IDs, URLs containing UUIDs, or the full message text to labels; those values must remain in the log content.

## Grafana Datasources

The `loki-datasource` release creates a `loki-datasource` ConfigMap with label `grafana_datasource: "1"`. Its datasource is named `Loki`, has UID `loki`, type `loki`, `access: proxy`, and URL `http://loki.monitoring.svc.cluster.local:3100`.

The `kube-prometheus-stack` values enable the Grafana datasource sidecar. It searches for ConfigMaps in namespace `monitoring` with resource `configmap` and imports ConfigMaps with the `grafana_datasource` label. Manual datasource creation in the UI is not required.

The `tempo-datasource` release creates a `tempo-datasource` ConfigMap with the same label. Its datasource is named `Tempo`, has UID `tempo`, type `tempo`, `access: proxy`, URL `http://tempo.monitoring.svc.cluster.local:3200`, and is not the default.

## Additional Tracing Pipeline

A monolithic Tempo is prepared in the repository:

| Parameter | Prepared value |
|---|---|
| Tempo chart / app | `3.0.0` / `3.0.3` |
| Tempo mode | Monolithic, `replicas: 1` |
| Tempo storage | local filesystem, PVC `10Gi`, StorageClass `hcloud-volumes` |
| Tempo PVC lifecycle | `enableStatefulSetAutoDeletePVC: false` |
| Tempo retention | `72h` |
| Tempo HTTP/query | `tempo` Service, port `3200` |
| OTLP receivers | gRPC `4317`, HTTP `4318` |

The span source is Online Boutique `v0.10.0` instrumented services, which send OTLP to the internal Alloy after the application is redeployed. The live cluster currently has no tracing environment variables: the code and Helm configuration are prepared, but the boutique has not yet been redeployed with this configuration. Therefore, no spans before redeployment is expected.

## Files and Installation Order

- `helm/loki/Chart.yaml`, `helm/loki/values-final-work.yaml` - Loki.
- `helm/alloy/Chart.yaml`, `helm/alloy/values-final-work.yaml` - Alloy and the pipeline.
- `helm/loki-datasource/Chart.yaml`, `templates/datasource.yaml` - datasource.
- `helm/tempo/Chart.yaml`, `helm/tempo/values-final-work.yaml` - Tempo 3.0.0/3.0.3 and storage.
- `helm/tempo-datasource/Chart.yaml`, `templates/datasource.yaml` - Tempo datasource.
- `helm/kube-prometheus-stack/values.yaml` - Grafana sidecar.
- `install.sh` - overall bootstrap order and Helm commands.
- `docs/monitoring.md` - related metrics and Grafana documentation.
- `README.md` - short reference and overall bootstrap.

In the `monitoring` section, the script installs `kube-prometheus-stack` first, then `loki`, `tempo`, `loki-datasource`, `tempo-datasource`, and finally `alloy`. Infrastructure and monitoring/observability must be ready first; Online Boutique can then be deployed or redeployed through GitLab CI with tracing environment variables. For the complete bootstrap, run `./install.sh` from the repository root after preparing secrets and infrastructure.

## Prerequisites, Backup, and Schema

You need working `kubectl`, Helm, a selected kubeconfig/context, working hcloud CCM/CSI, and the `hcloud-volumes` StorageClass; the Grafana Secret must exist before the full launch. Checks from the repository root:

```bash
kubectl config current-context
kubectl get nodes
kubectl get storageclass hcloud-volumes
kubectl -n monitoring get secret grafana-admin-credentials
```

Before the first upgrade, back up the existing Loki volume/PVC `storage-loki-0`. Never delete the existing Loki PVC: `enableStatefulSetAutoDeletePVC` is disabled in the values, but manual deletion still destroys the data. Preserve the current `boltdb-shipper`/v12 schema and the date `2024-01-01` so that old records remain readable. `allow_structured_metadata: false` remains in place until the planned migration to v13/TSDB; a new schema may be introduced only with a future date and a separate migration plan, not by retroactively replacing the current configuration.

## Deploy and Upgrade

From `/workspace/final_proj/cluster_infra`:

```bash
helm upgrade --install kube-prometheus-stack ./helm/kube-prometheus-stack --version 91.4.1 -n monitoring --create-namespace -f ./helm/kube-prometheus-stack/values.yaml --wait --timeout 15m
helm upgrade --install loki ./helm/loki -n monitoring -f ./helm/loki/values-final-work.yaml --wait --timeout 10m
helm upgrade --install tempo ./helm/tempo -n monitoring -f ./helm/tempo/values-final-work.yaml --wait --timeout 10m
helm upgrade --install loki-datasource ./helm/loki-datasource -n monitoring --wait --timeout 10m
helm upgrade --install tempo-datasource ./helm/tempo-datasource -n monitoring --wait --timeout 10m
helm upgrade --install alloy ./helm/alloy -n monitoring -f ./helm/alloy/values-final-work.yaml --wait --timeout 10m
```

These commands only prepare the observability stack. Afterward, redeploy Online Boutique `v0.10.0` through GitLab CI with tracing variables; until then, Tempo may be Ready but have no spans. The order matters: infrastructure and CSI, monitoring, Loki/Tempo, datasources, Alloy, then the boutique.

For a complete deployment rather than only the logging stack, use:

```bash
./install.sh
```

The script changes to the repository directory itself, but requires `.sensitive_data`, hcloud tools, and all prerequisites from `README.md`. Do not run a deployment merely to verify this documentation.

## Verification

```bash
kubectl -n monitoring get pods,ds,svc,pvc
kubectl -n monitoring get statefulset -l app.kubernetes.io/instance=loki
kubectl -n monitoring wait --for=condition=ready pod -l app.kubernetes.io/instance=loki --timeout=10m
kubectl -n monitoring rollout status daemonset/alloy --timeout=10m
kubectl -n monitoring get svc loki
kubectl -n monitoring get pvc storage-loki-0
kubectl -n monitoring port-forward svc/loki 3100:3100
curl -sS http://127.0.0.1:3100/ready
kubectl -n monitoring logs daemonset/alloy --all-containers --tail=100
kubectl -n monitoring get cm loki-datasource -o yaml
kubectl -n monitoring get cm -l grafana_datasource=1
```

For additional tracing after redeploying the boutique:

```bash
kubectl -n monitoring rollout status statefulset/tempo --timeout=10m
kubectl -n monitoring get svc tempo alloy
kubectl -n monitoring get pvc storage-tempo-0
kubectl -n monitoring get pods -l app.kubernetes.io/name=tempo
kubectl -n online-boutique get deploy -o yaml | grep -E 'ENABLE_TRACING|OTEL|OTLP|4317|4318'
kubectl -n monitoring port-forward svc/tempo 3200:3200
kubectl -n monitoring port-forward pod/<ALLOY_POD> 12345:12345
```

In Grafana, select the `Tempo` datasource and run this TraceQL query:

```traceql
{ resource.service.name = "frontend" }
```

Alternatively, use a `service.name` filter. Generate sample traffic in Online Boutique before searching for new spans. Before redeploying the instrumented boutique, zero spans is expected. If Alloy span metrics are available, also check `http://127.0.0.1:12345/metrics` through the Alloy pod port-forward; these metrics likewise do not appear until tracing is enabled.

To check ingestion after generating traffic, use the Loki API through the port-forward:

```bash
curl -sG http://127.0.0.1:3100/loki/api/v1/query_range \
  --data-urlencode 'query={collector="alloy"}' \
  --data-urlencode 'limit=20'
```

Expect `Ready` from `/ready`, Alloy pods on the nodes, Bound PVCs, and a non-empty `result` from `query_range`.

## Grafana Explore and LogQL

Open Grafana, select the `Loki` datasource, set the time range to **Last 15 minutes**, and run:

```logql
{pod=~"frontend-.*"}
{pod=~"checkoutservice-.*"}
{pod=~"loadgenerator-.*"}
{collector="alloy"}
{container="istio-proxy"}
```

The last query shows the Istio sidecar. To compare several microservices, use `{pod=~"(frontend|checkoutservice|loadgenerator)-.*"}`.

## Troubleshooting

- **`unsupported compactor.delete_request_store`**: this indicates an old Loki or old final configuration. The current chart/Loki pair `18.7.6`/`3.7.6` contains `loki.compactor.delete_request_store: filesystem`; check that the upgrade is not using an outdated values file or another Loki image. Do not blindly remove the field from the current values and do not mix versions.
- **`unknown field replicas`**: do not set a general `loki.replicas`. In the current chart, the count is set with `singleBinary.replicas`, while `read`, `write`, and `backend` are zero. Remove the stale key and repeat rendering/upgrading with the same values.
- **No logs**: check the Alloy DaemonSet, its logs, and RBAC; compare the pod's `spec.nodeName` with `K8S_NODE_NAME`. Then check Loki DNS/port and the `{collector="alloy"}` query. Host mounts are not needed for the Kubernetes API.
- **Duplicates**: keep one Alloy DaemonSet and ensure the `K8S_NODE_NAME` filter has not been removed. Do not enable a file-based collector or a second Alloy installation in parallel without explicitly separating targets.
- **PVC Pending**: check `kubectl get storageclass hcloud-volumes`, hcloud CSI, and `kubectl -n monitoring describe pvc storage-loki-0` events. Do not delete the PVC to fix Pending.
- **Datasource missing**: check the ConfigMap and `grafana_datasource=1` label, namespace `monitoring`, the Grafana `datasource-sc-datasources` container and its logs. Ensure the `loki-datasource` release is installed after the Grafana chart; the URL must point to `loki.monitoring.svc.cluster.local:3100`.

## Uninstall and Data

To remove only the Helm releases:

```bash
helm uninstall alloy -n monitoring
helm uninstall tempo-datasource -n monitoring
helm uninstall loki-datasource -n monitoring
helm uninstall tempo -n monitoring
helm uninstall loki -n monitoring
```

This is not a data-deletion instruction. Preserve PVCs and Loki contents separately; before deleting a release, confirm the backup and whether persistent data must be removed. For general monitoring removal, also account for the `kube-prometheus-stack` release and its PVCs. This document intentionally contains no PVC deletion command.

## Acceptance Checklist

- [ ] Loki chart `18.7.6` / app `3.7.6` and Alloy chart `1.12.1` / app `v1.19.2` confirmed.
- [ ] One Loki pod Ready, PVC `storage-loki-0` Bound, StorageClass `hcloud-volumes`.
- [ ] Alloy DaemonSet Ready on worker and control-plane nodes, with no RBAC errors.
- [ ] Loki `/ready` returns a successful response.
- [ ] ConfigMap `loki-datasource` is found by the Grafana sidecar, and datasource `Loki` is visible in Explore.
- [ ] Logs from at least two or three services, `frontend`, `checkoutservice`, and `loadgenerator`, found in the last 15 minutes.
- [ ] `{container="istio-proxy"}` checked separately, or the absence of an Istio sidecar on the selected pod explicitly recorded.
- [ ] `{collector="alloy"}` checked and duplicate entries ruled out.
- [ ] Tempo chart `3.0.0` / app `3.0.3`, PVC `storage-tempo-0` Bound, and `72h` retention confirmed.
- [ ] `tempo-datasource` found by the Grafana sidecar, and datasource `Tempo` is visible in Explore.
- [ ] After redeploying Online Boutique, spans found with TraceQL `{ resource.service.name = "frontend" }`.
- [ ] Confirmed that before redeploying the boutique, missing spans and Alloy span metrics are expected.
