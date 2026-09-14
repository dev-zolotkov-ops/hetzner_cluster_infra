# preparing_hosts
=================

The role is created to prepare hosts after terraform cloud infrastracture preparing before K8S cluster is bootstrapped.

Requirements
------------

Make sure that your inventory and vars (for 'all' group) file are correct after autofillitg with terraform

Role Variables
--------------

kubernetes_repo_version: "v1.36"          # version of the K8S repository for installation K8S components from
kubernetes_package_version: "1.36.4-1.1"  # kubelet, kubectl and kubeadm version
haproxy_cfg: /etc/haproxy/haproxy.cfg     # haproxy config file path

Dependencies
------------

A list of other roles hosted on Galaxy should go here, plus any details in regards to parameters that may need to be set for other roles, or variables that are used from other roles.

Example Playbook
----------------

- hosts: all
  roles:
    - { role: preparing_hosts, tags: ['preparing_hosts'], when: roles.preparing_hosts }

ansible-playbook k8s-install.yml --tags=preparing_hosts
