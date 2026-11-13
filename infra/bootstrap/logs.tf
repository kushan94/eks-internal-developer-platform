# Loki's log storage on EKS. It lives in the bootstrap stack, so logs
# survive the nightly destroy, and expire after 7 days like the backups.
resource "aws_s3_bucket" "logs" {
  bucket = "idp-logs-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Loki's compactor also deletes logs after 7 days. This catches anything it
# misses, such as chunks from a session destroyed before it ran.
resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    id     = "expire-after-7-days"
    status = "Enabled"
    filter {}
    expiration {
      days = 7
    }
  }
}

output "logs_bucket" {
  value = aws_s3_bucket.logs.bucket
}
