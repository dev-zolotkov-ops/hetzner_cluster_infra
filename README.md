# This repo is not for developers.

You can create and bootstrap HA cluster with Terraform, Ansible and Helm tools in Hetzner using this repo.

# Prerequisites And Pre-Deploy Checks

Required locally: Terraform (Hetzner provider lockfile is present), Ansible, `kubectl`, Helm, and `istioctl` **1.30.4**. The cluster is prepared by the Ansible roles in this repository; no external Kubespray checkout is used. Configure a kubeconfig and select the target context before running Helm.

Required credentials and cluster prerequisites confirmed by the manifests:

- `HCLOUD_TOKEN` for Terraform and a Kubernetes Secret named `hcloud` with key `token` for hcloud CSI and CCM. Optional Robot credentials use `robot-user` and `robot-password`.
- Kubernetes Secret `grafana-admin-credentials` in namespace `monitoring`, with keys `admin-user` and `admin-password`.
- Hetzner CCM must be running before LoadBalancer services; hcloud CSI creates the `hcloud-volumes` StorageClass used by Grafana and Prometheus.
- External DNS uses Cloudflare DNS. Create the Kubernetes Secret `cloudflare_external_dns` in namespace `ingress` with key `api-token`. cert-manager's production Let's Encrypt DNS-01 solver uses the Secret `cloudflare_cert_manager` in namespace `ingress` with key `api-token`. Do not store token values in this repository.

Run these checks without deploying:

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
kubectl -n ingress get secret cloudflare_external_dns cloudflare_cert_manager
```

The Helm charts and dependencies are vendored here; `helm repo update` is not required for `helm/install.sh`.

# Deploy

```bash
    cd ./terraform && export HCLOUD_TOKEN="<your_token>"
    terraform plan
    terraform apply
```

```bash
    cd ../ansible
    <some_command>   # here is some command to activate venv if it`s necessary
    ansible-playbook k8s-install.yml -t preparing_hosts
    ansible-playbook k8s-install.yml -t cluster
```

```bash
    cd ../helm
    export ACME_EMAIL="<your_acme_account_email>"
    ./install.sh
```

Monitoring is installed by the final Helm command in `install.sh`. Before running it, create the Grafana credentials Secret without putting the values in this repository:

Task 3 monitoring verification, dashboard inventory, metrics rationale, artifacts, and deployment troubleshooting are documented in [`docs/task-3-monitoring.md`](docs/task-3-monitoring.md).

```bash
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl -n monitoring create secret generic grafana-admin-credentials \
  --from-literal=admin-user='<admin-user>' \
  --from-literal=admin-password='<admin-password>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

The `kube-prometheus-stack` release deploys Prometheus and Grafana, stores Prometheus data for 10 days on a 30 GiB `hcloud-volumes` PVC, and stores Grafana data on a 10 GiB `hcloud-volumes` PVC. Kubelet and cAdvisor ServiceMonitor endpoints are enabled for node and container CPU/memory metrics, including `container_cpu_usage_seconds_total` and `container_memory_working_set_bytes`; probe metrics remain disabled. The only bundled default recording rules enabled are the pod/container CPU and memory groups used by the Kubernetes dashboards, producing `node_namespace_pod_container:container_cpu_usage_seconds_total:sum_irate` and `node_namespace_pod_container:container_memory_working_set_bytes`. Prometheus and Grafana remain on worker nodes; kube-state-metrics and the operator admission jobs use the control-plane placement configured in the values file.

The chart provisions the default Prometheus datasource automatically through Grafana's datasource sidecar, pointing at the in-cluster Prometheus service. No manual datasource ConfigMap is required.

Grafana is published at `https://grafana.final-work-k8s.raisa44.men` through the existing Cloudflare ExternalDNS -> Hetzner LoadBalancer -> Istio ingress path. The Grafana VirtualService is rendered by the `kube-prometheus-stack` Helm release, and ExternalDNS watches Istio VirtualServices. The shared Gateway and Certificate are repo-owned in `ingress/gateway_cert.yml`; the install script applies that manifest before the monitoring Helm release. The Gateway and Certificate already include both public hostnames:

```yaml
# Repo-owned Gateway, HTTPS server
spec:
  servers:
    - port:
        number: 443
        name: https
        protocol: HTTPS
      tls:
        credentialName: final-work-k8s-tls
      hosts:
        - final-work-k8s.raisa44.men
        - grafana.final-work-k8s.raisa44.men

# Repo-owned Certificate
spec:
  dnsNames:
    - final-work-k8s.raisa44.men
    - grafana.final-work-k8s.raisa44.men
  secretName: final-work-k8s-tls
```

The HTTP server uses the wildcard host and redirects to HTTPS. Do not create a second Gateway, Certificate, or Grafana VirtualService.

Verify the deployment and routing with:

```bash
helm -n monitoring status kube-prometheus-stack
kubectl -n monitoring get pods,svc,pvc,prometheus,alertmanager
kubectl -n monitoring get servicemonitor kube-prometheus-stack-kubelet -o yaml
kubectl -n monitoring get virtualservice grafana -o yaml
kubectl -n monitoring get secret grafana-admin-credentials
kubectl -n istio-system get secret final-work-k8s-tls
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
curl -I https://grafana.final-work-k8s.raisa44.men
```

Confirm DNS and certificate readiness with `dig grafana.final-work-k8s.raisa44.men` and `kubectl get certificate -A`.
