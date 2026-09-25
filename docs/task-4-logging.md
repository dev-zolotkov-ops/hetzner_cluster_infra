# Task 4: Логирование Loki и Alloy

## Цель и архитектура

Стек собирает stdout/stderr контейнеров Kubernetes и показывает их в Grafana
Explore:

```text
логи pod -> Alloy DaemonSet (по одному на узел) -> Loki -> Grafana Explore
```

Все компоненты находятся в namespace `monitoring`. Loki не публикуется наружу:
Grafana обращается к его ClusterIP Service внутри кластера.

### Почему Monolithic

Для небольшого кластера выбран режим Loki `Monolithic` (SingleBinary): один pod
одновременно принимает, индексирует и читает данные. Это проще в эксплуатации,
не требует распределённых компонентов, MinIO, memcached и координации реплик, а
одного экземпляра достаточно при текущем объёме логов. Distributed/SimpleScalable
режимы добавили бы отдельные read/write/backend компоненты и операционные расходы,
не давая этому кластеру необходимой отказоустойчивости или пропускной способности.

## Фактическая конфигурация

| Параметр | Текущее значение |
|---|---|
| Loki chart / app | `18.7.6` / `3.7.6` |
| Alloy chart / app | `1.12.1` / `v1.19.2` |
| Namespace | `monitoring` |
| Loki mode | `Monolithic`, `singleBinary.replicas: 1` |
| Остальные Loki replicas | `read: 0`, `write: 0`, `backend: 0` |
| Loki resources | requests `200m` CPU / `512Mi`; limits `1` CPU / `1Gi` |
| Loki storage | filesystem; PVC `10Gi`, StorageClass `hcloud-volumes` |
| PVC lifecycle | `enableStatefulSetAutoDeletePVC: false` |
| Retention | `168h` (7 дней), compactor retention включён |
| Schema/store | `boltdb-shipper`, `filesystem`, schema `v12`, index `index_`, period `24h`, с `2024-01-01` |
| Loki auth | `auth_enabled: false` |
| Replication factor | `1` |
| Loki endpoint | `http://loki.monitoring.svc.cluster.local:3100`; push: `/loki/api/v1/push` |
| Gateway/MinIO/cache | Gateway, MinIO, memcached, chunks/results cache выключены |
| Alloy controller | DaemonSet, включая control-plane благодаря toleration `node-role.kubernetes.io/control-plane:NoSchedule` |
| Alloy resources | requests `100m` CPU / `128Mi`; limits `500m` CPU / `512Mi` |
| Alloy Service | выключен (`service.enabled: false`) |

Явные `securityContext`, `nodeSelector`, affinity и host mounts в финальных values
не заданы. Alloy читает логи через Kubernetes API; `/var/log` и Docker socket не
монтируются. Alloy создаёт ServiceAccount, RBAC и ClusterRoleBinding.

## Сбор логов Alloy

Конфигурация в `helm/alloy/values-final-work.yaml`:

1. `discovery.kubernetes "pods"` обнаруживает pod targets.
2. `discovery.relabel "pods"` оставляет только targets, у которых
   `__meta_kubernetes_pod_node_name` совпадает с `K8S_NODE_NAME`.
3. `K8S_NODE_NAME` берётся из `spec.nodeName` через Downward API. Поэтому каждый
   DaemonSet собирает только логи своего узла, а не дублирует соседние.
4. В labels переносятся `namespace`, `pod`, `container`, `node_name`, `app`,
   `app_kubernetes_io_name`; `job` строится как `namespace/app`.
5. `loki.source.kubernetes` читает pod logs через API, `loki.process` добавляет
   `collector="alloy"` и `cluster="final-work-k8s"`, затем `loki.write` отправляет
   их в Loki.

Основные RBAC-разрешения: `get/list/watch` для `pods`, `pods/log`, `namespaces`,
`services`, `endpoints`, `endpointslices` и для `nodes`. Лишние labels повышают
кардинальность Loki. Не добавляйте уникальные значения вроде request ID, URL с
UUID или полного текста сообщения в labels; такие данные должны оставаться в
содержимом лога.

