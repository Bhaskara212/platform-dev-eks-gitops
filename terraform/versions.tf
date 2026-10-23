terraform {
  required_version = ">= 1.5.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.95"
    }
  }

  # Remote state (recommended even for PoC). Copy backend.tf.example -> backend.tf and fill in.
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "platform"
      Environment = "dev"
      ManagedBy   = "terraform"
      Cluster     = var.cluster_name
    }
  }
}
