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
variable "ingress_count" {
  type    = number
  default = 2
}

variable "haproxy_private_ip" {
  type    = string
  default = "192.168.30.30"
}

variable "kubeadm_token" {
  type        = string
  description = "Static kubeadm bootstrap token used by Kubespray"
  default     = "5qrmju.mstglmsfgl989pof"
}

data "hcloud_ssh_key" "my_key" {
  name = "my-key"
}
