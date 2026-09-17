#!/bin/bash
set -euo pipefail

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
