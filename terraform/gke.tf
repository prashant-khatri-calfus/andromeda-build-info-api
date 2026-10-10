# Least-privilege identity for the nodes (instead of the default Compute SA,
# which has project Editor).
resource "google_service_account" "nodes" {
  account_id   = "${var.name}-gke-nodes"
  display_name = "GKE Autopilot node SA (${var.name})"
}

resource "google_project_iam_member" "nodes_default" {
  project = var.project_id
  role    = "roles/container.defaultNodeServiceAccount"
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

resource "google_container_cluster" "autopilot" {
  name     = "${var.name}-${var.environment}"
  location = var.region # regional: control plane + nodes spread across zones

  enable_autopilot    = true
  deletion_protection = var.deletion_protection

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.gke.id

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Nodes get internal IPs only.
  private_cluster_config {
    enable_private_nodes = true
  }

  control_plane_endpoints_config {
    # IAM-authenticated DNS endpoint (container.clusters.connect). This lets
    # Cloud Build's default pool deploy without a private worker pool, VPN or
    # opening the IP endpoint to the internet.
    dns_endpoint_config {
      allow_external_traffic = true
    }
  }

  # The classic IP endpoint is locked to explicit admin CIDRs only
  # (empty list = no public access to the IP endpoint at all).
  master_authorized_networks_config {
    gcp_public_cidrs_access_enabled = false

    dynamic "cidr_blocks" {
      for_each = var.admin_cidrs
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = cidr_blocks.value.display_name
      }
    }
  }

  cluster_autoscaling {
    auto_provisioning_defaults {
      service_account = google_service_account.nodes.email
      oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    }
  }

  release_channel {
    channel = "REGULAR"
  }

  # Upgrades only in a low-traffic window (IST night, weekends).
  maintenance_policy {
    recurring_window {
      start_time = "2026-01-03T18:30:00Z"
      end_time   = "2026-01-03T23:30:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SA,SU"
    }
  }

  depends_on = [
    google_project_service.this,
    google_project_iam_member.nodes_default,
  ]
}
