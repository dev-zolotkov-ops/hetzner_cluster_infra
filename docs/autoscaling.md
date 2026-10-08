# Autoscaling

## Purpose and Scope

This document adds infrastructure for HPA and VPA in Kubernetes 1.35.x. Metrics Server is required for HPA CPU metrics and as a VPA observation source. HPA applies to frontend CPU with target `50%`. VPA applies only to the frontend `server` container memory, with `updateMode: Recreate`, `controlledValues: RequestsAndLimits`, request `64..128Mi`, and a proportional limit up to `256Mi`. A conflict occurs if HPA and VPA both control the same CPU metric/request; VPA does not control replicas. Specific VPA resources are created by the app chart through `boutique-deploy` and are intentionally not added here.

## Versions and Placement

| Component | Chart | App | Source |
|---|---:|---:|---|
| Metrics Server | `3.14.0` | `0.9.0` | official `kubernetes-sigs/metrics-server` Helm release |
| VPA | `0.9.0` | `1.7.0` | official `kubernetes/autoscaler` chart/source |

The charts are fully vendored: `helm/metrics-server` and `helm/vertical-pod-autoscaler`. Values are in `values-final-work.yaml`. Metrics Server uses `InternalIP` and kubelet serving certificates; `--kubelet-insecure-tls` is not used. The APIService gets its CA from the Helm-generated serving certificate (`tls.type: helm`).

The three control-plane nodes have taint `node-role.kubernetes.io/control-plane:NoSchedule`. Metrics Server and all VPA controllers are placed there through tolerations; the worker remains available for Online Boutique capacity. VPA enables the recommender, updater, admission controller, CRD, and Helm-managed TLS webhook.

## Prerequisites

- Kubernetes 1.35.x, a kubeconfig with cluster-admin permissions, Helm, and kubectl.
- Working kubelet serving certificates on all nodes, including the three control-plane nodes and `worker-0`, with an accessible `InternalIP`.
- A working CNI/API server and permission to create the `monitoring` namespace.
- Metrics Server and VPA must not be installed through a second release or raw manifests.
- Frontend must have CPU requests for HPA; VPA must not manage the CPU request used by HPA.

## Install Autoscaling Only

From `/workspace/final_proj/cluster_infra`, run only these upgrades:

```bash
helm upgrade --install metrics-server ./helm/metrics-server -n monitoring --create-namespace -f ./helm/metrics-server/values-final-work.yaml --wait --timeout 10m
kubectl wait --for=condition=Available deployment/metrics-server -n monitoring --timeout=5m
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Available")].status}'=True apiservice/v1beta1.metrics.k8s.io --timeout=5m
helm upgrade --install vertical-pod-autoscaler ./helm/vertical-pod-autoscaler -n monitoring -f ./helm/vertical-pod-autoscaler/values-final-work.yaml --wait --timeout 10m
kubectl wait --for=condition=Established crd/verticalpodautoscalers.autoscaling.k8s.io --timeout=5m
kubectl get --raw /apis/metrics.k8s.io/v1beta1
```

The full `./install.sh` also installs these releases, but additionally reruns the entire infrastructure bootstrap and is not an autoscaling-only command.

## Verification

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

Do not use `kubectl top` as the only readiness check immediately after installation: wait for the Deployment and APIService first, then repeat the raw API/top checks.

## Load Test and Capacity

After infrastructure installation, GitLab `boutique-deploy` deploys Online Boutique, and the app chart creates an HPA for frontend with CPU target `50%` and a memory-only VPA policy for the `server` container with `updateMode: Recreate`. Do not create HPA or VPA separately. Check `kubectl -n online-boutique get hpa` and `kubectl -n online-boutique describe hpa`. Generate load with the boutique `loadgenerator` or an agreed test request to frontend; observe `kubectl top pods` and `kubectl -n online-boutique get hpa`. Check VPA recommendations:

```bash
kubectl -n online-boutique get vpa -o yaml
kubectl -n online-boutique describe vpa
kubectl top pods -n online-boutique
```

The cluster has one worker. HPA and VPA are created by the app chart through GitLab `boutique-deploy`; no separate manual create commands are needed. If HPA increases replicas beyond `worker-0` capacity, a pod may remain `Pending`; this is an expected capacity signal, not a reason to remove taints or disable requests. Check `kubectl -n online-boutique get pods -o wide` and `kubectl describe pod`.

## Rollback

```bash
helm history metrics-server -n monitoring
helm rollback metrics-server <REVISION> -n monitoring --wait --timeout 10m
helm history vertical-pod-autoscaler -n monitoring
helm rollback vertical-pod-autoscaler <REVISION> -n monitoring --wait --timeout 10m
```

Do not delete the VPA CRD without a separate decision: this deletes VPA objects. For a full uninstall, first disable HPA/VPA objects in the app namespace and preserve diagnostics.

## GitLab Dependency

GitLab `boutique-deploy` runs only after the infrastructure installation succeeds: the Metrics Server API and VPA webhook must be Ready before the frontend is deployed. The infrastructure pipeline does not deploy frontend or create app HPA/VPA objects; the app repository is responsible for their manifests and workload policy.
