terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.12"
    }
  }

  # Remote state in GCS (versioned bucket, state locking built in).
  # Bucket is created once out-of-band (see README "Bootstrap"), then:
  #   terraform init -backend-config="bucket=<PROJECT_ID>-tfstate"
  backend "gcs" {
    prefix = "build-info-api"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = {
    app        = "build-info-api"
    managed-by = "terraform"
    env        = var.environment
  }
}
