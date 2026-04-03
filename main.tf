locals {
  node_name       = "airbus4"
  pool_id         = "lefevret"
  template_vm_id  = 100000
  bridge          = "vn00009"
  vm_datastore_id = "airbus-LUN1"
  ssh_user        = "ubuntu"
  ssh_public_key  = trimspace(file(pathexpand("~/.ssh/id_ed25519.pub")))

  subnet_cidr   = "10.100.9.0/24"
  subnet_prefix = 24
  gateway_ip    = "10.100.9.254"
  dns_servers   = [local.gateway_ip, "1.1.1.1"]
  vm1_ip_host   = 230
  vm2_ip_host   = 219
  vm3_ip_host   = 231
  vm1_ip        = cidrhost(local.subnet_cidr, local.vm1_ip_host)
  vm2_ip        = cidrhost(local.subnet_cidr, local.vm2_ip_host)
  vm3_ip        = cidrhost(local.subnet_cidr, local.vm3_ip_host)
  vm1_ipv4_cidr = "${local.vm1_ip}/${local.subnet_prefix}"
  vm2_ipv4_cidr = "${local.vm2_ip}/${local.subnet_prefix}"
  vm3_ipv4_cidr = "${local.vm3_ip}/${local.subnet_prefix}"
  all_ips       = [local.vm1_ip, local.vm2_ip, local.vm3_ip]

  vm_definitions = {
    vm1 = {
      name      = "vm1-lefevret"
      ipv4_cidr = local.vm1_ipv4_cidr
    }
    vm2 = {
      name      = "vm2-lefevret"
      ipv4_cidr = local.vm2_ipv4_cidr
    }
    vm3 = {
      name      = "vm3-lefevret"
      ipv4_cidr = local.vm3_ipv4_cidr
    }
  }
}

resource "proxmox_virtual_environment_vm" "ubuntu_vm" {
  for_each  = local.vm_definitions
  name      = each.value.name
  node_name = local.node_name
  pool_id   = local.pool_id

  clone {
    vm_id = local.template_vm_id
    full  = true
  }

  cpu {
    cores = 4
  }

  memory {
    dedicated = 2048
  }

  disk {
    datastore_id = local.vm_datastore_id
    interface    = "scsi0"
    size         = 40
  }

  initialization {
    datastore_id = local.vm_datastore_id

    dns {
      servers = local.dns_servers
    }

    ip_config {
      ipv4 {
        address = each.value.ipv4_cidr
        gateway = local.gateway_ip
      }
    }

    user_account {
      username = local.ssh_user
      keys     = [local.ssh_public_key]
    }
  }

  network_device {
    bridge = local.bridge
    model  = "virtio"
  }
}

moved {
  from = proxmox_virtual_environment_vm.first_vm
  to   = proxmox_virtual_environment_vm.ubuntu_vm["vm1"]
}

moved {
  from = proxmox_virtual_environment_vm.second_vm
  to   = proxmox_virtual_environment_vm.ubuntu_vm["vm2"]
}

moved {
  from = proxmox_virtual_environment_vm.third_vm
  to   = proxmox_virtual_environment_vm.ubuntu_vm["vm3"]
}
