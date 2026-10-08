# Cluster Infrastructure

This repository deploys an HA Kubernetes cluster in Hetzner using Terraform, Ansible, and Helm. It is not an application development project: it documents infrastructure, network ingress, storage, monitoring, logging, and CI/CD.

## Purpose and Architecture

Terraform creates `hcloud_server` resources for `masters`, `workers`, `ingress`, and `haproxy`, the `k8s-network` network with four subnets, a default route through HAProxy, the `k8s-nodes` and `k8s-haproxy` firewalls, and `terraform_data` resources for Ansible inventory and variables. Terraform does not create a Hetzner LoadBalancer. The LoadBalancer appears later through HCCM when a Kubernetes Service receives type `LoadBalancer`. Ansible prepares the hosts and installs Kubernetes through the `ansible/roles/preparing_hosts` and `ansible/roles/cluster` roles, called from `ansible/k8s-install.yml`.

The cluster uses:

- Hetzner Cloud Controller Manager (`hccm`) for cloud integration and LoadBalancer support.
- Hetzner CSI (`hcloud-csi`) and the `hcloud-volumes` StorageClass for PVCs.
- The Istio control plane and `istio-ingressgateway`.
- `external-dns` with Cloudflare and cert-manager with production Let's Encrypt DNS-01.
- `postfinance/kubelet-csr-approver` for safely approving `kubernetes.io/kubelet-serving` CSRs and rotating serving certificates.
- `kube-prometheus-stack` for Prometheus, Grafana, Alertmanager, node-exporter, and kube-state-metrics.
- Loki in `Monolithic` mode and an Alloy DaemonSet for container logs.
- GitLab Runner releases `build-runner`, `deploy-runner`, and `test-runner`.
- Tempo in `Monolithic` mode and an Alloy OTLP pipeline for additional tracing.
- Metrics Server for `metrics.k8s.io` and Kubernetes Autoscaler VPA for CPU/memory recommendations and the admission webhook.

Public origins work only through Cloudflare: public VirtualServices require `cloudflare-proxied: true`, and `ingress/cloudflare-origin-policy.yml` blocks direct traffic that does not come from Cloudflare CIDRs. The Hetzner LoadBalancer and Istio ingress gateway use the PROXY protocol so Istio can see the client's original IP. Cloudflare IPv4/IPv6 CIDRs must be checked periodically against the official lists.

The shared Gateway and Certificate are in `ingress/gateway_cert.yml`; Telemetry for Istio HTTP metrics is in `ingress/ingress-telemetry.yml`. Public addresses are `https://final-work-k8s.raisa44.men` and `https://grafana.raisa44.men`.

## Local Requirements

You need Terraform with the Hetzner provider lockfile, Ansible, `kubectl`, Helm, `jq`, `curl`, `dig`, `hcloud`, Python 3 with PyYAML, and `istioctl` version **1.30.4**. Before running Helm commands, configure kubeconfig and select the target context. Helm charts and dependencies are already in the repository; `helm repo update` is not needed for `install.sh`. PyYAML is required by the recovery script to read vendored Helm values.

The following secrets and conditions are required:

- `HCLOUD_TOKEN` for Terraform.
- Secret `hcloud` in `kube-system` with the `token` key; `install.sh` additionally writes the `k8s-network` network ID to it.
- Secret `grafana-admin-credentials` in `monitoring` with the `admin-user` and `admin-password` keys.
- Secret `cloudflare-external-dns` in `ingress` with the `api-token` key.
- Secret `cloudflare-cert-manager` in `ingress` with the `api-token` key.
- Files `../../../../.sensitive_data/ns_secrets_roles.yml` and `../../../../.sensitive_data/opencode_kubeconfig.sh`, used by the current `install.sh`; this path is calculated relative to the repository root, and secret values are not added to the repository.

Check the environment before deployment:

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

## Deployment Order

1. Create the infrastructure from `terraform/`:

```bash
cd terraform
export HCLOUD_TOKEN="<your_token>"
terraform plan
terraform apply
```

2. Prepare the hosts and install the cluster from `ansible/`:

```bash
cd ../ansible
ansible-playbook k8s-install.yml -t preparing_hosts
ansible-playbook k8s-install.yml -t cluster
```

3. From the repository root, create the prerequisites and run the complete bootstrap:

```bash
./install.sh
```

The script applies the external `ns_secrets_roles.yml` file, installs HCCM and CSI, checks only the major/minor `istioctl` version against `1.30`, installs Istio, ExternalDNS, and cert-manager, applies `ingress/gateway_cert.yml`, `ingress/ingress-telemetry.yml`, and `ingress/cloudflare-origin-policy.yml`, then installs kube-prometheus-stack, Metrics Server, VPA, the remaining monitoring stack, and the three GitLab Runners. The local prerequisites specify target `istioctl 1.30.4`; it is compatible with the `1.30` check because the script does not pin the patch version. The current command does not set a separate ACME email.

