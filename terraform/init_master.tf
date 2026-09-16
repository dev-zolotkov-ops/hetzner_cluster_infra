locals {
  cloud_init_master = <<-EOF
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

  master_locations = ["fsn1", "nbg1", "hel1"]

  masters = {
    for i in range(var.master_count) : i => {
      name       = "master-${i}"
      location   = local.master_locations[i % length(local.master_locations)]
      private_ip = "192.168.10.${10 + i}"
    }
  }
}
