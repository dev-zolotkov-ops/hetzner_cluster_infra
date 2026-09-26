# Инфраструктура кластера

Репозиторий предназначен для развёртывания HA Kubernetes-кластера в Hetzner с помощью Terraform, Ansible и Helm. Это не проект для разработки приложений: здесь описаны инфраструктура, сетевой вход, хранилища, мониторинг, логирование и CI/CD.

## Назначение и архитектура

Terraform создаёт `hcloud_server` для `masters`, `workers`, `ingress` и `haproxy`, сеть `k8s-network` с четырьмя subnet, маршрут по умолчанию через HAProxy, firewall `k8s-nodes` и `k8s-haproxy`, а также `terraform_data` для inventory и переменных Ansible. Terraform не создаёт Hetzner LoadBalancer. LoadBalancer появляется позже через HCCM, когда Kubernetes Service получает тип `LoadBalancer`. Ansible подготавливает хосты и устанавливает Kubernetes через роли `ansible/roles/preparing_hosts` и `ansible/roles/cluster`, вызываемые из `ansible/k8s-install.yml`.

В кластере используются:

- Hetzner Cloud Controller Manager (`hccm`) для cloud-интеграции и LoadBalancer.
- Hetzner CSI (`hcloud-csi`) и StorageClass `hcloud-volumes` для PVC.
- Istio control plane и `istio-ingressgateway`.
- `external-dns` с Cloudflare и cert-manager с production Let's Encrypt DNS-01.
- `postfinance/kubelet-csr-approver` для безопасного одобрения `kubernetes.io/kubelet-serving` CSR и ротации serving-сертификатов.
- `kube-prometheus-stack` для Prometheus, Grafana, Alertmanager, node-exporter и kube-state-metrics.
- Loki в режиме `Monolithic` и Alloy DaemonSet для логов контейнеров.
- GitLab Runner releases `build-runner`, `deploy-runner` и `test-runner`.
- Tempo в режиме `Monolithic` и Alloy OTLP pipeline для дополнительного tracing.
- Metrics Server для `metrics.k8s.io` и Kubernetes Autoscaler VPA для рекомендаций CPU/памяти и admission webhook.

Публичный origin работает только через Cloudflare: для публичных VirtualService требуется `cloudflare-proxied: true`, а `ingress/cloudflare-origin-policy.yml` запрещает прямой трафик не из Cloudflare CIDR. Hetzner LoadBalancer и Istio ingress gateway используют PROXY protocol, чтобы Istio видел исходный IP клиента. Cloudflare IPv4/IPv6 CIDR нужно периодически сверять с официальными списками.

Общий Gateway и Certificate находятся в `ingress/gateway_cert.yml`; Telemetry для HTTP-метрик Istio находится в `ingress/ingress-telemetry.yml`. Публичные адреса: `https://final-work-k8s.raisa44.men` и `https://grafana.raisa44.men`.

## Что нужно локально

Нужны Terraform с lockfile провайдера Hetzner, Ansible, `kubectl`, Helm, `jq`, `curl`, `dig`, `hcloud`, Python 3 с PyYAML и `istioctl` версии **1.30.4**. Перед Helm-командами настройте kubeconfig и выберите целевой context. Helm charts и зависимости уже находятся в репозитории; `helm repo update` для `install.sh` не нужен. PyYAML нужен recovery-скрипту для чтения vendored Helm values.

Нужны следующие секреты и условия:

- `HCLOUD_TOKEN` для Terraform.
- Secret `hcloud` в `kube-system` с ключом `token`; `install.sh` дополнительно записывает в него id сети `k8s-network`.
- Secret `grafana-admin-credentials` в `monitoring` с ключами `admin-user` и `admin-password`.
- Secret `cloudflare-external-dns` в `ingress` с ключом `api-token`.
- Secret `cloudflare-cert-manager` в `ingress` с ключом `api-token`.
- Файл `../../../../.sensitive_data/ns_secrets_roles.yml` и скрипт `../../../../.sensitive_data/opencode_kubeconfig.sh`, которые используются текущим `install.sh`; этот путь вычисляется относительно корня репозитория, а значения секретов в репозиторий не добавляются.

Проверка перед развёртыванием:

```bash
terraform version
ansible --version
kubectl version --client
helm version --short
istioctl version --remote=false
kubectl config current-context
kubectl cluster-info
kubectl get nodes
kubectl get storageclass
kubectl -n kube-system get secret hcloud
kubectl -n monitoring get secret grafana-admin-credentials
kubectl -n ingress get secret cloudflare-external-dns cloudflare-cert-manager
```

## Порядок развёртывания

1. Создайте инфраструктуру из `terraform/`:

```bash
cd terraform
export HCLOUD_TOKEN="<your_token>"
terraform plan
terraform apply
```

2. Подготовьте хосты и установите кластер из `ansible/`:

```bash
cd ../ansible
ansible-playbook k8s-install.yml -t preparing_hosts
ansible-playbook k8s-install.yml -t cluster
```

3. Из корня репозитория создайте prerequisites и запустите полный bootstrap:

```bash
./install.sh
```

Скрипт применяет внешний файл `ns_secrets_roles.yml`, устанавливает HCCM и CSI, проверяет только major/minor `istioctl` на соответствие `1.30`, устанавливает Istio, ExternalDNS и cert-manager, применяет `ingress/gateway_cert.yml`, `ingress/ingress-telemetry.yml` и `ingress/cloudflare-origin-policy.yml`, затем устанавливает kube-prometheus-stack, Metrics Server, VPA, остальной monitoring stack и три GitLab Runner. В локальных prerequisites указан target `istioctl 1.30.4`: он совместим с проверкой `1.30`, поскольку patch-версия скриптом не фиксируется. Отдельный ACME email в текущей команде не задаётся.

