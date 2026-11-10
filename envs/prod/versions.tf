terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Regional NAT gateway support (availability_mode) requires >= 6.24.0.
      version = ">= 6.24.0, < 7.0.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }

  backend "s3" {
    bucket         = "hisaab-tfstate"
    key            = "envs/prod/terraform.tfstate"
    region         = "us-west-2"
    dynamodb_table = "hisaab-tfstate-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}

# cert-cloudfront must be created here because CloudFront only reads ACM
# certificates from us-east-1, regardless of where the rest of the stack
# lives (spec §3.7). Only modules/network needs this alias passed in.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}
