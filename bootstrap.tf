locals {
  openwrt_host                = "10.210.0.9"
  manager_ssh_key_remote_path = "/home/${local.ssh_user}/.ssh/id_ed25519_terraform"
  nebula_repo_path            = "/home/${local.ssh_user}/nebula-infra-swarm"

  nodes = {
    vm1 = {
      ip   = local.vm1_ip
      name = local.vm_definitions["vm1"].name
      role = "app"
    }
    vm2 = {
      ip   = local.vm2_ip
      name = local.vm_definitions["vm2"].name
      role = "edge"
    }
    vm3 = {
      ip   = local.vm3_ip
      name = local.vm_definitions["vm3"].name
      role = "data"
    }
  }

  full_bootstrap_requested = var.enable_cluster_bootstrap || var.enable_monitoring_deploy
}

variable "openwrt_password" {
  type        = string
  sensitive   = true
  description = "Mot de passe root OpenWrt utilise comme bastion SSH."
}

variable "ssh_private_key_path" {
  type        = string
  default     = "~/.ssh/id_ed25519"
  description = "Chemin local vers la cle privee SSH utilisee pour se connecter aux VM."
}

variable "nebula_repo_url" {
  type        = string
  default     = "https://github.com/Aozoke/nebula-infra-swarm.git"
  description = "Depot Git a cloner pour le deploiement applicatif."
}

variable "python_base_image" {
  type        = string
  default     = "public.ecr.aws/docker/library/python:3.12-slim"
  description = "Image de base Python utilisee pour les builds applicatifs afin d'eviter les rate limits Docker Hub."
}

variable "enable_cluster_bootstrap" {
  type        = bool
  default     = false
  description = "Prepare le Swarm, clone le repo, build les images applicatives et deploie Nebula + Portainer."
}

variable "enable_monitoring_deploy" {
  type        = bool
  default     = false
  description = "Deploie Grafana, Prometheus et node-exporter apres le bootstrap du cluster."
}

variable "nebula_postgres_password" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Mot de passe injecte dans le secret Docker nebula_postgres_password."
}

variable "grafana_admin_password" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Mot de passe injecte dans le secret Docker grafana_admin_password."
}

resource "null_resource" "install_docker" {
  for_each = local.nodes

  depends_on = [
    proxmox_virtual_environment_vm.ubuntu_vm,
  ]

  triggers = {
    ip                 = each.value.ip
    ssh_private_key    = filemd5(pathexpand(var.ssh_private_key_path))
    docker_install_rev = "2"
  }

  connection {
    type             = "ssh"
    host             = each.value.ip
    user             = local.ssh_user
    private_key      = file(pathexpand(var.ssh_private_key_path))
    timeout          = "15m"
    bastion_host     = local.openwrt_host
    bastion_user     = "root"
    bastion_password = var.openwrt_password
  }

  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait || true",
      "echo 'Acquire::ForceIPv4 \"true\";' | sudo tee /etc/apt/apt.conf.d/99force-ipv4 >/dev/null",
      "sudo apt-get -o Acquire::ForceIPv4=true update",
      "if ! command -v docker >/dev/null 2>&1; then sudo DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::ForceIPv4=true install -y docker.io; fi",
      "sudo systemctl enable --now docker",
      "sudo usermod -aG docker ${local.ssh_user} || true",
      "sudo docker version",
    ]
  }
}

resource "null_resource" "manager_ssh_key" {
  count = local.full_bootstrap_requested ? 1 : 0

  depends_on = [
    null_resource.install_docker,
  ]

  triggers = {
    manager_ip          = local.nodes.vm2.ip
    ssh_private_key_md5 = filemd5(pathexpand(var.ssh_private_key_path))
    manager_ssh_key_rev = "1"
  }

  connection {
    type             = "ssh"
    host             = local.nodes.vm2.ip
    user             = local.ssh_user
    private_key      = file(pathexpand(var.ssh_private_key_path))
    timeout          = "15m"
    bastion_host     = local.openwrt_host
    bastion_user     = "root"
    bastion_password = var.openwrt_password
  }

  provisioner "file" {
    source      = pathexpand(var.ssh_private_key_path)
    destination = "/tmp/id_ed25519_terraform"
  }

  provisioner "remote-exec" {
    inline = [
      "mkdir -p ~/.ssh",
      "install -m 600 /tmp/id_ed25519_terraform ${local.manager_ssh_key_remote_path}",
    ]
  }
}

resource "null_resource" "prepull_service_images" {
  for_each = local.full_bootstrap_requested ? local.nodes : {}

  depends_on = [
    null_resource.install_docker,
  ]

  triggers = {
    ip             = each.value.ip
    prepull_rev    = "1"
    prepull_script = filesha256("${path.module}/scripts/bootstrap/prepull-service-images.sh.tftpl")
  }

  connection {
    type             = "ssh"
    host             = each.value.ip
    user             = local.ssh_user
    private_key      = file(pathexpand(var.ssh_private_key_path))
    timeout          = "20m"
    bastion_host     = local.openwrt_host
    bastion_user     = "root"
    bastion_password = var.openwrt_password
  }

  provisioner "file" {
    content     = templatefile("${path.module}/scripts/bootstrap/prepull-service-images.sh.tftpl", {})
    destination = "/tmp/prepull-service-images.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/prepull-service-images.sh",
      "bash /tmp/prepull-service-images.sh",
    ]
  }
}

