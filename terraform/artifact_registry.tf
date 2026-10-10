resource "google_artifact_registry_repository" "images" {
  repository_id = "${var.name}-images"
  location      = var.region
  format        = "DOCKER"
  description   = "Container images for build-info-api"

  # Keep the registry from growing forever: always keep the 10 newest
  # versions (KEEP wins over DELETE), delete anything else older than 30 days,
  # and drop untagged layers after a week.
  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }

  cleanup_policies {
    id     = "delete-old"
    action = "DELETE"
    condition {
      tag_state  = "ANY"
      older_than = "2592000s"
    }
  }

  cleanup_policies {
    id     = "delete-untagged"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "604800s"
    }
  }

  depends_on = [google_project_service.this]
}

# Nodes may only *read* from this one repository.
resource "google_artifact_registry_repository_iam_member" "nodes_reader" {
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.nodes.email}"
}
