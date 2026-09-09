variable "admin_ip" {
  type    = string
  default = "0.0.0.0/0"
}
variable "master_count" {
  type    = number
  default = 3
}
variable "worker_count" {
  type    = number
  default = 1
}

variable "haproxy_private_ip" {
  type    = string
  default = "192.168.30.30"
}

data "hcloud_ssh_key" "my_key" {
  name = "my-key"
}
