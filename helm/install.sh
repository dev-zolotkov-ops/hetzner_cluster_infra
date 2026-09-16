#!/bin/bash
set -euo pipefail

helm upgrade --install -n kube-system hcloud-csi ./hcloud-csi -f ./hcloud-csi/values.yaml 
helm upgrade --install -n kube-system hccm ./hcloud-cloud-controller-manager -f ./hcloud-cloud-controller-manager/values.yaml 
helm upgrade --install external-dns ./external-dns -n ingress --create-namespace -f ./external-dns/values.yaml 
helm upgrade --install cert-manager ./cert-manager -n ingress --create-namespace -f ./cert-manager/values.yaml
helm upgrade --install gitlab-runner ./gitlab-runner -n gitlab-runner --create-namespace -f ./gitlab-runner/values.yaml

kubectl get po -A | grep -E "gitlab|hcloud|hccm|external-dns|cert-manager"