## Datasource Grafana

Release `loki-datasource` создаёт ConfigMap `loki-datasource` с label
`grafana_datasource: "1"`. В нём datasource имеет имя `Loki`, UID `loki`, тип
`loki`, `access: proxy` и URL
`http://loki.monitoring.svc.cluster.local:3100`.

В values `kube-prometheus-stack` включён Grafana datasource sidecar: он ищет
ConfigMap в namespace `monitoring`, resource `configmap`, и импортирует ConfigMap
с label `grafana_datasource`. Ручное добавление datasource в UI не требуется.

## Файлы и порядок установки

- `helm/loki/Chart.yaml`, `helm/loki/values-final-work.yaml` — Loki.
- `helm/alloy/Chart.yaml`, `helm/alloy/values-final-work.yaml` — Alloy и pipeline.
- `helm/loki-datasource/Chart.yaml`, `templates/datasource.yaml` — datasource.
- `helm/kube-prometheus-stack/values.yaml` — Grafana sidecar.
- `install.sh` — общий порядок bootstrap и Helm-команды.
- `docs/task-3-monitoring.md` — связанная документация метрик и Grafana.
- `README.md` — краткая ссылка и общий bootstrap.

В секции `monitoring` скрипт устанавливает сначала `kube-prometheus-stack`, затем
`loki`, `loki-datasource`, и затем `alloy`. Для полного bootstrap запускается
`./install.sh` из корня репозитория после подготовки секретов и инфраструктуры.

## Prerequisites, backup и schema

Нужны рабочие `kubectl`, Helm, выбранный kubeconfig/context, работающие hcloud
CCM/CSI и StorageClass `hcloud-volumes`; секрет Grafana должен существовать до
полного запуска. Проверки из корня:

```bash
kubectl config current-context
kubectl get nodes
kubectl get storageclass hcloud-volumes
kubectl -n monitoring get secret grafana-admin-credentials
```

Перед первым upgrade сделайте backup существующего Loki volume/PVC
`storage-loki-0`. Никогда не удаляйте существующий Loki PVC: в values
`enableStatefulSetAutoDeletePVC` выключен, но ручное удаление всё равно уничтожит
данные. Сохраняйте текущую схему `boltdb-shipper`/v12 и дату `2024-01-01`, чтобы
старые записи оставались читаемыми. `allow_structured_metadata: false` оставлен
до планируемой миграции на v13/TSDB; новую схему можно вводить только с будущей
датой и отдельным планом миграции, а не заменой текущего конфига задним числом.

## Deploy и upgrade

Из корня `/workspace/final_proj/cluster_infra`:

```bash
helm upgrade --install kube-prometheus-stack ./helm/kube-prometheus-stack --version 91.4.1 -n monitoring --create-namespace -f ./helm/kube-prometheus-stack/values.yaml --wait --timeout 15m
helm upgrade --install loki ./helm/loki -n monitoring -f ./helm/loki/values-final-work.yaml --wait --timeout 10m
helm upgrade --install loki-datasource ./helm/loki-datasource -n monitoring --wait --timeout 10m
helm upgrade --install alloy ./helm/alloy -n monitoring -f ./helm/alloy/values-final-work.yaml --wait --timeout 10m
```

Для полного развёртывания, а не только logging stack, используйте:

```bash
./install.sh
```

Скрипт сам переходит в каталог репозитория, но требует `.sensitive_data`, hcloud
инструменты и все prerequisites из `README.md`. Не запускайте deploy для проверки
этой документации.

## Проверка

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

Для проверки ingestion после генерации трафика используйте Loki API через
port-forward:

```bash
curl -sG http://127.0.0.1:3100/loki/api/v1/query_range \
  --data-urlencode 'query={collector="alloy"}' \
  --data-urlencode 'limit=20'
```

