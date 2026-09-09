locals {
  cloud_init_haproxy = <<-EOF
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
      - path: /etc/sysctl.d/88-nat.conf
        content: |
          net.ipv4.ip_forward=1                    
    runcmd:
      - [netplan, generate]
      - [netplan, apply]
      - [sysctl, system]
      - [iptables, -t, nat, -A ,POSTROUTING ,-s ,192.168.0.0/16, -o, eth0, -j, MASQUERADE]
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
}
