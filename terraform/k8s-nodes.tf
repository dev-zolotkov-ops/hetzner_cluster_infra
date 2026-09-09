resource "hcloud_server" "masters" {
  for_each    = local.masters
  name        = each.value.name
  image       = "ubuntu-24.04"
  server_type = "cx23"
  location    = each.value.location
  public_net {
    ipv4_enabled = false
    ipv6_enabled = false
  }
  network {
    subnet_id = hcloud_network_subnet.k8s-subnet-1.id
    ip        = each.value.private_ip
  }
  user_data    = replace(local.cloud_init_master, "PRIVATE_IP", each.value.private_ip)
  ssh_keys     = [data.hcloud_ssh_key.my_key.id]
  firewall_ids = [hcloud_firewall.k8s-nodes.id]
  labels       = { role = "master" }
}
resource "hcloud_server" "workers" {
  for_each    = local.workers
  name        = each.value.name
  image       = "ubuntu-24.04"
  server_type = "cx23"
  location    = each.value.location
  public_net {
    ipv4_enabled = false
    ipv6_enabled = false
  }
  network {
    subnet_id = hcloud_network_subnet.k8s-subnet-2.id
    ip        = each.value.private_ip
  }
  user_data    = replace(local.cloud_init_worker, "PRIVATE_IP", each.value.private_ip)
  ssh_keys     = [data.hcloud_ssh_key.my_key.id]
  firewall_ids = [hcloud_firewall.k8s-nodes.id]
  labels       = { role = "worker" }
}
resource "hcloud_server" "haproxy" {
  name        = "haproxy-0"
  image       = "ubuntu-24.04"
  server_type = "cx23"
  location    = "fsn1"
  public_net {
    ipv4_enabled = true
    ipv6_enabled = false
  }
  network {
    subnet_id = hcloud_network_subnet.k8s-subnet-3.id
    ip        = var.haproxy_private_ip
  }
  user_data    = replace(local.cloud_init_haproxy, "PRIVATE_IP", var.haproxy_private_ip)
  ssh_keys     = [data.hcloud_ssh_key.my_key.id]
  firewall_ids = [hcloud_firewall.k8s-haproxy.id]
  labels       = { role = "haproxy" }
}
