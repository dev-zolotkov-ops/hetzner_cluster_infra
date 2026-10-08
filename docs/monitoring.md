# Monitoring

## Purpose and Architecture

The stack collects cluster and application metrics and displays them in Grafana.

Grafana is published at [https://grafana.raisa44.men](https://grafana.raisa44.men). The request flow is: HTTPS Gateway and Certificate from `ingress/gateway_cert.yml` -> the Grafana VirtualService created by Helm -> Service `kube-prometheus-stack-grafana` -> Grafana. The preconfigured `Prometheus` datasource uses UID `prometheus` and the address `http://kube-prometheus-stack-prometheus.monitoring.svc:9090`.

Prometheus scrapes kubelet/cAdvisor, node-exporter, kube-state-metrics, and enabled ServiceMonitors. Prometheus data is stored for 10 days on a 30Gi PVC, and Grafana state is stored on a 10Gi PVC.

## Metric Purpose

| Metric/query | Purpose | Owner/scenario |
|---|---|---|
| `container_cpu_usage_seconds_total` through `rate()` | Pod CPU consumption in cores | Platform operations, capacity planning, and finding overloaded pods |
| `container_memory_working_set_bytes` | Pod working-set memory | Platform operations, diagnosing memory pressure, and selecting resources |
| `kube_pod_container_status_restarts_total` | Cumulative container restarts by `exported_namespace` (a counter, not a rate) | Application and platform incident investigation |
| `kube_pod_info` | Variables for finding namespaces and pods | Filtering platform dashboards |
| `node_namespace_pod_container:container_cpu_usage_seconds_total:sum_irate` | Recording-rule series for CPU | Fast Kubernetes dashboard queries |
| `node_namespace_pod_container:container_memory_working_set_bytes` | Recording-rule series for memory | Fast Kubernetes dashboard queries |
| `up` and `prometheus_target_interval_length_seconds` | Scrape and target status | Platform monitoring checks |
| `istio_requests_total` | Aggregated ingress HTTP requests by path and response code | Istio ingress dashboard and HTTP error analysis |

## Dashboards

- `Kubernetes / Pod Resources`: six-hour default range, 30-second refresh, multi-select namespace and pod variables with an all option, CPU and memory time series by pod, current CPU and memory tables, and restart counters.
- `Kubernetes / Cluster Overview`: counts of ready, running, and non-running pods; cluster CPU and memory; restarts filtered by namespace; and scrape target status. The built-in kube-prometheus-stack dashboards are disabled so that unsupported or partially empty views are not shown.
- `Istio / Ingress HTTP`: seven panels: requests over the selected range, current RPS, 4xx percentage, 5xx percentage, RPS by path, RPS by response code, and requests aggregated by path and response code.

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

Check that the `kubelet`, `kube-state-metrics`, and `node-exporter` targets are healthy. Kubelet and cAdvisor are scraped from the kube-system kubelet Service over authenticated HTTPS on port 10250, using the Prometheus ServiceAccount token and the cluster CA; the paths remain `/metrics` and `/metrics/cadvisor`.

In Prometheus or Grafana Explore, check the queries corresponding to the dashboards. For cAdvisor, use the `exported_namespace` label; do not add the `metrics_path` label to these series:

```promql
sum by (exported_namespace, pod) (rate(container_cpu_usage_seconds_total{job="kubelet",pod!="",container!="",container!="POD",image!="",exported_namespace=~".*"}[5m]))
sum by (exported_namespace, pod) (container_memory_working_set_bytes{job="kubelet",pod!="",container!="",container!="POD",image!="",exported_namespace=~".*"})
node_namespace_pod_container:container_cpu_usage_seconds_total:sum_irate
node_namespace_pod_container:container_memory_working_set_bytes
up
```

## Artifacts and Post-Installation Actions

For the complete infrastructure flow, create the Grafana credentials Secret and run `./install.sh` from the repository root. If this document is applied to an already running cluster, use:

```bash
helm upgrade --install kube-prometheus-stack ./helm/kube-prometheus-stack --version 91.4.1 -n monitoring --create-namespace -f ./helm/kube-prometheus-stack/values.yaml --wait --timeout 15m
kubectl -n monitoring rollout status deploy/kube-prometheus-stack-grafana --timeout=10m
kubectl -n monitoring rollout status statefulset/prometheus-kube-prometheus-stack-prometheus --timeout=10m
```

Expected resources include Grafana with `grafana`, dashboard sidecar, and datasource sidecar containers; a ConfigMap with label `grafana_dashboard=1`; a ConfigMap with label `grafana_datasource=1`; the Prometheus PVC; the kubelet/cAdvisor ServiceMonitor; and CPU and memory PrometheusRules. Do not create or store credentials in the repository.

Artifact checklist:

- Record the external HTTPS URL and a successful certificate/browser check.
- Save `Kubernetes / Pod Resources` with a several-hour range, visible CPU and memory, and demonstrated namespace filtering.
- Save `Kubernetes / Cluster Overview` with node and pod counts, cluster CPU and memory, restarts, and target status.
- Save the Prometheus datasource and target state with healthy kubelet/cAdvisor and kube-state-metrics.
- Save `Istio / Ingress HTTP` with requests, total RPS, 4xx/5xx percentages, RPS by path and response code, and the path/response-code table.
- Store this document with the dashboard screenshots; do not include credential values.

If a dashboard is empty, check both Grafana sidecars, the `grafana_dashboard: "1"` label on the dashboard ConfigMap, the `grafana_datasource: "1"` label on the datasource ConfigMap, and discovery in the sidecar logs. Check the datasource URL/UID, Prometheus targets, and non-empty namespace/pod variables. A new cluster cannot show several hours of history until data has accumulated; after waiting, use the six-hour default range.

## Bonus: Istio Ingress HTTP Observability

The bonus is complete. `ingress/ingress-telemetry.yml` applies Telemetry only to workloads labeled `istio: ingressgateway`. It adds the raw `request_path` from `request.url_path` to Prometheus with `CLIENT_AND_SERVER` mode. `helm/kube-prometheus-stack` creates a PodMonitor in the `monitoring` namespace that scrapes the `http-envoy-prom` pod port on `15090` at `/stats/prometheus`; a ServiceMonitor is not used because the Istio Service does not publish this port.

Istio metrics are aggregated monotonic counters, not a log of individual requests. The `Istio / Ingress HTTP` dashboard uses `istio_requests_total` and only source-side ingress gateway series so that one request is not counted twice:

```promql
sum by (request_path, response_code) (
  rate(istio_requests_total{
    reporter="source",
    source_workload="istio-ingressgateway",
    source_workload_namespace="istio-system",
    request_path!="",
    request_path=~"$path",
    response_code!=""
  }[5m])
)
```

The `$path` variable exists only inside the Grafana dashboard. The Prometheus API and shell queries use the `.*` regex, meaning all non-empty paths.

Verify after installation:

```bash
kubectl -n istio-system get telemetry ingressgateway-request-path -o yaml
kubectl -n monitoring get podmonitor istio-ingressgateway -o yaml
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

In another terminal, check the `istio-ingressgateway` target and its scrape URL with `:15090/stats/prometheus`:

```bash
curl -s http://127.0.0.1:9090/api/v1/targets | jq '.data.activeTargets[] | select(.scrapeUrl | test(":15090/stats/prometheus$")) | {health, scrapeUrl, lastError}'
```

Generate HTTPS traffic through the shared Gateway:

```bash
curl -sk -o /dev/null -w '%{http_code}\n' https://final-work-k8s.raisa44.men/
curl -sk -o /dev/null -w '%{http_code}\n' https://grafana.raisa44.men/
```

Run PromQL through the Prometheus API without a Grafana variable:

```bash
curl -sG http://127.0.0.1:9090/api/v1/query \
  --data-urlencode 'query=count by (reporter, source_workload, source_workload_namespace, request_path, response_code) (istio_requests_total{reporter="source",source_workload="istio-ingressgateway",source_workload_namespace="istio-system",request_path!="",request_path=~".*",response_code!=""})' \
  | jq .
```

Raw URL paths may contain identifiers, UUIDs, and other high-cardinality values. This increases the number of time series and Prometheus memory/disk usage. Before enabling substantial external traffic, check the actual `request_path` values and normalize routes or limit the path set if necessary.
