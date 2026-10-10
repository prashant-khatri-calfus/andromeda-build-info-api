# Dedicated, user-managed SA for CI instead of the legacy Cloud Build SA.
resource "google_service_account" "cloudbuild" {
  account_id   = "${var.name}-cloudbuild"
  display_name = "Cloud Build deployer (${var.name})"
}

locals {
  cloudbuild_project_roles = [
    "roles/logging.logWriter",   # write build logs
    "roles/container.developer", # get-credentials + apply workloads (incl. clusters.connect for DNS endpoint)
  ]
}

resource "google_project_iam_member" "cloudbuild" {
  for_each = toset(local.cloudbuild_project_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.cloudbuild.email}"
}

# Push rights scoped to the single repository, not project-wide.
resource "google_artifact_registry_repository_iam_member" "cloudbuild_writer" {
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.cloudbuild.email}"
}

# Push-to-main trigger. Gated because connecting GitHub to Cloud Build is a
# one-time manual OAuth/App install step.
resource "google_cloudbuild_trigger" "deploy" {
  count = var.create_build_trigger ? 1 : 0

  name            = "${var.name}-deploy-${var.environment}"
  location        = "global"
  description     = "Test, build, push and deploy build-info-api on push to ${var.deploy_branch_regex}"
  filename        = "cloudbuild.yaml"
  service_account = google_service_account.cloudbuild.id

  github {
    owner = var.github_owner
    name  = var.github_repo
    push {
      branch = var.deploy_branch_regex
    }
  }

  # Only rebuild when something that affects the artifact or its deployment changes.
  included_files = ["src/**", "test/**", "package.json", "package-lock.json", "Dockerfile", "k8s/**", "cloudbuild.yaml", "VERSION"]

  substitutions = {
    _REGION      = var.region
    _CLUSTER     = google_container_cluster.autopilot.name
    _REPO        = google_artifact_registry_repository.images.repository_id
    _ENVIRONMENT = var.environment
  }
}
