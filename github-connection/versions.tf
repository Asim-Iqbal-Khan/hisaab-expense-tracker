terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.24.0, < 7.0.0"
    }
  }

  # Deliberately separate state from envs/prod — this connection's GitHub
  # OAuth authorization is a one-time, human-in-the-console step (AWS gives
  # no API/Terraform way to complete it). Keeping it out of envs/prod's
  # state means a `terraform destroy` + `terraform apply` cycle on the main
  # environment never needs that manual re-authorization again.
  backend "s3" {
    bucket         = "hisaab-tfstate"
    key            = "github-connection/terraform.tfstate"
    region         = "us-west-2"
    dynamodb_table = "hisaab-tfstate-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}
