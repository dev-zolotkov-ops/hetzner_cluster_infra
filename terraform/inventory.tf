locals {
  inventory_content = templatefile("${path.module}/templates/hosts.yml.tftpl", {
    masters           = values(local.masters)
    workers           = values(local.workers)
    ingress           = values(local.ingress)
    haproxy_public_ip = hcloud_server.haproxy.ipv4_address
  })
}

resource "terraform_data" "ansible_inventory" {
  triggers_replace = sha256(local.inventory_content)

  provisioner "local-exec" {
    command = <<-EOT
      mkdir -p "${path.module}/../ansible"
      printf '%s' '${base64encode(local.inventory_content)}' | base64 --decode > "${path.module}/../ansible/hosts.yml"
    EOT
  }
}
