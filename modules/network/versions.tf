terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Regional NAT gateway support (availability_mode) requires >= 6.24.0.
      version               = ">= 6.24.0, < 7.0.0"
      configuration_aliases = [aws.us_east_1]
    }
  }
}
