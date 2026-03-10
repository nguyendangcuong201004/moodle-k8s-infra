terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Cấu hình AWS Provider
provider "aws" {
  region = "ap-southeast-1" 
}