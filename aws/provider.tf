terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "aws_profile" {
  default = "moodle-aws"
}

provider "aws" {
  region  = "ap-southeast-1"
  profile = var.aws_profile
}