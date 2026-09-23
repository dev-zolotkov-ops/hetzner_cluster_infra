# cluster
=========

The role bootstraps the Kubernetes control plane and worker nodes with kubeadm, installs the Calico CNI plugin, and fetches the resulting cluster kubeconfig.

Kubelet serving certificates
----------------------------

After kubeadm initialization or node joins, the role persistently enables `serverTLSBootstrap: true` in `/var/lib/kubelet/config.yaml` and restarts kubelet only when that setting changes. This causes each kubelet to submit a `kubernetes.io/kubelet-serving` CSR. This repository has no CSR approval controller or automatic approval logic; review and approve requests manually only after verifying the node identity and requested DNS/IP SANs:

```bash
kubectl get csr -o wide
kubectl describe csr <csr-name>
kubectl certificate approve <csr-name>
kubectl get csr <csr-name> -o wide
```

Verify that the approved request has username `system:node:<node-name>`, the expected node-serving SANs, and usages appropriate for a server certificate before approving it. Then verify kubelet HTTPS metrics and Prometheus targets:

```bash
kubectl get csr -o jsonpath='{range .items[?(@.spec.signerName=="kubernetes.io/kubelet-serving")]}{.metadata.name}{"\t"}{.status.conditions[*].type}{"\n"}{end}'
kubectl -n monitoring get servicemonitor kube-prometheus-stack-kubelet -o yaml
```

Requirements
------------

Make sure that your inventory and vars (for the 'all' group) file are correct after autofill with Terraform. The inventory must define the `control_plane`, `workers`, `ingress`, and `haproxy` groups. Hosts must be prepared with the `preparing_hosts` role before this role runs.

Role Variables
--------------

**kubeadm_token**: "..."                    # token used by kubeadm to join nodes

**kube_pod_network_cidr**: "10.244.0.0/16"  # pod network CIDR passed to kubeadm

**calico_version**: "v3.31.0"               # Calico release to install

**calico_manifest_url**: "https://raw.githubusercontent.com/projectcalico/calico/{{ calico_version }}/manifests/calico.yaml" # Calico manifest URL

**haproxy_public_ip**: "..."                # public address of the Kubernetes API endpoint

Dependencies
------------

The `preparing_hosts` role must run first and install kubelet, kubeadm, kubectl, and the required host networking configuration.

Example Playbook
----------------

- hosts: all
  become: true
  roles:
    - { role: cluster, tags: ['cluster'], when: enables_roles.cluster }

ansible-playbook k8s-install.yml --tags=cluster
