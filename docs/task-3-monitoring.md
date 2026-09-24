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
| `istio_requests_total` | Aggregated ingress HTTP requests by path and response code | Istio ingress dashboard and HTTP error analysis |

## Dashboards

- `Kubernetes / Pod Resources`: six-hour default range, 30-second refresh, namespace and pod multi-select/all variables, per-pod CPU and memory time series, current CPU and memory tables, and restart counts.
- `Kubernetes / Cluster Overview`: ready/running/non-running pod counts, cluster CPU and memory, namespace-filtered restarts, and scrape target health. Built-in kube-prometheus-stack dashboards are disabled to avoid unsupported or partially empty views.
- `Istio / Ingress HTTP`: seven panels for selected-range requests, current RPS, 4xx percentage, 5xx percentage, RPS by path, RPS by response code, and requests aggregated by path and response code.

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
- Capture `Istio / Ingress HTTP` showing selected-range requests, current total RPS, 4xx percentage, 5xx percentage, RPS by request path, RPS by response code, and the path/response-code table.
- Retain this document with the dashboard screenshots; never include credential values.

If dashboards are blank, confirm the Grafana pod has both sidecars, the dashboard ConfigMap has `grafana_dashboard: "1"`, the datasource ConfigMap has `grafana_datasource: "1"`, and sidecar logs show it was discovered. Check the datasource URL/UID, Prometheus targets, and that the selected namespace/pod variables are not empty. A newly deployed cluster cannot provide several hours of history until it has collected that history; use the default six-hour range after waiting.

## Бонус: HTTP-наблюдаемость Istio ingress

Бонус выполнен. `ingress/ingress-telemetry.yml` применяет Telemetry только к workload с меткой `istio: ingressgateway`. Для Prometheus добавляется raw `request_path` из `request.url_path` с режимом `CLIENT_AND_SERVER`. `helm/kube-prometheus-stack` создаёт PodMonitor в namespace `monitoring`, который скрапит pod-порт `http-envoy-prom` на `15090` по пути `/stats/prometheus`; ServiceMonitor не используется, поскольку Service Istio не публикует этот порт.

Метрики Istio являются агрегированными монотонными счётчиками, а не журналом отдельных запросов. Панель `Istio / Ingress HTTP` строится по `istio_requests_total` и использует только source-side серии ingress gateway, чтобы не считать один запрос дважды:

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

Переменная `$path` существует только внутри Grafana dashboard. В Prometheus API и shell-запросах ниже используется regex `.*`, то есть все непустые пути.

Проверка после установки:

```bash
kubectl -n istio-system get telemetry ingressgateway-request-path -o yaml
kubectl -n monitoring get podmonitor istio-ingressgateway -o yaml
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

В другом терминале проверьте target `istio-ingressgateway` и scrape URL с `:15090/stats/prometheus`:

```bash
curl -s http://127.0.0.1:9090/api/v1/targets | jq '.data.activeTargets[] | select(.scrapeUrl | test(":15090/stats/prometheus$")) | {health, scrapeUrl, lastError}'
```

Сгенерируйте HTTPS-трафик через общий Gateway:

```bash
curl -sk -o /dev/null -w '%{http_code}\n' https://final-work-k8s.raisa44.men/
curl -sk -o /dev/null -w '%{http_code}\n' https://grafana.final-work-k8s.raisa44.men/
```

Выполните PromQL через Prometheus API без Grafana-переменной:

```bash
curl -sG http://127.0.0.1:9090/api/v1/query \
  --data-urlencode 'query=count by (reporter, source_workload, source_workload_namespace, request_path, response_code) (istio_requests_total{reporter="source",source_workload="istio-ingressgateway",source_workload_namespace="istio-system",request_path!="",request_path=~".*",response_code!=""})' \
  | jq .
```

Сырые URL-пути могут содержать идентификаторы, UUID и другие значения с высокой кардинальностью. Это увеличивает число временных рядов и расход памяти/диска Prometheus. Перед включением большого внешнего трафика следует проверить фактические значения `request_path` и при необходимости нормализовать маршруты или ограничить набор путей.
