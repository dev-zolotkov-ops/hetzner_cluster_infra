#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

required_istio_version="1.30.4"
istioctl_version="$(istioctl version --remote=false 2>/dev/null || istioctl version 2>/dev/null)"
if [[ "$istioctl_version" != *"${required_istio_version}"* ]]; then
  printf 'istioctl %s is required (detected: %s)\n' "$required_istio_version" "$istioctl_version" >&2
  exit 1
fi

# Istio control plane and ingress gateway
istioctl install -f ./istio/istio-operator.yaml -y
# Cloud controllers
helm upgrade --install -n kube-system hcloud-csi ./hcloud-csi -f ./hcloud-csi/values.yaml --wait --timeout 10m
helm upgrade --install -n kube-system hccm ./hcloud-cloud-controller-manager -f ./hcloud-cloud-controller-manager/values.yaml --wait --timeout 10m
# DNS + certs
helm upgrade --install external-dns ./external-dns -n ingress --create-namespace -f ./external-dns/values.yaml --wait --timeout 10m
helm upgrade --install cert-manager ./cert-manager -n ingress --create-namespace -f ./cert-manager/values.yaml --wait --timeout 10m
# monitoring
helm upgrade --install kube-prometheus-stack ./kube-prometheus-stack --version 91.4.1 -n monitoring --create-namespace -f ./kube-prometheus-stack/values.yaml --wait --timeout 15m
# CI/CD
helm upgrade --install gitlab-runner ./gitlab-runner -n gitlab-runner --create-namespace -f ./gitlab-runner/values.yaml --wait --timeout 10m
# Test
kubectl get po -A | grep -E "gitlab|hcloud|hccm|external-dns|cert-manager|istio|prometheus|grafana"
