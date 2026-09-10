# output "instance_group_masters_public_ips" { value = [for s in hcloud_server.masters : s.ipv4_address] }
# output "instance_group_workers_public_ips" { value = [for s in hcloud_server.workers : s.ipv4_address] }
output "instance_group_haproxy_public_ips" { value = [hcloud_server.haproxy.ipv4_address] }
output "ssh_nat_port_mapping" {
  value = local.nat_port_map
}
