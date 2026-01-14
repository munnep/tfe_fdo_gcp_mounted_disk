resource "google_compute_network" "tfe_vpc" {
  name                    = "${var.tag_prefix}-vpc"
  auto_create_subnetworks = false
}


resource "google_compute_subnetwork" "tfe_subnet" {
  name          = "${var.tag_prefix}-public1"
  ip_cidr_range = cidrsubnet(var.vnet_cidr, 8, 1)
  network       = google_compute_network.tfe_vpc.self_link
}

resource "google_compute_router" "tfe_router" {
  name    = "${var.tag_prefix}-router"
  network = google_compute_network.tfe_vpc.self_link
}


data "google_compute_image" "ubuntu" {
  family  = "ubuntu-2404-lts-amd64"
  project = "ubuntu-os-cloud"
}

data "google_compute_image" "redhat" {
  family  = "rhel-9"
  project = "rhel-cloud"
}

locals {
  os_user = var.tfe_os == "redhat" ? "cloud-user" : "ubuntu"
}


resource "google_compute_instance" "tfe" {
  name         = var.tag_prefix
  machine_type = "n2-standard-8"
  zone         = "${var.gcp_region}-a"



  boot_disk {
    initialize_params {
      image = var.tfe_os == "ubuntu" ? data.google_compute_image.ubuntu.self_link : data.google_compute_image.redhat.self_link
    }
  }

  // Local SSD disk
  scratch_disk {
    interface = "NVME"
  }

  network_interface {
    network    = "${var.tag_prefix}-vpc"
    subnetwork = "${var.tag_prefix}-public1"

    access_config {
      // Ephemeral public IP
      nat_ip = google_compute_address.tfe-public-ipc.address
    }
  }

  metadata = {
    "ssh-keys" = "${local.os_user}:${var.public_key}"
    "user-data" = templatefile("${path.module}/scripts/cloudinit_tfe_server_${var.tfe_os}.yaml", {
      tag_prefix        = var.tag_prefix
      dns_hostname      = var.dns_hostname
      tfe_password      = var.tfe_password
      dns_zonename      = var.dns_zonename
      tfe_release       = var.tfe_release
      tfe_license       = var.tfe_license
      certificate_email = var.certificate_email
      full_chain        = base64encode("${acme_certificate.certificate.certificate_pem}${acme_certificate.certificate.issuer_pem}")
      private_key_pem   = base64encode(lookup(acme_certificate.certificate, "private_key_pem"))
    })
  }

  metadata_startup_script = var.tfe_os == "redhat" ? file("${path.module}/scripts/startup_wrapper_redhat.sh") : null

  depends_on = [google_compute_subnetwork.tfe_subnet]

  lifecycle {
    ignore_changes = [ attached_disk ]
  }
}

resource "google_compute_address" "tfe-public-ipc" {
  name         = "${var.tag_prefix}-public-ip"
  address_type = "EXTERNAL"
}

resource "google_compute_disk" "compute_disk_swap" {
  name = "${var.tag_prefix}-swap-disk"
  type = "pd-ssd"
  size = "10"
  zone = "${var.gcp_region}-a"
}

resource "google_compute_disk" "compute_disk_docker" {
  name = "${var.tag_prefix}-docker-disk"
  type = "pd-ssd"
  size = "20"
  zone = "${var.gcp_region}-a"
}

resource "google_compute_disk" "compute_disk_tfe_data" {
  name = "${var.tag_prefix}-tfe-data-disk"
  type = "pd-ssd"
  size = "40"
  zone = "${var.gcp_region}-a"
}

resource "google_compute_attached_disk" "swap" {
  disk     = google_compute_disk.compute_disk_swap.id
  instance = google_compute_instance.tfe.id
}

resource "google_compute_attached_disk" "docker" {
  disk     = google_compute_disk.compute_disk_docker.id
  instance = google_compute_instance.tfe.id
}

resource "google_compute_attached_disk" "tfe_data" {
  disk     = google_compute_disk.compute_disk_tfe_data.id
  instance = google_compute_instance.tfe.id
}

resource "google_compute_firewall" "default" {
  name    = "test-firewall"
  network = google_compute_network.tfe_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22", "443"]
  }

  source_ranges = ["0.0.0.0/0"]
}
