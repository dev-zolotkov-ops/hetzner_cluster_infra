# Task 5: Autoscaling

## Цель и область

Task 5 добавляет инфраструктуру для HPA и VPA в Kubernetes 1.35.x. Metrics Server нужен для CPU-метрик HPA и источника наблюдений VPA. HPA применяется к frontend по CPU с target `50%`. VPA применяется только к memory контейнера `server` frontend, с `updateMode: Recreate`, `controlledValues: RequestsAndLimits`, request `64..128Mi` и пропорциональным limit до `256Mi`. Конфликт возникает, если HPA и VPA одновременно управляют одним CPU metric/request; VPA не управляет replicas. Конкретные VPA resources создаются app chart через `boutique-deploy` и здесь намеренно не добавляются.

## Версии и размещение

| Компонент | Chart | App | Источник |
|---|---:|---:|---|
| Metrics Server | `3.14.0` | `0.9.0` | official `kubernetes-sigs/metrics-server` Helm release |
| VPA | `0.9.0` | `1.7.0` | official `kubernetes/autoscaler` chart/source |

Чарты полностью vendored: `helm/metrics-server` и `helm/vertical-pod-autoscaler`. Values находятся в `values-final-work.yaml`. Metrics Server использует `InternalIP` и kubelet serving certificates; `--kubelet-insecure-tls` не используется. APIService получает CA от Helm-generated serving certificate (`tls.type: helm`).

Три control-plane имеют taint `node-role.kubernetes.io/control-plane:NoSchedule`. Metrics Server и все VPA controllers toleration-ами размещаются там; worker остаётся под capacity Online Boutique. В VPA включены recommender, updater, admission controller, CRD и Helm-managed TLS webhook.

## Prerequisites

- Kubernetes 1.35.x, kubeconfig с правами cluster-admin, Helm и kubectl.
- Исправные kubelet serving certificates на всех узлах, включая три control-plane и `worker-0`, с доступным `InternalIP`.
- Рабочие CNI/API server и право создать namespace `monitoring`.
- Metrics Server и VPA не должны быть установлены вторым release или raw manifests.
- Для HPA у frontend должны быть CPU requests; VPA не должен управлять CPU request, который используется HPA.

## Установка только Task 5

Из `/workspace/final_proj/cluster_infra` выполните только эти upgrades:

```bash
helm upgrade --install metrics-server ./helm/metrics-server -n monitoring --create-namespace -f ./helm/metrics-server/values-final-work.yaml --wait --timeout 10m
kubectl wait --for=condition=Available deployment/metrics-server -n monitoring --timeout=5m
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Available")].status}'=True apiservice/v1beta1.metrics.k8s.io --timeout=5m
helm upgrade --install vertical-pod-autoscaler ./helm/vertical-pod-autoscaler -n monitoring -f ./helm/vertical-pod-autoscaler/values-final-work.yaml --wait --timeout 10m
kubectl wait --for=condition=Established crd/verticalpodautoscalers.autoscaling.k8s.io --timeout=5m
kubectl get --raw /apis/metrics.k8s.io/v1beta1
```

Полный `./install.sh` также устанавливает эти releases, но дополнительно перезапускает весь infrastructure bootstrap и не является командой только Task 5.

## Проверка

```bash
kubectl -n monitoring get deploy,pods,svc -o wide
kubectl get apiservice v1beta1.metrics.k8s.io
kubectl get crd verticalpodautoscalers.autoscaling.k8s.io
kubectl get --raw /apis/metrics.k8s.io/v1beta1 | jq .
kubectl top nodes
kubectl top pods -A
kubectl get mutatingwebhookconfiguration
kubectl -n monitoring logs deploy/metrics-server --tail=100
kubectl describe apiservice v1beta1.metrics.k8s.io
```

Не вызывайте `kubectl top` единственным readiness check сразу после install: сначала ждите Deployment и APIService, затем повторяйте raw API/top.

## Load test и capacity

После установки infrastructure `boutique-deploy` из GitLab разворачивает Online Boutique и app chart вместе создаёт HPA frontend с target CPU `50%` и VPA memory-only policy для контейнера `server` с `updateMode: Recreate`. Отдельно создавать HPA или VPA не нужно. Проверьте `kubectl -n online-boutique get hpa` и `kubectl -n online-boutique describe hpa`. Нагрузку можно сгенерировать штатным `loadgenerator` boutique или согласованным тестовым запросом к frontend; наблюдайте `kubectl top pods` и `kubectl -n online-boutique get hpa`. VPA recommendations проверяйте:

```bash
kubectl -n online-boutique get vpa -o yaml
kubectl -n online-boutique describe vpa
kubectl top pods -n online-boutique
```

У кластера один worker. HPA и VPA создаются вместе app chart через GitLab `boutique-deploy`; отдельные ручные create-команды для них не нужны. Если HPA увеличит replicas сверх capacity `worker-0`, pod может быть `Pending`; это ожидаемый сигнал нехватки capacity, а не причина снимать taints или отключать requests. Проверяйте `kubectl -n online-boutique get pods -o wide` и `kubectl describe pod`.

## Rollback

```bash
helm history metrics-server -n monitoring
helm rollback metrics-server <REVISION> -n monitoring --wait --timeout 10m
helm history vertical-pod-autoscaler -n monitoring
helm rollback vertical-pod-autoscaler <REVISION> -n monitoring --wait --timeout 10m
```

Не удаляйте VPA CRD без отдельного решения: это удалит VPA objects. При полном uninstall сначала отключите HPA/VPA objects в app namespace и сохраните диагностику.

## GitLab dependency

GitLab `boutique-deploy` запускается только после успешной установки infrastructure: Metrics Server API и VPA webhook должны быть Ready до deployment frontend. Infrastructure pipeline не деплоит frontend и не создаёт app HPA/VPA objects; app repo отвечает за их manifests и workload policy.
