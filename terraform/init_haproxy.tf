locals {
  nat_forwardings = [
    for index, node in concat(values(local.masters), values(local.workers), values(local.ingress)) : {
      public_port = 3030 + index
      private_ip  = node.private_ip
    }
  ]

  nat_port_map = {
    for forwarding in local.nat_forwardings : forwarding.public_port => forwarding.private_ip
  }

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
    package_update: true
    packages:
      - curl
      - iptables
    runcmd:
      - [netplan, generate]
      - [netplan, apply]
      - [sysctl, --system]
      - [iptables, -t, nat, -A, POSTROUTING, -s, 192.168.0.0/16, -o, eth0, -j, MASQUERADE]
      - [iptables, -t, nat, -A, POSTROUTING, -o, enp7s0, -d, 192.168.0.0/16, -p, tcp, --dport, 22, -j, MASQUERADE]
      - [iptables, -A, FORWARD, -s, 192.168.0.0/16, -m, conntrack, --ctstate, ESTABLISHED,RELATED, -j, ACCEPT]
      - [iptables, -A, FORWARD, -d, 192.168.0.0/16, -p, tcp, --dport, 22, -m, conntrack, --ctstate, NEW,ESTABLISHED, -j, ACCEPT]
${join("\n", [for forwarding in local.nat_forwardings : "      - [iptables, -t, nat, -A, PREROUTING, -p, tcp, --dport, ${forwarding.public_port}, -j, DNAT, --to-destination, ${forwarding.private_ip}:22]"])}
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
