# Task 3 Monitoring

## Flow and Published Endpoint

Grafana is published at [https://grafana.final-work-k8s.raisa44.men](https://grafana.final-work-k8s.raisa44.men). The flow is HTTPS Gateway and certificate in `ingress/gateway_cert.yml` -> Helm-owned Grafana VirtualService -> `kube-prometheus-stack-grafana` Service -> Grafana. Grafana's provisioned `Prometheus` datasource uses UID `prometheus` and `http://kube-prometheus-stack-prometheus.monitoring.svc:9090`.

Prometheus scrapes kubelet/cAdvisor, node-exporter, kube-state-metrics, and the enabled ServiceMonitors. Prometheus retains 10 days on its 30Gi PVC; Grafana retains provisioned state on its 10Gi PVC.

## Metrics Purpose

| Metric/query | Purpose | Owner/use |
|---|---|---|
| `container_cpu_usage_seconds_total` via `rate()` | Per-pod CPU consumption in cores | Platform, capacity and noisy-pod diagnosis |
| `container_memory_working_set_bytes` | Working-set memory per pod | Platform, memory pressure and sizing |
| `kube_pod_container_status_restarts_total` | Container restart accumulation | Application/platform incident triage |
| `kube_pod_info` | Namespace/pod discovery variables | Platform dashboard filtering |
| `node_namespace_pod_container:container_cpu_usage_seconds_total:sum_irate` | CPU recording-rule series | Fast Kubernetes dashboard queries |
| `node_namespace_pod_container:container_memory_working_set_bytes` | Memory recording-rule series | Fast Kubernetes dashboard queries |
| `up` and `prometheus_target_interval_length_seconds` | Scrape/target health | Platform monitoring validation |

## Dashboards

- `Kubernetes / Pod Resources`: six-hour default range, 30-second refresh, namespace and pod multi-select/all variables, per-pod CPU and memory time series, current CPU and memory tables, and restart counts.
- `Kubernetes / Cluster Overview`: ready/running/non-running pod counts, cluster CPU and memory, namespace-filtered restarts, and scrape target health. Built-in kube-prometheus-stack dashboards are disabled to avoid unsupported or partially empty views.

## Verification

```bash
helm -n monitoring status kube-prometheus-stack
kubectl -n monitoring get pods,svc,pvc
kubectl -n monitoring get servicemonitor -o name
kubectl -n monitoring get prometheusrule -o name
kubectl -n monitoring get cm -l grafana_dashboard=1
kubectl -n monitoring get cm -l grafana_datasource=1 -o yaml
kubectl -n monitoring get virtualservice grafana -o yaml
kubectl -n monitoring get prometheus kube-prometheus-stack-prometheus -o yaml
kubectl -n monitoring logs deploy/kube-prometheus-stack-grafana -c dashboard-sc-dashboard --tail=100
kubectl -n monitoring logs deploy/kube-prometheus-stack-grafana -c datasource-sc-datasources --tail=100
```

Confirm healthy Prometheus targets for `kubelet`, `kube-state-metrics`, and `node-exporter`. Kubelet and cAdvisor are scraped from the kube-system kubelet Service over authenticated HTTPS on port 10250, using the Prometheus ServiceAccount token and cluster CA; the paths remain `/metrics` and `/metrics/cadvisor`.

In Prometheus or Grafana Explore, verify:

```promql
sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{job="kubelet",metrics_path="/metrics/cadvisor",container!="",container!="POD"}[5m]))
sum by (namespace, pod) (container_memory_working_set_bytes{job="kubelet",metrics_path="/metrics/cadvisor",container!="",container!="POD"})
node_namespace_pod_container:container_cpu_usage_seconds_total:sum_irate
node_namespace_pod_container:container_memory_working_set_bytes
up
```

## Artifacts and Post-Deploy

For the full infrastructure flow, run `./install.sh` from the repository root after the existing Grafana credential Secret is present. When only applying Task 3 changes to an already-running cluster, use this monitoring-only Helm command instead:

```bash
helm upgrade --install kube-prometheus-stack ./helm/kube-prometheus-stack --version 91.4.1 -n monitoring --create-namespace -f ./helm/kube-prometheus-stack/values.yaml --wait --timeout 15m
kubectl -n monitoring rollout status deploy/kube-prometheus-stack-grafana --timeout=10m
kubectl -n monitoring rollout status statefulset/prometheus-kube-prometheus-stack-prometheus --timeout=10m
```

Expected resources include Grafana with `grafana`, dashboard sidecar, and datasource sidecar containers; a ConfigMap labelled `grafana_dashboard=1`; a ConfigMap labelled `grafana_datasource=1`; Prometheus PVCs; the kubelet/cAdvisor ServiceMonitor; and CPU/memory PrometheusRules. Do not create or store credentials.

Artifact checklist:

- Capture the external HTTPS URL and certificate/browser success.
- Capture `Kubernetes / Pod Resources` with several hours selected, visible CPU/memory data, and namespace filtering demonstrated.
- Capture `Kubernetes / Cluster Overview` with several hours selected, showing node/pod counts, cluster CPU/memory, restarts, and target health.
- Capture datasource health and Prometheus targets showing healthy kubelet/cAdvisor and kube-state-metrics targets.
- Retain this document with the dashboard screenshots; never include credential values.

If dashboards are blank, confirm the Grafana pod has both sidecars, the dashboard ConfigMap has `grafana_dashboard: "1"`, the datasource ConfigMap has `grafana_datasource: "1"`, and sidecar logs show it was discovered. Check the datasource URL/UID, Prometheus targets, and that the selected namespace/pod variables are not empty. A newly deployed cluster cannot provide several hours of history until it has collected that history; use the default six-hour range after waiting.
