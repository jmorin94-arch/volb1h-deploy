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
# -1 = automatic: the first availability domain that offers `shape` (Ashburn has 3 ADs and the Always Free
# micro shape lives in only one of them). 0/1/2 forces that AD.
variable "availability_domain_index" {
  default = -1
}
# Support only: leave empty for the sealed box the setup page describes. A public key here opens SSH (port 22).
variable "ssh_public_key" {
  default   = ""
  sensitive = false
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
    cat > /etc/volb1h/deploy_key.blob <<'BLOB'
    ${try(local.setup.deploy_key_blob, "")}
    BLOB
    cat > /etc/volb1h/deploy_key.full <<'KEY'
    ${try(local.setup.deploy_key, "")}
    KEY
    python3 - <<'PY'
    import base64, struct, os
    def s(b): return struct.pack(">I", len(b)) + b
    blob = open("/etc/volb1h/deploy_key.blob").read().strip()
    full = open("/etc/volb1h/deploy_key.full").read().strip()
    if blob:
        sk = base64.urlsafe_b64decode(blob + "=" * (-len(blob) % 4)); pub = sk[32:]
        chk = os.urandom(4)
        priv = chk + chk + s(b"ssh-ed25519") + s(pub) + s(sk) + s(b"volb1h")
        pad = 1
        while len(priv) % 8: priv += bytes([pad]); pad += 1
        raw = b"openssh-key-v1\0" + s(b"none") + s(b"none") + s(b"") + struct.pack(">I", 1) + s(s(b"ssh-ed25519") + s(pub)) + s(priv)
        b64 = base64.b64encode(raw).decode()
        full = "-----BEGIN OPENSSH PRIVATE KEY-----\n" + "\n".join(b64[i:i+70] for i in range(0, len(b64), 70)) + "\n-----END OPENSSH PRIVATE KEY-----"
    open("/etc/volb1h/deploy_key", "w").write(full + "\n")
    PY
    rm -f /etc/volb1h/deploy_key.blob /etc/volb1h/deploy_key.full
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

data "oci_core_shapes" "per_ad" {
  count               = length(data.oci_identity_availability_domains.ads.availability_domains)
  compartment_id      = var.compartment_ocid
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[count.index].name
}

locals {
  ad_names       = [for a in data.oci_identity_availability_domains.ads.availability_domains : a.name]
  ads_with_shape = [for i, n in local.ad_names : n if contains([for s in data.oci_core_shapes.per_ad[i].shapes : s.name], var.shape)]
  ad = (var.availability_domain_index >= 0 ? local.ad_names[var.availability_domain_index] :
        length(local.ads_with_shape) > 0 ? local.ads_with_shape[0] : local.ad_names[0])
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
  dynamic "ingress_security_rules" {
    for_each = var.ssh_public_key == "" ? [] : [1]
    content {
      source   = "0.0.0.0/0"
      protocol = "6"
      tcp_options {
        min = 22
        max = 22
      }
    }
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
  availability_domain = local.ad
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
  metadata = merge(
    { user_data = base64encode(local.cloud_init) },
    var.ssh_public_key == "" ? {} : { ssh_authorized_keys = var.ssh_public_key }
  )
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
