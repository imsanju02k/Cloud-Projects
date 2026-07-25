# Terraform IaC Blueprint: S3 Cross-Region Replication (CRR) with KMS Auto-Encryption

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ------------------------------------------------------------------------------
# 1. AWS Multi-Region Provider Configurations
# ------------------------------------------------------------------------------
provider "aws" {
  alias  = "primary"
  region = var.primary_region
}

provider "aws" {
  alias  = "replica"
  region = var.replica_region
}

variable "primary_region" {
  type    = string
  default = "us-east-1"
}

variable "replica_region" {
  type    = string
  default = "us-west-2"
}

variable "environment" {
  type    = string
  default = "production"
}

# ------------------------------------------------------------------------------
# 2. KMS Customer Managed Keys (CMK) in Primary & Replica Regions
# ------------------------------------------------------------------------------
resource "aws_kms_key" "primary_key" {
  provider                = aws.primary
  description             = "Primary KMS key for S3 compliance data encryption (us-east-1)"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_key" "replica_key" {
  provider                = aws.replica
  description             = "Replica KMS key for S3 compliance data re-encryption (us-west-2)"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

# ------------------------------------------------------------------------------
# 3. S3 Buckets in Primary & Replica Regions with Versioning & KMS Encryption
# ------------------------------------------------------------------------------
resource "aws_s3_bucket" "primary_bucket" {
  provider      = aws.primary
  bucket        = "compliance-primary-data-${var.environment}-east1"
  force_destroy = false
}

resource "aws_s3_bucket_versioning" "primary_versioning" {
  provider = aws.primary
  bucket   = aws_s3_bucket.primary_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "primary_encryption" {
  provider = aws.primary
  bucket   = aws_s3_bucket.primary_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.primary_key.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket" "replica_bucket" {
  provider      = aws.replica
  bucket        = "compliance-replica-dr-${var.environment}-west2"
  force_destroy = false
}

resource "aws_s3_bucket_versioning" "replica_versioning" {
  provider = aws.replica
  bucket   = aws_s3_bucket.replica_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "replica_encryption" {
  provider = aws.replica
  bucket   = aws_s3_bucket.replica_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.replica_key.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

# ------------------------------------------------------------------------------
# 4. IAM Role & Policy for Cross-Region S3 Replication & KMS Decrypt/Encrypt
# ------------------------------------------------------------------------------
resource "aws_iam_role" "replication_role" {
  name = "s3-cross-region-replication-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_policy" "replication_policy" {
  name        = "s3-cross-region-replication-policy-${var.environment}"
  description = "Allows S3 CRR to read primary bucket, decrypt with primary KMS, and write/encrypt with replica KMS"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetReplicationConfiguration",
          "s3:ListBucket"
        ]
        Resource = [aws_s3_bucket.primary_bucket.arn]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObjectVersionForReplication",
          "s3:GetObjectVersionAcl",
          "s3:GetObjectVersionTagging"
        ]
        Resource = ["${aws_s3_bucket.primary_bucket.arn}/*"]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ReplicateObject",
          "s3:ReplicateDelete",
          "s3:ReplicateTags"
        ]
        Resource = ["${aws_s3_bucket.replica_bucket.arn}/*"]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt"
        ]
        Resource = [aws_kms_key.primary_key.arn]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:GenerateDataKey"
        ]
        Resource = [aws_kms_key.replica_key.arn]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "replication_attachment" {
  role       = aws_iam_role.replication_role.name
  policy_arn = aws_iam_policy.replication_policy.arn
}

# ------------------------------------------------------------------------------
# 5. S3 Cross-Region Replication (CRR) Configuration with KMS Re-Encryption
# ------------------------------------------------------------------------------
resource "aws_s3_bucket_replication_configuration" "crr_configuration" {
  provider = aws.primary
  depends_on = [
    aws_s3_bucket_versioning.primary_versioning,
    aws_s3_bucket_versioning.replica_versioning
  ]

  role   = aws_iam_role.replication_role.arn
  bucket = aws_s3_bucket.primary_bucket.id

  rule {
    id     = "MultiRegionKmsReplicationRule"
    status = "Enabled"

    source_selection_criteria {
      sse_kms_encrypted_objects {
        status = "Enabled"
      }
    }

    destination {
      bucket        = aws_s3_bucket.replica_bucket.arn
      storage_class = "STANDARD"

      encryption_configuration {
        replica_kms_key_id = aws_kms_key.replica_key.arn
      }

      metrics {
        status = "Enabled"
        event_threshold {
          minutes = 15
        }
      }

      replication_time {
        status = "Enabled"
        time {
          minutes = 15
        }
      }
    }
  }
}

# ------------------------------------------------------------------------------
# 6. Outputs
# ------------------------------------------------------------------------------
output "primary_bucket_name" {
  value = aws_s3_bucket.primary_bucket.id
}

output "replica_bucket_name" {
  value = aws_s3_bucket.replica_bucket.id
}

output "primary_kms_key_arn" {
  value = aws_kms_key.primary_key.arn
}

output "replica_kms_key_arn" {
  value = aws_kms_key.replica_key.arn
}
