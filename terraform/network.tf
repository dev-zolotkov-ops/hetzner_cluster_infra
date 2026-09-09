resource "hcloud_network" "k8s-network" {
  name     = "k8s-network"
  ip_range = "192.168.0.0/16"
}
resource "hcloud_network_subnet" "k8s-subnet-1" {
  network_id   = hcloud_network.k8s-network.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "192.168.10.0/24"
}

resource "hcloud_network_subnet" "k8s-subnet-2" {
  network_id   = hcloud_network.k8s-network.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "192.168.20.0/24"
}

resource "hcloud_network_subnet" "k8s-subnet-3" {
  network_id   = hcloud_network.k8s-network.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "192.168.30.0/24"
}

resource "hcloud_network_route" "default_via_haproxy" {
  network_id  = hcloud_network.k8s-network.id
  destination = "0.0.0.0/0"
  gateway     = var.haproxy_private_ip
}