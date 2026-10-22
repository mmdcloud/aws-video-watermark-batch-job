# S3 Bucket
resource "aws_s3_bucket" "bucket" {
  bucket        = var.bucket_name
  force_destroy = var.force_destroy
  tags = merge(
    {
      Name = var.bucket_name
    },
    var.tags
  )
}

# Creating object
resource "aws_s3_object" "object" {
  count  = length(var.objects)
  bucket = aws_s3_bucket.bucket.id
  source = var.objects[count.index].source
  key    = var.objects[count.index].key
}

# Bucket versioning configuration
resource "aws_s3_bucket_versioning" "versioning" {
  bucket = aws_s3_bucket.bucket.id
  versioning_configuration {
    status = var.versioning_enabled
  }
}

# Bucket cors configuration
resource "aws_s3_bucket_cors_configuration" "cors" {
  bucket = aws_s3_bucket.bucket.id
  dynamic "cors_rule" {
    for_each = var.cors
    content {
      allowed_headers = cors_rule.value["allowed_headers"]
      allowed_methods = cors_rule.value["allowed_methods"]
      allowed_origins = cors_rule.value["allowed_origins"]
      max_age_seconds = cors_rule.value["max_age_seconds"]
    }
  }
}

# Bucket policy
resource "aws_s3_bucket_policy" "bucket_policy" {
  count  = var.bucket_policy != "" ? 1 : 0
  bucket = aws_s3_bucket.bucket.id
  policy = var.bucket_policy
}

# Specifying bucket notification configuration
resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.bucket.bucket
  dynamic "queue" {
    for_each = var.bucket_notification.queue
    content {
      queue_arn = queue.value["queue_arn"]
      events    = queue.value["events"]
    }
  }
  dynamic "lambda_function" {
    for_each = var.bucket_notification.lambda_function
    content {
      lambda_function_arn = lambda_function.value["lambda_function_arn"]
      events              = lambda_function.value["events"]
    }
  }
}

resource "aws_s3_bucket_public_access_block" "public_access_block" {
  bucket = aws_s3_bucket.bucket.id

  block_public_acls       = var.block_public_acls
  block_public_policy     = var.block_public_policy
  ignore_public_acls      = var.ignore_public_acls
  restrict_public_buckets = var.restrict_public_buckets
}

# resource "aws_s3_bucket_lifecycle_configuration" "lifecyle_policy" {
#   bucket = aws_s3_bucket.bucket.id
#   count  = length(var.lifecycle_policies) > 0 ? 1 : 0    
#   dynamic "rule" {
#     for_each = var.lifecycle_policies[count.index].rules
#     content {
#       id     = rule.value.id
#       status = rule.value.status

#       dynamic "filter" {
#         for_each = rule.value.filter != null ? [rule.value.filter] : []
#         content {
#           prefix = filter.value.prefix
#         }
#       }

#       dynamic "transition" {
#         for_each = rule.value.transition != null ? [rule.value.transition] : []
#         content {
#           days          = transition.value.days
#           storage_class = transition.value.storage_class
#         }
#       }

#       dynamic "noncurrent_version_transition" {
#         for_each = rule.value.noncurrent_version_transition != null ? [rule.value.noncurrent_version_transition] : []
#         content {
#           noncurrent_days          = noncurrent_version_transition.value.days
#           storage_class = noncurrent_version_transition.value.storage_class
#         }
#       }

#       dynamic "expiration" {
#         for_each = rule.value.expiration != null ? [rule.value.expiration] : []
#         content {
#           days = expiration.value.days
#         }
#       }

#       dynamic "noncurrent_version_expiration" {
#         for_each = rule.value.noncurrent_version_expiration != null ? [rule.value.noncurrent_version_expiration] : []
#         content {
#           noncurrent_days = noncurrent_version_expiration.value.days
#         }
#       }

#       dynamic "abort_incomplete_multipart_upload" {
#         for_each = rule.value.abort_incomplete_multipart_upload != null ? [rule.value.abort_incomplete_multipart_upload] : []
#         content {
#           days_after_initiation = abort_incomplete_multipart_upload.value.days_after_initiation
#         }
#       }
#     }
#   }
# }
