terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Deliberately no backend block. This module creates the S3 bucket and
  # DynamoDB table that every other module's backend points at, so it can't
  # use that backend itself. State for bootstrap stays local.
}

provider "aws" {
  region = var.aws_region
}
