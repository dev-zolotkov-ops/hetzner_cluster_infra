locals {
  vars_content = templatefile("${path.module}/templates/vars.yml.tftpl", {
    haproxy_public_ip = hcloud_server.haproxy.ipv4_address
    kubeadm_token     = var.kubeadm_token
    nat_port_mapping  = local.nat_port_map
  })
}

resource "terraform_data" "ansible_vars" {
  triggers_replace = sha256(local.vars_content)

  provisioner "local-exec" {
    command = <<-EOT
      mkdir -p "${path.module}/../ansible/group_vars/all"
      printf '%s' '${base64encode(local.vars_content)}' | base64 --decode > "${path.module}/../ansible/group_vars/all/vars.yml"
    EOT
  }
}
