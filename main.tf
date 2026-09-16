# VOLB1H one-click stack for Oracle Cloud Resource Manager ("Deploy to Oracle Cloud" button).
# Creates a small network and one Always Free VM, and hands the VM the same cloud-init text START.html would
# generate. No secrets live in this stack: everything personal arrives in `setup_code` (one pasted string).
terraform {
  required_version = ">= 1.2"
  required_providers {
    oci = { source = "oracle/oci" }
  }
}

variable "tenancy_ocid" {}
variable "region" {}
variable "compartment_ocid" {}
variable "setup_code" {
  description = "The setup code from your VOLB1H setup page (one long line)."
  type        = string
  sensitive   = true
}
variable "shape" {
  default = "VM.Standard.E2.1.Micro"
}
variable "availability_domain_index" {
  default = 0
}

locals {
  setup      = jsondecode(base64decode(trimspace(var.setup_code)))
  config     = jsonencode({
    tradier_token  = local.setup.tradier_token
    telegram_token = local.setup.telegram_token
    pair_code      = tostring(local.setup.pair_code)
    size_frac      = try(local.setup.size_frac, 0.6)
  })
  cloud_init = <<-EOT
    #!/bin/bash
    # VOLB1H one-time server setup (Resource Manager stack). Runs once as root on first boot.
    mkdir -p /etc/volb1h && chmod 750 /etc/volb1h
    cat > /etc/volb1h/config.json <<'JSON'
    ${local.config}
    JSON
    cat > /etc/volb1h/deploy_key <<'KEY'
    ${local.setup.deploy_key}
    KEY
    chmod 600 /etc/volb1h/deploy_key /etc/volb1h/config.json
    export DEBIAN_FRONTEND=noninteractive
    for i in 1 2 3 4 5; do apt-get update -q && apt-get install -y -q git && break; sleep 20; done
    GIT_SSH_COMMAND="ssh -i /etc/volb1h/deploy_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" \
      git clone -q ${local.setup.repo} /opt/volb1h
    bash /opt/volb1h/install/install.sh
  EOT
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

data "oci_core_images" "ubuntu" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = var.shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_vcn" "vcn" {
  compartment_id = var.compartment_ocid
  display_name   = "volb1h-vcn"
  cidr_blocks    = ["10.0.0.0/16"]
  dns_label      = "volb1h"
}

resource "oci_core_internet_gateway" "igw" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vcn.id
  display_name   = "volb1h-igw"
}

resource "oci_core_route_table" "rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vcn.id
  display_name   = "volb1h-rt"
  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.igw.id
  }
}

# Sealed box: the server can reach the internet; nothing can reach the server.
resource "oci_core_security_list" "sl" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vcn.id
  display_name   = "volb1h-sealed"
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }
}

resource "oci_core_subnet" "subnet" {
  compartment_id    = var.compartment_ocid
  vcn_id            = oci_core_vcn.vcn.id
  display_name      = "volb1h-subnet"
  cidr_block        = "10.0.0.0/24"
  dns_label         = "bot"
  route_table_id    = oci_core_route_table.rt.id
  security_list_ids = [oci_core_security_list.sl.id]
}

resource "oci_core_instance" "bot" {
  compartment_id      = var.compartment_ocid
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[var.availability_domain_index].name
  display_name        = "volb1h"
  shape               = var.shape

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.ubuntu.images[0].id
  }
  create_vnic_details {
    subnet_id        = oci_core_subnet.subnet.id
    assign_public_ip = true
    display_name     = "volb1h-vnic"
  }
  metadata = {
    user_data = base64encode(local.cloud_init)
  }
  lifecycle {
    ignore_changes = [source_details, metadata]
  }
}

output "public_ip" {
  value = oci_core_instance.bot.public_ip
}
output "next_step" {
  value = "Open Telegram and send your 4-digit code to your bot. It replies within about 10 minutes."
}
