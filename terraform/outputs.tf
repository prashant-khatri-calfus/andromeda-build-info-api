output "cluster_name" {
  value = google_container_cluster.autopilot.name
}

output "get_credentials_command" {
  description = "Connect kubectl via the IAM-authenticated DNS endpoint."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.autopilot.name} --region ${var.region} --project ${var.project_id} --dns-endpoint"
}

output "image_repository" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}/build-info-api"
}

output "api_ip" {
  description = "Static external IP the LoadBalancer Service binds to."
  value       = google_compute_address.api.address
}

output "api_url" {
  value = "http://${google_compute_address.api.address}/build-info"
}

output "cloudbuild_service_account" {
  value = google_service_account.cloudbuild.email
}
