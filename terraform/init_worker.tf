locals {
  cloud_init_worker = <<-EOF
    #cloud-config
    write_files:
      - path: /etc/netplan/99-private-network.yaml
        permissions: '0600'
        content: |
          network:
            version: 2
            renderer: networkd
            ethernets:
              enp7s0:
                dhcp4: false
                mtu: 1450
                addresses:
                  - PRIVATE_IP/32
                routes:
                  - to: 192.168.0.1/32
                    scope: link
                  - to: 192.168.0.0/16
                    via: 192.168.0.1
                    on-link: true
                  - to: 0.0.0.0/0
                    via: 192.168.0.1
                nameservers:
                  addresses:
                    - 1.1.1.1
                    - 8.8.8.8
    runcmd:
      - |
        until ip link show enp7s0 >/dev/null 2>&1; do
          sleep 2
        done

      - |
        until ip addr show enp7s0 | grep -q "PRIVATE_IP"; do
          sleep 2
        done

      - |
        until ip route | grep -E '^default .*192.168.0.1'; do
          netplan apply
          sleep 2
        done
    users:
      - name: ubuntu
        gecos: Ubuntu User
        groups: sudo
        shell: /bin/bash
        sudo: ALL=(ALL) NOPASSWD:ALL
        lock_passwd: true
        ssh_authorized_keys:
          - ${trimspace(data.hcloud_ssh_key.my_key.public_key)}
    ssh_deletekeys: false
    ssh_pwauth: false
  EOF

  worker_locations = ["fsn1"]

  workers = {
    for i in range(var.worker_count) : i => {
      name       = "worker-${i}"
      location   = local.worker_locations[i % length(local.worker_locations)]
      private_ip = "192.168.20.${20 + i}"
    }
  }

  ingress_locations = ["fsn1"]

  ingress = {
    for i in range(var.ingress_count) : i => {
      name       = "ingress-${i}"
      location   = local.ingress_locations[i % length(local.ingress_locations)]
      private_ip = "192.168.40.${20 + i}"
    }
  }
}
