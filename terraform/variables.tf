variable "project_id" {
  description = "GCP project to deploy into."
  type        = string
}

variable "region" {
  description = "Region for the cluster, subnet, registry and LB IP."
  type        = string
  default     = "asia-south1"
}

variable "environment" {
  description = "Environment name, used in labels and resource names."
  type        = string
  default     = "dev"
}

variable "name" {
  description = "Base name for resources."
  type        = string
  default     = "build-info"
}

# --- Networking -----------------------------------------------------------

variable "subnet_cidr" {
  description = "Primary range for nodes."
  type        = string
  default     = "10.10.0.0/20"
}

variable "pods_cidr" {
  description = "Secondary range for Pods (VPC-native)."
  type        = string
  default     = "10.20.0.0/16"
}

variable "services_cidr" {
  description = "Secondary range for ClusterIP Services."
  type        = string
  default     = "10.30.0.0/20"
}

variable "admin_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the control plane's IP endpoint (e.g. your office/VPN).
    CI does NOT need to be in here - Cloud Build uses the IAM-authenticated DNS endpoint.
  EOT
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
}

# --- CI/CD ----------------------------------------------------------------

variable "create_build_trigger" {
  description = "Create the Cloud Build push trigger. Requires the Cloud Build GitHub App to be installed on the repo first (one-time, manual)."
  type        = bool
  default     = false
}

variable "github_owner" {
  description = "GitHub user/org that owns the repository."
  type        = string
  default     = ""
}

variable "github_repo" {
  description = "GitHub repository name."
  type        = string
  default     = "build-info-api"
}

variable "deploy_branch_regex" {
  description = "Branches whose pushes build and deploy."
  type        = string
  default     = "^main$"
}

variable "deletion_protection" {
  description = "Protect the cluster from accidental terraform destroy. Set false for throwaway demo envs."
  type        = bool
  default     = true
}
