# This repo is not for developers.

You can create and bootstrap HA cluster with Terraform, Ansible and Helm tools in Hetzner using this repo.

# Prerequisites And Pre-Deploy Checks

Required locally: Terraform (Hetzner provider lockfile is present), Ansible, `kubectl`, Helm, and `istioctl` **1.30.4**. The cluster is prepared by the Ansible roles in this repository; no external Kubespray checkout is used. Configure a kubeconfig and select the target context before running Helm.

Required credentials and cluster prerequisites confirmed by the manifests:

- `HCLOUD_TOKEN` for Terraform and a Kubernetes Secret named `hcloud` with key `token` for hcloud CSI and CCM. Optional Robot credentials use `robot-user` and `robot-password`.
- Kubernetes Secret `grafana-admin-credentials` in namespace `monitoring`, with keys `admin-user` and `admin-password`.
- Hetzner CCM must be running before LoadBalancer services; hcloud CSI creates the `hcloud-volumes` StorageClass used by Grafana and Prometheus.
- External DNS is configured for the AWS provider, so the corresponding AWS/DNS provider credentials and DNS access must be available in the cluster environment. No credential values belong in this repository.

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
    ./install.sh