Ожидайте `Ready` от `/ready`, Alloy pods на узлах, Bound PVC и непустой `result`
у `query_range`.

## Grafana Explore и LogQL

Откройте Grafana, выберите datasource `Loki`, поставьте time range **Last 15
minutes** и выполните:

```logql
{pod=~"frontend-.*"}
{pod=~"checkoutservice-.*"}
{pod=~"loadgenerator-.*"}
{collector="alloy"}
{container="istio-proxy"}
```

Последний запрос показывает sidecar Istio. Для общего сравнения нескольких
микросервисов используйте `{pod=~"(frontend|checkoutservice|loadgenerator)-.*"}`.

## Troubleshooting

- **`unsupported compactor.delete_request_store`**: это признак старого Loki или
  старого итогового конфига. Текущая пара chart `18.7.6`/Loki `3.7.6` содержит
  `loki.compactor.delete_request_store: filesystem`; проверьте, что upgrade не
  запускается с устаревшим values-файлом или другим образом Loki. Не удаляйте
  поле из текущих values вслепую и не смешивайте версии.
- **`unknown field replicas`**: не задавайте общий `loki.replicas`. В текущем
  chart число задаётся `singleBinary.replicas`, а `read`, `write`, `backend` равны
  нулю. Удалите stale key и повторите render/upgrade теми же values.
- **Нет логов**: проверьте Alloy DaemonSet, его logs и RBAC; сравните
  `spec.nodeName` pod с `K8S_NODE_NAME`. Затем проверьте DNS/порт Loki и запрос
  `{collector="alloy"}`. Для Kubernetes API не нужны host mounts.
- **Дублирование**: оставьте один Alloy DaemonSet и убедитесь, что фильтр
  `K8S_NODE_NAME` не удалён. Не включайте параллельно file-based collector или
  вторую установку Alloy без явного разделения targets.
- **PVC Pending**: проверьте `kubectl get storageclass hcloud-volumes`, hcloud
  CSI и события `kubectl -n monitoring describe pvc storage-loki-0`. Не удаляйте
  PVC для исправления Pending.
- **Datasource отсутствует**: проверьте ConfigMap и label
  `grafana_datasource=1`, namespace `monitoring`, контейнер Grafana
  `datasource-sc-datasources` и его logs. Убедитесь, что release
  `loki-datasource` установлен после Grafana chart; URL должен указывать на
  `loki.monitoring.svc.cluster.local:3100`.

## Uninstall и данные

Для удаления только Helm-релизов:

```bash
helm uninstall alloy -n monitoring
helm uninstall loki-datasource -n monitoring
helm uninstall loki -n monitoring
```

Это не является инструкцией удаления данных. PVC и содержимое Loki нужно
сохранять отдельно; перед удалением release сначала подтвердите backup и
необходимость удаления persistent data. Для общего удаления мониторинга также
учтите release `kube-prometheus-stack` и его PVC. В этой документации намеренно
нет команды удаления PVC.

## Acceptance checklist Task 4

- [ ] Loki chart `18.7.6` / app `3.7.6` и Alloy chart `1.12.1` / app `v1.19.2` подтверждены.
- [ ] Один Loki pod Ready, PVC `storage-loki-0` Bound, StorageClass `hcloud-volumes`.
- [ ] Alloy DaemonSet Ready на worker и control-plane узлах, без RBAC ошибок.
- [ ] `/ready` Loki возвращает успешный ответ.
- [ ] ConfigMap `loki-datasource` найден Grafana sidecar, datasource `Loki` виден в Explore.
- [ ] За последние 15 минут найдены логи минимум двух-трёх сервисов: `frontend`, `checkoutservice`, `loadgenerator`.
- [ ] Отдельно проверен запрос `{container="istio-proxy"}` или явно зафиксировано отсутствие Istio sidecar у выбранного pod.
- [ ] Проверен `{collector="alloy"}` и исключено дублирование записей.