resource "null_resource" "cluster_bootstrap" {
  count = var.enable_cluster_bootstrap ? 1 : 0

  depends_on = [
    null_resource.install_docker,
    null_resource.manager_ssh_key,
    null_resource.prepull_service_images,
  ]

  triggers = {
    manager_ip            = local.nodes.vm2.ip
    app_ip                = local.nodes.vm1.ip
    data_ip               = local.nodes.vm3.ip
    manager_name          = local.nodes.vm2.name
    app_name              = local.nodes.vm1.name
    data_name             = local.nodes.vm3.name
    repo_url              = var.nebula_repo_url
    repo_path             = local.nebula_repo_path
    python_base_image     = var.python_base_image
    postgres_password_sha = nonsensitive(sha256(var.nebula_postgres_password))
    cluster_script        = filesha256("${path.module}/scripts/bootstrap/cluster-bootstrap.sh.tftpl")
  }

  lifecycle {
    precondition {
      condition     = var.nebula_postgres_password != ""
      error_message = "Definis TF_VAR_nebula_postgres_password avant d'activer enable_cluster_bootstrap."
    }
  }

  connection {
    type             = "ssh"
    host             = local.nodes.vm2.ip
    user             = local.ssh_user
    private_key      = file(pathexpand(var.ssh_private_key_path))
    timeout          = "20m"
    bastion_host     = local.openwrt_host
    bastion_user     = "root"
    bastion_password = var.openwrt_password
  }

  provisioner "file" {
    content = templatefile("${path.module}/scripts/bootstrap/cluster-bootstrap.sh.tftpl", {
      manager_ip                  = local.nodes.vm2.ip
      app_ip                      = local.nodes.vm1.ip
      data_ip                     = local.nodes.vm3.ip
      manager_name                = local.nodes.vm2.name
      app_name                    = local.nodes.vm1.name
      data_name                   = local.nodes.vm3.name
      manager_ssh_key_remote_path = local.manager_ssh_key_remote_path
      ssh_user                    = local.ssh_user
      nebula_repo_path            = local.nebula_repo_path
      nebula_repo_url             = var.nebula_repo_url
      python_base_image           = var.python_base_image
      postgres_password_b64       = base64encode(var.nebula_postgres_password)
    })
    destination = "/tmp/cluster-bootstrap.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/cluster-bootstrap.sh",
      "bash /tmp/cluster-bootstrap.sh",
    ]
  }
}

resource "null_resource" "monitoring_bootstrap" {
  count = var.enable_monitoring_deploy ? 1 : 0

  depends_on = [
    null_resource.cluster_bootstrap,
    null_resource.prepull_service_images,
  ]

  triggers = {
    manager_ip        = local.nodes.vm2.ip
    app_ip            = local.nodes.vm1.ip
    data_ip           = local.nodes.vm3.ip
    repo_path         = local.nebula_repo_path
    grafana_admin_sha = nonsensitive(sha256(var.grafana_admin_password))
    grafana_root_url  = "http://${local.nodes.vm2.ip}/grafana"
    monitoring_script = filesha256("${path.module}/scripts/bootstrap/monitoring-bootstrap.sh.tftpl")
  }

  lifecycle {
    precondition {
      condition     = var.enable_cluster_bootstrap
      error_message = "Active aussi enable_cluster_bootstrap avant enable_monitoring_deploy."
    }

    precondition {
      condition     = var.grafana_admin_password != ""
      error_message = "Definis TF_VAR_grafana_admin_password avant d'activer enable_monitoring_deploy."
    }
  }

  connection {
    type             = "ssh"
    host             = local.nodes.vm2.ip
    user             = local.ssh_user
    private_key      = file(pathexpand(var.ssh_private_key_path))
    timeout          = "20m"
    bastion_host     = local.openwrt_host
    bastion_user     = "root"
    bastion_password = var.openwrt_password
  }

  provisioner "file" {
    content = templatefile("${path.module}/scripts/bootstrap/monitoring-bootstrap.sh.tftpl", {
      app_ip                      = local.nodes.vm1.ip
      data_ip                     = local.nodes.vm3.ip
      grafana_password_b64        = base64encode(var.grafana_admin_password)
      grafana_root_url            = "http://${local.nodes.vm2.ip}/grafana"
      manager_ssh_key_remote_path = local.manager_ssh_key_remote_path
      nebula_repo_path            = local.nebula_repo_path
      ssh_user                    = local.ssh_user
    })
    destination = "/tmp/monitoring-bootstrap.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/monitoring-bootstrap.sh",
      "bash /tmp/monitoring-bootstrap.sh",
    ]
  }
}

moved {
  from = null_resource.install_docker[0]
  to   = null_resource.install_docker["vm1"]
}

moved {
  from = null_resource.install_docker[1]
  to   = null_resource.install_docker["vm2"]
}

moved {
  from = null_resource.install_docker[2]
  to   = null_resource.install_docker["vm3"]
}

moved {
  from = null_resource.prepull_runtime_images[0]
  to   = null_resource.prepull_service_images["vm1"]
}

moved {
  from = null_resource.prepull_runtime_images[1]
  to   = null_resource.prepull_service_images["vm2"]
}

moved {
  from = null_resource.prepull_runtime_images[2]
  to   = null_resource.prepull_service_images["vm3"]
}
