# Dedicated VPC rather than "default": explicit, non-overlapping ranges and
# nothing else living in it.
resource "google_compute_network" "vpc" {
  name                    = "${var.name}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  depends_on = [google_project_service.this]
}

resource "google_compute_subnetwork" "gke" {
  name          = "${var.name}-${var.region}"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = var.subnet_cidr

  # Private nodes reach Google APIs (Artifact Registry, Logging) without public IPs.
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Nodes have no external IPs; Cloud NAT gives them controlled outbound
# internet access (e.g. pulling public images) without being reachable inbound.
resource "google_compute_router" "router" {
  name    = "${var.name}-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.name}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# Reserved regional IP for the Service's external passthrough Network LB.
# Keeps the endpoint stable across Service re-creation; referenced by name
# from the Service annotation `networking.gke.io/load-balancer-ip-addresses`.
# NOTE: with the default var.name this is "build-info-api-ip" - keep k8s/base/service.yaml in sync.
resource "google_compute_address" "api" {
  name         = "${var.name}-api-ip"
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"
}