## Ingress, DNS и сертификаты

ExternalDNS публикует DNS через Cloudflare. cert-manager получает production-сертификат Let's Encrypt через DNS-01 с Secret `cloudflare-cert-manager`. Gateway обслуживает оба публичных имени, сертификат имеет Secret `final-work-k8s-tls`, HTTP перенаправляется на HTTPS. Grafana VirtualService создаётся values `helm/kube-prometheus-stack/values.yaml`; второй Gateway, Certificate или Grafana VirtualService создавать не нужно.

Проверка origin-политики и PROXY protocol:

```bash
kubectl -n istio-system get authorizationpolicy cloudflare-origin-only
kubectl -n istio-system get service istio-ingressgateway -o yaml
kubectl -n istio-system rollout status deployment/istio-ingressgateway --timeout=5m
curl -I https://final-work-k8s.raisa44.men/
curl -k -I --resolve final-work-k8s.raisa44.men:443:<LB_IP> https://final-work-k8s.raisa44.men/
```

Запрос через hostname должен идти через Cloudflare, а прямой `curl --resolve` к LoadBalancer должен вернуть `403`. Внутренний scrape Prometheus на `15090` разрешён; этот порт не публикуется LoadBalancer и не открывает трафик приложения.

## Хранилища

HCCM должен работать до создания LoadBalancer Service, а CSI должен создать StorageClass `hcloud-volumes`. Актуальные размеры monitoring PVC и replica count задаются vendored Helm values и проверяются recovery-скриптом, а не дублируются в этом тексте. Loki использует один pod, filesystem и retention `168h`; его PVC `storage-loki-0` нельзя удалять. Конфигурация Loki намеренно сохраняет schema `boltdb-shipper` v12 с датой `2024-01-01`. Подробности upgrade и backup находятся в [`docs/task-4-logging.md`](docs/task-4-logging.md).

Мониторинговые PVC защищены от Terraform destroy: StorageClass использует
`Retain`, а `install.sh` требует authoritative `hcloud volume list`, до
monitoring Helm releases запускает fail-closed восстановление проверенных
Hetzner volumes, а после monitoring проверяет все пять PVC и регистрирует
только выбранные volumes короткими durable labels. Пять исторических IDs и
точные claims находятся в `storage/monitoring-volume-registry.json`.
Подробности pre-install recovery, static CSI PV и dynamic first bootstrap находятся в
[`docs/monitoring-storage-recovery.md`](docs/monitoring-storage-recovery.md).

## Task 3: мониторинг

`kube-prometheus-stack` устанавливается из `helm/kube-prometheus-stack/values.yaml` версией chart `91.4.1`. Включены kubelet/cAdvisor, node-exporter, kube-state-metrics и собственные dashboard `Kubernetes / Pod Resources`, `Kubernetes / Cluster Overview`, `Istio / Ingress HTTP`. Kubelet и cAdvisor скрапятся по HTTPS на `10250`; probe metrics отключены. Prometheus и Grafana размещаются на worker nodes, kube-state-metrics и admission jobs на control-plane.

Подробные назначение метрик, панели, проверки, артефакты, troubleshooting и бонус Istio ingress HTTP: [`docs/task-3-monitoring.md`](docs/task-3-monitoring.md).

## Task 4: логирование

`helm/loki/values-final-work.yaml` устанавливает Loki, `helm/alloy/values-final-work.yaml` устанавливает Alloy DaemonSet на узлах, а `helm/loki-datasource` создаёт datasource `Loki` для Grafana. Loki доступен только внутри кластера; поток логов: pod -> Alloy -> Loki -> Grafana Explore.

Подробные параметры, порядок upgrade, backup, LogQL, troubleshooting и acceptance checklist: [`docs/task-4-logging.md`](docs/task-4-logging.md).

## Task 5: autoscaling

Metrics Server `3.14.0` / app `0.9.0` публикует защищённый ресурсный API `metrics.k8s.io`; затем VPA chart `0.9.0` / app `1.7.0` устанавливает CRD, recommender, updater и admission controller/webhook. Оба официальных chart полностью vendored в `helm/metrics-server` и `helm/vertical-pod-autoscaler`. Компоненты toleration-ами работают на трёх tainted control-plane, не занимая единственный worker. Подробности HPA/VPA, upgrade и проверки: [`docs/task-5-autoscaling.md`](docs/task-5-autoscaling.md).

Дополнительный tracing подготовлен через Tempo chart `3.0.0` / app `3.0.3`,
Tempo datasource UID `tempo` и OTLP-порты Alloy `4317`/`4318`; существующий
log flow не изменяется. Источник spans — instrumented сервисы Online Boutique
`v0.10.0`, отправляющие OTLP через Alloy в Tempo. До redeploy boutique с tracing
environment variables live spans не ожидаются; подробности и проверка находятся
в [`docs/task-4-logging.md`](docs/task-4-logging.md).

## Проверка кластера

```bash
kubectl -n kube-system get deployment kubelet-csr-approver
kubectl get csr -o wide
kubectl -n kube-system logs deployment/kubelet-csr-approver
kubectl get nodes -o wide
helm -n monitoring status kube-prometheus-stack
kubectl -n monitoring get pods,ds,svc,pvc
kubectl get certificate -A
dig grafana.raisa44.men
```

Для быстрого проверки Task 3 используйте команды и PromQL из [`docs/task-3-monitoring.md`](docs/task-3-monitoring.md); для проверки Loki и Alloy используйте [`docs/task-4-logging.md`](docs/task-4-logging.md). Не включайте секреты в вывод, скриншоты и артефакты.
