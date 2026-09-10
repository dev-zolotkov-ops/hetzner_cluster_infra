resource "hcloud_firewall" "k8s-nodes" {
  name = "k8s-nodes"
  # rule {
  #   direction  = "in"
  #   protocol   = "tcp"
  #   port       = "22"
  #   source_ips = ["${var.admin_ip}/32"]
  # }
  # rule {
  #   direction  = "in"
  #   protocol   = "tcp"
  #   port       = "6443"
  #   source_ips = ["${var.admin_ip}/32", "192.168.0.0/16"]
  # }
  rule {
    direction  = "in"
    protocol   = "tcp"
    source_ips = ["192.168.0.0/16"]
  }
  rule {
    direction  = "in"
    protocol   = "udp"
    source_ips = ["192.168.0.0/16"]
  }
  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = ["192.168.0.0/16"]
  }
}
resource "hcloud_firewall" "k8s-haproxy" {
  name = "k8s-haproxy"
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = ["${var.admin_ip}/32"]
  }
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "3030-3050"
    source_ips = ["${var.admin_ip}/32"]
  }
}
