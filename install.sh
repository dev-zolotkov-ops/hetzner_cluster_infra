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

 kubectl apply -f ${MANEFESTS_DIR}/gateway_cert.yml


# monitoring
helm upgrade --install kube-prometheus-stack ${HELM_DIR}/kube-prometheus-stack --version 91.4.1 -n monitoring --create-namespace -f ${HELM_DIR}/kube-prometheus-stack/values.yaml --wait --timeout 15m

# CI/CD
helm upgrade --install build-runner ${HELM_DIR}/gitlab-runner -n gitlab-runner --create-namespace -f ${HELM_DIR}/gitlab-runner/values.yaml
helm upgrade --install deploy-runner ${HELM_DIR}/gitlab-runner -n gitlab-runner -f ${HELM_DIR}/gitlab-runner/values.yaml -f ${HELM_DIR}/gitlab-runner/deploy-values.yaml
helm upgrade --install test-runner ${HELM_DIR}/gitlab-runner/ -n gitlab-runner -f ${HELM_DIR}/gitlab-runner/values.yaml -f ${HELM_DIR}/gitlab-runner/test-values.yaml

# Test
kubectl get po -A | grep -E "gitlab|hcloud|hccm|external-dns|cert-manager|istio|prometheus|grafana"

${MANEFESTS_DIR}/opencode_kubeconfig.sh