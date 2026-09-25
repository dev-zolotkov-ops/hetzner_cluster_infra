#!/bin/bash
set -euo pipefail

MANEFESTS_DIR=../../../../.sensitive_data
HELM_DIR=./helm

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

kubectl apply -f ${MANEFESTS_DIR}/ns_secrets_roles.yml

kubectl patch secret hcloud -n kube-system \
  --type='merge' \
  -p "{\"data\":{\"network\":\"$(hcloud network list -o json | \
  jq -r '.[] | select(.name=="k8s-network") | .id' | \
  tr -d '\r\n' | base64 -w0)\"}}"

# HCCM
helm upgrade --install -n kube-system hccm ${HELM_DIR}/hcloud-cloud-controller-manager -f ${HELM_DIR}/hcloud-cloud-controller-manager/values.yaml --wait --timeout 10m

# CSI
helm upgrade --install -n kube-system hcloud-csi ${HELM_DIR}/hcloud-csi -f ${HELM_DIR}/hcloud-csi/values.yaml --wait --timeout 10m

# Istio control plane and ingress gateway
required_istio_version="1.30"
istioctl_version="$(istioctl version --remote=false 2>/dev/null || istioctl version 2>/dev/null)"
if [[ ! "$istioctl_version" =~ (^|[^0-9])v?([0-9]+)\.([0-9]+)(\.[0-9]+)?([^0-9]|$) ]] || [[ "${BASH_REMATCH[2]}.${BASH_REMATCH[3]}" != "$required_istio_version" ]]; then
  printf 'istioctl %s is required (detected: %s)\n' "$required_istio_version" "$istioctl_version" >&2
  exit 1
fi

istioctl install -f ${HELM_DIR}/istio/istio-operator.yaml -y

# DNS + certs. The issuer is enabled in a second Helm upgrade because the
# ClusterIssuer CRD must exist before that custom resource can be submitted.
helm upgrade --install external-dns ${HELM_DIR}/external-dns -n ingress --create-namespace -f ${HELM_DIR}/external-dns/values.yaml --wait --timeout 10m
helm upgrade --install cert-manager ${HELM_DIR}/cert-manager -n ingress --create-namespace -f ${HELM_DIR}/cert-manager/values.yaml --set crds.enabled=true --wait --timeout 10m
# : "${ACME_EMAIL:?Set ACME_EMAIL to the ACME account email before deploying}"
helm upgrade cert-manager ${HELM_DIR}/cert-manager -n ingress -f ${HELM_DIR}/cert-manager/values.yaml --set crds.enabled=true --set acme.enabled=true --wait --timeout 10m

kubectl apply -f ${SCRIPT_DIR}/ingress/gateway_cert.yml \
  -f ${SCRIPT_DIR}/ingress/ingress-telemetry.yml

kubectl -n istio-system rollout status deployment/istio-ingressgateway --timeout=5m
kubectl apply -f ${SCRIPT_DIR}/ingress/cloudflare-origin-policy.yml


# monitoring
helm upgrade --install kube-prometheus-stack ${HELM_DIR}/kube-prometheus-stack --version 91.4.1 -n monitoring --create-namespace -f ${HELM_DIR}/kube-prometheus-stack/values.yaml --wait --timeout 15m
helm upgrade --install metrics-server ${HELM_DIR}/metrics-server -n monitoring -f ${HELM_DIR}/metrics-server/values-final-work.yaml --wait --timeout 10m
kubectl wait --for=condition=Available deployment/metrics-server -n monitoring --timeout=5m
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Available")].status}'=True apiservice/v1beta1.metrics.k8s.io --timeout=5m
helm upgrade --install vertical-pod-autoscaler ${HELM_DIR}/vertical-pod-autoscaler -n monitoring -f ${HELM_DIR}/vertical-pod-autoscaler/values-final-work.yaml --wait --timeout 10m
kubectl wait --for=condition=Established crd/verticalpodautoscalers.autoscaling.k8s.io --timeout=5m
kubectl wait --for=condition=Available deployment/vertical-pod-autoscaler-admission-controller -n monitoring --timeout=5m
kubectl wait --for=condition=Available deployment/vertical-pod-autoscaler-recommender -n monitoring --timeout=5m
kubectl wait --for=condition=Available deployment/vertical-pod-autoscaler-updater -n monitoring --timeout=5m
kubectl get --raw /apis/metrics.k8s.io/v1beta1 >/dev/null
helm upgrade --install loki ${HELM_DIR}/loki -n monitoring -f ${HELM_DIR}/loki/values-final-work.yaml --wait --timeout 10m
helm upgrade --install tempo ${HELM_DIR}/tempo -n monitoring -f ${HELM_DIR}/tempo/values-final-work.yaml --wait --timeout 10m
helm upgrade --install loki-datasource ${HELM_DIR}/loki-datasource -n monitoring --wait --timeout 10m
helm upgrade --install tempo-datasource ${HELM_DIR}/tempo-datasource -n monitoring --wait --timeout 10m
helm upgrade --install alloy ${HELM_DIR}/alloy -n monitoring -f ${HELM_DIR}/alloy/values-final-work.yaml --wait --timeout 10m

# CI/CD
helm upgrade --install build-runner ${HELM_DIR}/gitlab-runner -n gitlab-runner --create-namespace -f ${HELM_DIR}/gitlab-runner/values.yaml
helm upgrade --install deploy-runner ${HELM_DIR}/gitlab-runner -n gitlab-runner -f ${HELM_DIR}/gitlab-runner/values.yaml -f ${HELM_DIR}/gitlab-runner/deploy-values.yaml
helm upgrade --install test-runner ${HELM_DIR}/gitlab-runner/ -n gitlab-runner -f ${HELM_DIR}/gitlab-runner/values.yaml -f ${HELM_DIR}/gitlab-runner/test-values.yaml

# Test
kubectl get po -A | grep -E "gitlab|hcloud|hccm|external-dns|cert-manager|istio|prometheus|grafana"

${MANEFESTS_DIR}/opencode_kubeconfig.sh
