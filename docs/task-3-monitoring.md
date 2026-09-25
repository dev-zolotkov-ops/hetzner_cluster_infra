# Task 3: Мониторинг

## Цель и архитектура

Стек собирает метрики кластера и приложений и отображает их в Grafana.

Grafana опубликована по адресу [https://grafana.raisa44.men](https://grafana.raisa44.men). Поток запроса: HTTPS Gateway и Certificate из `ingress/gateway_cert.yml` -> VirtualService Grafana, создаваемый Helm -> Service `kube-prometheus-stack-grafana` -> Grafana. Преднастроенный datasource `Prometheus` использует UID `prometheus` и адрес `http://kube-prometheus-stack-prometheus.monitoring.svc:9090`.

Prometheus скрапит kubelet/cAdvisor, node-exporter, kube-state-metrics и включённые ServiceMonitor. Данные Prometheus хранятся 10 дней на PVC 30Gi, состояние Grafana сохраняется на PVC 10Gi.

## Назначение метрик

| Метрика/запрос | Назначение | Ответственный/сценарий |
|---|---|---|
| `container_cpu_usage_seconds_total` через `rate()` | Потребление CPU pod в ядрах | Платформа, планирование ёмкости и поиск перегруженных pod |
| `container_memory_working_set_bytes` | Рабочий набор памяти pod | Платформа, диагностика давления на память и подбор ресурсов |
| `kube_pod_container_status_restarts_total` | Накопительное число перезапусков контейнеров по `exported_namespace` (counter, не rate) | Разбор инцидентов приложения и платформы |
| `kube_pod_info` | Переменные для поиска namespace/pod | Фильтрация dashboard платформы |
| `node_namespace_pod_container:container_cpu_usage_seconds_total:sum_irate` | Ряд recording rule для CPU | Быстрые запросы Kubernetes dashboard |
| `node_namespace_pod_container:container_memory_working_set_bytes` | Ряд recording rule для памяти | Быстрые запросы Kubernetes dashboard |
| `up` и `prometheus_target_interval_length_seconds` | Состояние scrape и target | Проверка мониторинга платформы |
| `istio_requests_total` | Агрегированные ingress HTTP-запросы по пути и коду ответа | Dashboard Istio ingress и анализ HTTP-ошибок |

## Дашборды

- `Kubernetes / Pod Resources`: диапазон по умолчанию шесть часов, обновление каждые 30 секунд, множественный выбор namespace и pod с вариантом выбора всех, временные ряды CPU и памяти по pod, текущие таблицы CPU и памяти, счётчики перезапусков.
- `Kubernetes / Cluster Overview`: число готовых, работающих и неработающих pod, CPU и память кластера, перезапуски с фильтрацией по namespace и состояние scrape target. Встроенные dashboard kube-prometheus-stack отключены, чтобы не показывать неподдерживаемые или частично пустые представления.
- `Istio / Ingress HTTP`: семь панелей: запросы за выбранный диапазон, текущий RPS, доля 4xx, доля 5xx, RPS по пути, RPS по коду ответа и запросы с агрегацией по пути и коду ответа.

## Проверка

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

Проверьте исправные target `kubelet`, `kube-state-metrics` и `node-exporter`. Kubelet и cAdvisor скрапятся с kube-system kubelet Service по аутентифицированному HTTPS на порту 10250 с использованием токена ServiceAccount Prometheus и cluster CA; пути остаются `/metrics` и `/metrics/cadvisor`.

В Prometheus или Grafana Explore проверьте запросы, соответствующие dashboard. Для cAdvisor используйте label `exported_namespace`; label `metrics_path` в этих рядах не добавляйте:

```promql
sum by (exported_namespace, pod) (rate(container_cpu_usage_seconds_total{job="kubelet",pod!="",container!="",container!="POD",image!="",exported_namespace=~".*"}[5m]))
sum by (exported_namespace, pod) (container_memory_working_set_bytes{job="kubelet",pod!="",container!="",container!="POD",image!="",exported_namespace=~".*"})
node_namespace_pod_container:container_cpu_usage_seconds_total:sum_irate
node_namespace_pod_container:container_memory_working_set_bytes
up
```

## Артефакты и действия после установки

Для полного потока инфраструктуры после создания Secret с учётными данными Grafana выполните `./install.sh` из корня репозитория. Если Task 3 применяется к уже работающему кластеру, используйте:

```bash
helm upgrade --install kube-prometheus-stack ./helm/kube-prometheus-stack --version 91.4.1 -n monitoring --create-namespace -f ./helm/kube-prometheus-stack/values.yaml --wait --timeout 15m
kubectl -n monitoring rollout status deploy/kube-prometheus-stack-grafana --timeout=10m
kubectl -n monitoring rollout status statefulset/prometheus-kube-prometheus-stack-prometheus --timeout=10m
```

Ожидаются Grafana с контейнерами `grafana`, dashboard sidecar и datasource sidecar; ConfigMap с label `grafana_dashboard=1`; ConfigMap с label `grafana_datasource=1`; PVC Prometheus; ServiceMonitor kubelet/cAdvisor; PrometheusRules CPU и памяти. Не создавайте и не храните учётные данные в репозитории.

Чек-лист артефактов:

- Зафиксировать внешний HTTPS URL и успешную проверку сертификата/браузера.
- Сохранить `Kubernetes / Pod Resources` с диапазоном в несколько часов, видимыми CPU/памятью и продемонстрированной фильтрацией namespace.
- Сохранить `Kubernetes / Cluster Overview` с числом узлов и pod, CPU/памятью кластера, перезапусками и состоянием target.
- Сохранить состояние datasource и target Prometheus с исправными kubelet/cAdvisor и kube-state-metrics.
- Сохранить `Istio / Ingress HTTP` с запросами, общим RPS, долями 4xx/5xx, RPS по пути и коду ответа и таблицей пути/кода ответа.
- Хранить этот документ вместе со скриншотами dashboard; значения учётных данных не включать.

Если dashboard пуст, проверьте оба sidecar Grafana, label `grafana_dashboard: "1"` у ConfigMap dashboard, label `grafana_datasource: "1"` у ConfigMap datasource и обнаружение в логах sidecar. Проверьте URL/UID datasource, target Prometheus и непустые переменные namespace/pod. Новый кластер не может показать несколько часов истории до накопления данных; после ожидания используйте диапазон по умолчанию шесть часов.

## Бонус: HTTP-наблюдаемость Istio ingress

Бонус выполнен. `ingress/ingress-telemetry.yml` применяет Telemetry только к workload с меткой `istio: ingressgateway`. Для Prometheus добавляется raw `request_path` из `request.url_path` с режимом `CLIENT_AND_SERVER`. `helm/kube-prometheus-stack` создаёт PodMonitor в namespace `monitoring`, который скрапит pod-порт `http-envoy-prom` на `15090` по пути `/stats/prometheus`; ServiceMonitor не используется, поскольку Service Istio не публикует этот порт.

Метрики Istio являются агрегированными монотонными счётчиками, а не журналом отдельных запросов. Dashboard `Istio / Ingress HTTP` использует `istio_requests_total` и только source-side серии ingress gateway, чтобы не считать один запрос дважды:

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

Переменная `$path` существует только внутри Grafana dashboard. В Prometheus API и shell-запросах используется regex `.*`, то есть все непустые пути.

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
curl -sk -o /dev/null -w '%{http_code}\n' https://grafana.raisa44.men/
```

Выполните PromQL через Prometheus API без Grafana-переменной:

```bash
curl -sG http://127.0.0.1:9090/api/v1/query \
  --data-urlencode 'query=count by (reporter, source_workload, source_workload_namespace, request_path, response_code) (istio_requests_total{reporter="source",source_workload="istio-ingressgateway",source_workload_namespace="istio-system",request_path!="",request_path=~".*",response_code!=""})' \
  | jq .
```

Сырые URL-пути могут содержать идентификаторы, UUID и другие значения с высокой кардинальностью. Это увеличивает число временных рядов и расход памяти/диска Prometheus. Перед включением большого внешнего трафика проверьте фактические значения `request_path` и при необходимости нормализуйте маршруты или ограничьте набор путей.