## Ingress, DNS, and Certificates

ExternalDNS publishes DNS through Cloudflare. cert-manager obtains a production Let's Encrypt certificate through DNS-01 using Secret `cloudflare-cert-manager`. The Gateway serves both public names, the certificate uses Secret `final-work-k8s-tls`, and HTTP redirects to HTTPS. The Grafana VirtualService is created by the values in `helm/kube-prometheus-stack/values.yaml`; no second Gateway, Certificate, or Grafana VirtualService is needed.

Check the origin policy and PROXY protocol:

```bash
kubectl -n istio-system get authorizationpolicy cloudflare-origin-only
kubectl -n istio-system get service istio-ingressgateway -o yaml
kubectl -n istio-system rollout status deployment/istio-ingressgateway --timeout=5m
curl -I https://final-work-k8s.raisa44.men/
curl -k -I --resolve final-work-k8s.raisa44.men:443:<LB_IP> https://final-work-k8s.raisa44.men/
```

A request through the hostname must go through Cloudflare, while a direct `curl --resolve` request to the LoadBalancer must return `403`. Internal Prometheus scraping on `15090` is allowed; this port is not published by the LoadBalancer and does not open application traffic.

## Storage

HCCM must be running before a LoadBalancer Service is created, and CSI must create the `hcloud-volumes` StorageClass. Current monitoring PVC sizes and replica counts are defined in the vendored Helm values and checked by the recovery script rather than duplicated here. Loki uses one pod, filesystem storage, and `168h` retention; its `storage-loki-0` PVC must not be deleted. Loki's configuration intentionally retains the `boltdb-shipper` v12 schema with the date `2024-01-01`. Upgrade and backup details are in [`docs/logging-and-tracing.md`](docs/logging-and-tracing.md).

Monitoring PVCs are protected from Terraform destroy: the StorageClass uses `Retain`, and `install.sh` requires an authoritative `hcloud volume list`, performs fail-closed recovery of verified Hetzner volumes before the monitoring Helm releases, then checks all five PVCs after monitoring and registers only the selected volumes with short durable labels. The five historical IDs and exact claims are in `storage/monitoring-volume-registry.json`.

Details of pre-install recovery, static CSI PVs, and the dynamic first bootstrap are in [`docs/monitoring-storage-recovery.md`](docs/monitoring-storage-recovery.md).

## Monitoring

`kube-prometheus-stack` is installed from `helm/kube-prometheus-stack/values.yaml` at chart version `91.4.1`. Kubelet/cAdvisor, node-exporter, kube-state-metrics, and the custom dashboards `Kubernetes / Pod Resources`, `Kubernetes / Cluster Overview`, and `Istio / Ingress HTTP` are enabled. Kubelet and cAdvisor are scraped over HTTPS on `10250`; probe metrics are disabled. Prometheus and Grafana run on worker nodes, while kube-state-metrics and admission jobs run on the control plane.

Detailed metric purposes, dashboards, checks, artifacts, troubleshooting, and the Istio ingress HTTP bonus are documented in [`docs/monitoring.md`](docs/monitoring.md).

## Logging and Tracing

`helm/loki/values-final-work.yaml` installs Loki, `helm/alloy/values-final-work.yaml` installs the Alloy DaemonSet on the nodes, and `helm/loki-datasource` creates the `Loki` datasource for Grafana. Loki is available only inside the cluster; the log flow is pod -> Alloy -> Loki -> Grafana Explore.

Detailed parameters, upgrade order, backup, LogQL, troubleshooting, and the acceptance checklist are in [`docs/logging-and-tracing.md`](docs/logging-and-tracing.md).

## Autoscaling

Metrics Server `3.14.0` / app `0.9.0` publishes the protected `metrics.k8s.io` resource API. VPA chart `0.9.0` / app `1.7.0` then installs the CRD, recommender, updater, and admission controller/webhook. Both official charts are fully vendored in `helm/metrics-server` and `helm/vertical-pod-autoscaler`. Tolerations allow the components to run on the three tainted control-plane nodes without occupying the sole worker. Details of HPA/VPA, upgrades, and checks are in [`docs/autoscaling.md`](docs/autoscaling.md).

Additional tracing is prepared through Tempo chart `3.0.0` / app `3.0.3`, the Tempo datasource UID `tempo`, and Alloy OTLP ports `4317`/`4318`; the existing log flow is unchanged. The span source is the instrumented Online Boutique service `v0.10.0`, which sends OTLP through Alloy to Tempo. Live spans are not expected until the boutique is redeployed with tracing environment variables; details and verification are in [`docs/logging-and-tracing.md`](docs/logging-and-tracing.md).

## Cluster Verification

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

For a quick Monitoring check, use the commands and PromQL in [`docs/monitoring.md`](docs/monitoring.md); for Loki and Alloy checks, use [`docs/logging-and-tracing.md`](docs/logging-and-tracing.md). Do not include secrets in output, screenshots, or artifacts.
