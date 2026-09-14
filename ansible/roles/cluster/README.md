# cluster
=========

The role bootstraps the Kubernetes control plane and worker nodes with kubeadm, installs the Calico CNI plugin, and fetches the resulting cluster kubeconfig.

Requirements
------------

Make sure that your inventory and vars (for the 'all' group) file are correct after autofill with Terraform. The inventory must define the `control_plane`, `workers`, `ingress`, and `haproxy` groups. Hosts must be prepared with the `preparing_hosts` role before this role runs.

Role Variables
--------------

kubeadm_token: "..."                    # token used by kubeadm to join nodes

kube_pod_network_cidr: "10.244.0.0/16"  # pod network CIDR passed to kubeadm

calico_version: "v3.31.0"               # Calico release to install

calico_manifest_url: "https://raw.githubusercontent.com/projectcalico/calico/{{ calico_version }}/manifests/calico.yaml" # Calico manifest URL

haproxy_public_ip: "..."                # public address of the Kubernetes API endpoint

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
