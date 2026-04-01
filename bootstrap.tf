locals {
  openwrt_host                = "10.210.0.9"
  vm1_name                    = "vm1-lefevret"
  vm2_name                    = "vm2-lefevret"
  vm3_name                    = "vm3-lefevret"
  manager_ip                  = local.vm2_ip
  manager_ssh_key_remote_path = "/home/${local.ssh_user}/.ssh/id_ed25519_terraform"
  nebula_repo_path            = "/home/${local.ssh_user}/nebula-infra-swarm"
  full_bootstrap_requested    = var.enable_swarm_bootstrap || var.enable_repo_prepare || var.enable_app_image_build || var.enable_nebula_deploy || var.enable_monitoring_deploy
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
  description = "Depot Git a cloner sur vm1 et vm2 pour la partie applicative."
}

variable "enable_swarm_bootstrap" {
  type        = bool
  default     = false
  description = "Initialise le manager Swarm sur vm2, fait rejoindre vm1/vm3 et applique les labels."
}

variable "enable_repo_prepare" {
  type        = bool
  default     = false
  description = "Clone ou met a jour le depot nebula-infra-swarm sur vm1 et vm2."
}

variable "enable_app_image_build" {
  type        = bool
  default     = false
  description = "Build les images applicatives Nebula sur vm1."
}

variable "enable_nebula_deploy" {
  type        = bool
  default     = false
  description = "Cree le secret Postgres puis deploie la stack Nebula et Portainer depuis vm2."
}

variable "enable_monitoring_deploy" {
  type        = bool
  default     = false
  description = "Cree le secret Grafana, corrige l'URL Grafana et deploie le monitoring depuis vm2."
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
  count = length(local.all_ips)

  depends_on = [
    proxmox_virtual_environment_vm.first_vm,
    proxmox_virtual_environment_vm.second_vm,
    proxmox_virtual_environment_vm.third_vm,
  ]

  triggers = {
    ip                 = local.all_ips[count.index]
    ssh_private_key    = filemd5(pathexpand(var.ssh_private_key_path))
    docker_install_rev = "1"
  }

  connection {
    type             = "ssh"
    host             = local.all_ips[count.index]
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
    manager_ip          = local.manager_ip
    ssh_private_key_md5 = filemd5(pathexpand(var.ssh_private_key_path))
    manager_ssh_key_rev = "1"
  }

  connection {
    type             = "ssh"
    host             = local.manager_ip
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

resource "null_resource" "init_swarm_manager" {
  count = var.enable_swarm_bootstrap ? 1 : 0

  depends_on = [
    null_resource.install_docker,
    null_resource.manager_ssh_key,
  ]

  triggers = {
    manager_ip        = local.manager_ip
    vm1_ip            = local.vm1_ip
    vm3_ip            = local.vm3_ip
    vm1_name          = local.vm1_name
    vm2_name          = local.vm2_name
    vm3_name          = local.vm3_name
    init_swarm_script = filesha256("${path.module}/scripts/bootstrap/init-swarm-manager.sh.tftpl")
  }

  connection {
    type             = "ssh"
    host             = local.manager_ip
    user             = local.ssh_user
    private_key      = file(pathexpand(var.ssh_private_key_path))
    timeout          = "15m"
    bastion_host     = local.openwrt_host
    bastion_user     = "root"
    bastion_password = var.openwrt_password
  }

  provisioner "file" {
    content = templatefile("${path.module}/scripts/bootstrap/init-swarm-manager.sh.tftpl", {
      manager_ip                  = local.manager_ip
      manager_ssh_key_remote_path = local.manager_ssh_key_remote_path
      ssh_user                    = local.ssh_user
      vm1_ip                      = local.vm1_ip
      vm3_ip                      = local.vm3_ip
      vm1_name                    = local.vm1_name
      vm2_name                    = local.vm2_name
      vm3_name                    = local.vm3_name
    })
    destination = "/tmp/init-swarm-manager.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/init-swarm-manager.sh",
      "bash /tmp/init-swarm-manager.sh",
    ]
  }
}

resource "null_resource" "prepare_repo" {
  count = var.enable_repo_prepare ? 1 : 0

  depends_on = [
    null_resource.manager_ssh_key,
    null_resource.init_swarm_manager,
  ]

  triggers = {
    repo_url            = var.nebula_repo_url
    repo_path           = local.nebula_repo_path
    manager_ip          = local.manager_ip
    app_ip              = local.vm1_ip
    prepare_repo_script = filesha256("${path.module}/scripts/bootstrap/prepare-repos.sh.tftpl")
  }

  connection {
    type             = "ssh"
    host             = local.manager_ip
    user             = local.ssh_user
    private_key      = file(pathexpand(var.ssh_private_key_path))
    timeout          = "15m"
    bastion_host     = local.openwrt_host
    bastion_user     = "root"
    bastion_password = var.openwrt_password
  }

  provisioner "file" {
    content = templatefile("${path.module}/scripts/bootstrap/prepare-repos.sh.tftpl", {
      app_ip                      = local.vm1_ip
      manager_ssh_key_remote_path = local.manager_ssh_key_remote_path
      repo_path                   = local.nebula_repo_path
      repo_url                    = var.nebula_repo_url
      ssh_user                    = local.ssh_user
    })
    destination = "/tmp/prepare-repos.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/prepare-repos.sh",
      "bash /tmp/prepare-repos.sh",
    ]
  }
}

