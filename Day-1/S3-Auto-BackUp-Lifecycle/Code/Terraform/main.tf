# Terraform Blueprint for Day 1: Production Hardened S3 Bucket with Lifecycle & Archival

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region for deployment"
}

variable "environment" {
  type        = string
  default     = "production"
  description = "Environment name"
}

# Generate unique suffix for S3 Bucket Name
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# 1. Primary Hardened S3 Backup Bucket
resource "aws_s3_bucket" "backup_bucket" {
  bucket        = "saasflow-backup-logs-${var.environment}-${random_id.bucket_suffix.hex}"
  force_destroy = false

  tags = {
    Name        = "Production Backup Logs Bucket"
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = "365-Days-Cloud-Automation"
  }
}

# 2. Enable S3 Bucket Versioning (Ransomware & Accidental Deletion Protection)
resource "aws_s3_bucket_versioning" "backup_bucket_versioning" {
  bucket = aws_s3_bucket.backup_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

# 3. Enforce Server-Side Encryption (AES256)
resource "aws_s3_bucket_server_side_encryption_configuration" "backup_bucket_crypto" {
  bucket = aws_s3_bucket.backup_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 4. Block All Public Access (Security Hardening)
resource "aws_s3_bucket_public_access_block" "public_block" {
  bucket = aws_s3_bucket.backup_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 5. Automated S3 Lifecycle Policy (Multi-Tier Archival & Cleanup)
resource "aws_s3_bucket_lifecycle_configuration" "backup_lifecycle" {
  depends_on = [aws_s3_bucket_versioning.backup_bucket_versioning]
  bucket     = aws_s3_bucket.backup_bucket.id

  rule {
    id     = "auto-archival-and-cleanup-rule"
    status = "Enabled"

    # Transition current objects to Glacier Instant Retrieval after 30 days
    transition {
      days          = 30
      storage_class = "GLACIER_IR"
    }

    # Transition to Glacier Deep Archive after 90 days (Lowest Cost Tier)
    transition {
      days          = 90
      storage_class = "DEEP_ARCHIVE"
    }

    # Noncurrent (Previous) Versions Lifecycle
    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "GLACIER_IR"
    }

    noncurrent_version_expiration {
      noncurrent_days = 365
    }

    # Auto-Clean incomplete multipart uploads after 7 days (Cost Optimization)
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# 6. SNS Topic for Compliance Notifications
resource "aws_sns_topic" "compliance_alerts" {
  name = "s3-compliance-alerts-${var.environment}"
}

output "s3_bucket_name" {
  value       = aws_s3_bucket.backup_bucket.id
  description = "The created production S3 bucket name"
}

output "sns_topic_arn" {
  value       = aws_sns_topic.compliance_alerts.arn
  description = "SNS Topic ARN for alerts"
}
