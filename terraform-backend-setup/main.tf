terraform {
  # This configuration will use a local backend by default
  # (no backend "s3" block here for the initial run)
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1" # Specify the region where you want to create the state bucket
}

# Replace this with the name you want for your Terraform state S3 bucket
# It MUST be globally unique.
variable "terraform_state_bucket_name" {
  description = "The globally unique name for the S3 bucket to store Terraform state."
  type        = string
  default     = "ddavid-io-tfstate-20250510" # Use the name we discussed, or your choice
}

resource "aws_s3_bucket" "terraform_state" {
  bucket = var.terraform_state_bucket_name

  # Prevent accidental deletion of this critical bucket
  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name        = "Terraform State Storage"
    Purpose     = "Terraform backend for ddavid.io"
    Environment = "Global" # Or a specific environment if you prefer
  }
}

resource "aws_s3_bucket_versioning" "terraform_state_versioning" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state_encryption" {
  bucket = aws_s3_bucket.terraform_state.bucket # Use .bucket here
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state_public_access_block" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "terraform_state_s3_bucket_name" {
  description = "The name of the S3 bucket created for Terraform state."
  value       = aws_s3_bucket.terraform_state.bucket
}