resource "null_resource" "build_app_images_vm1" {
  count = var.enable_app_image_build ? 1 : 0

  depends_on = [
    null_resource.manager_ssh_key,
    null_resource.prepare_repo,
  ]

  triggers = {
    app_ip              = local.vm1_ip
    repo_path           = local.nebula_repo_path
    build_images_script = filesha256("${path.module}/scripts/bootstrap/build-images-vm1.sh.tftpl")
  }

  lifecycle {
    precondition {
      condition     = var.enable_repo_prepare
      error_message = "Active aussi enable_repo_prepare avant d'activer enable_app_image_build."
    }
  }

  connection {
    type             = "ssh"
    host             = local.manager_ip
    user             = local.ssh_user
    private_key      = file(pathexpand(var.ssh_private_key_path))
    timeout          = "15m"
    bastion_host     = local.openwrt_host
    bastion_user     = "root"
    bastion_password = var.openwrt_password
  }

  provisioner "file" {
    content = templatefile("${path.module}/scripts/bootstrap/build-images-vm1.sh.tftpl", {
      app_ip                      = local.vm1_ip
      manager_ssh_key_remote_path = local.manager_ssh_key_remote_path
      repo_path                   = local.nebula_repo_path
      ssh_user                    = local.ssh_user
    })
    destination = "/tmp/build-images-vm1.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/build-images-vm1.sh",
      "bash /tmp/build-images-vm1.sh",
    ]
  }
}

resource "null_resource" "deploy_nebula_vm2" {
  count = var.enable_nebula_deploy ? 1 : 0

  depends_on = [
    null_resource.init_swarm_manager,
    null_resource.prepare_repo,
    null_resource.build_app_images_vm1,
  ]

  triggers = {
    repo_path              = local.nebula_repo_path
    manager_name           = local.vm2_name
    app_name               = local.vm1_name
    data_name              = local.vm3_name
    postgres_password_hash = nonsensitive(sha256(var.nebula_postgres_password))
    deploy_nebula_script   = filesha256("${path.module}/scripts/bootstrap/deploy-nebula-vm2.sh.tftpl")
  }

  lifecycle {
    precondition {
      condition     = var.enable_swarm_bootstrap
      error_message = "Active aussi enable_swarm_bootstrap avant d'activer enable_nebula_deploy."
    }

    precondition {
      condition     = var.enable_repo_prepare
      error_message = "Active aussi enable_repo_prepare avant d'activer enable_nebula_deploy."
    }

    precondition {
      condition     = var.enable_app_image_build
      error_message = "Active aussi enable_app_image_build avant d'activer enable_nebula_deploy."
    }

    precondition {
      condition     = var.nebula_postgres_password != ""
      error_message = "Definis TF_VAR_nebula_postgres_password avant d'activer enable_nebula_deploy."
    }
  }

  connection {
    type             = "ssh"
    host             = local.manager_ip
    user             = local.ssh_user
    private_key      = file(pathexpand(var.ssh_private_key_path))
    timeout          = "15m"
    bastion_host     = local.openwrt_host
    bastion_user     = "root"
    bastion_password = var.openwrt_password
  }

  provisioner "file" {
    content = templatefile("${path.module}/scripts/bootstrap/deploy-nebula-vm2.sh.tftpl", {
      app_name              = local.vm1_name
      data_name             = local.vm3_name
      manager_name          = local.vm2_name
      postgres_password_b64 = base64encode(var.nebula_postgres_password)
      repo_path             = local.nebula_repo_path
    })
    destination = "/tmp/deploy-nebula-vm2.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/deploy-nebula-vm2.sh",
      "bash /tmp/deploy-nebula-vm2.sh",
    ]
  }
}

resource "null_resource" "deploy_monitoring_vm2" {
  count = var.enable_monitoring_deploy ? 1 : 0

  depends_on = [
    null_resource.deploy_nebula_vm2,
  ]

  triggers = {
    repo_path                = local.nebula_repo_path
    grafana_admin_hash       = nonsensitive(sha256(var.grafana_admin_password))
    grafana_root_url         = "http://${local.manager_ip}/grafana"
    deploy_monitoring_script = filesha256("${path.module}/scripts/bootstrap/deploy-monitoring-vm2.sh.tftpl")
  }

  lifecycle {
    precondition {
      condition     = var.grafana_admin_password != ""
      error_message = "Definis TF_VAR_grafana_admin_password avant d'activer enable_monitoring_deploy."
    }

    precondition {
      condition     = var.enable_nebula_deploy
      error_message = "Active aussi enable_nebula_deploy avant d'activer enable_monitoring_deploy."
    }
  }

  connection {
    type             = "ssh"
    host             = local.manager_ip
    user             = local.ssh_user
    private_key      = file(pathexpand(var.ssh_private_key_path))
    timeout          = "15m"
    bastion_host     = local.openwrt_host
    bastion_user     = "root"
    bastion_password = var.openwrt_password
  }

  provisioner "file" {
    content = templatefile("${path.module}/scripts/bootstrap/deploy-monitoring-vm2.sh.tftpl", {
      grafana_password_b64 = base64encode(var.grafana_admin_password)
      grafana_root_url     = "http://${local.manager_ip}/grafana"
      repo_path            = local.nebula_repo_path
    })
    destination = "/tmp/deploy-monitoring-vm2.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/deploy-monitoring-vm2.sh",
      "bash /tmp/deploy-monitoring-vm2.sh",
    ]
  }
}
