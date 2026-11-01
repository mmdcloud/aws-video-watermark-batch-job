# ==============================================================================
# Production Configuration Variables: Media Watermarking Pipeline on AWS Batch
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. Project & Environment Identity
# ------------------------------------------------------------------------------
project_name = "media-watermark"
environment  = "prod"

tags = {
  Project     = "media-watermark"
  Environment = "prod"
  ManagedBy   = "Terraform"
  Owner       = "PlatformEngineering"
}

# ------------------------------------------------------------------------------
# 2. AWS Region & VPC Networking
# ------------------------------------------------------------------------------
region   = "us-east-1"
vpc_name = "media-watermark-vpc"
vpc_cidr = "10.0.0.0/16"

azs             = ["us-east-1a", "us-east-1b", "us-east-1c"]
public_subnets  = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
private_subnets = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]

# Cost-optimized NAT Gateway: single NAT across AZs
enable_nat_gateway = true
single_nat_gateway = true

# S3 Gateway VPC Endpoint: Routes all S3 traffic privately at zero data fee
enable_s3_endpoint = true

# ------------------------------------------------------------------------------
# 3. Amazon S3 Storage
# ------------------------------------------------------------------------------
source_bucket_prefix      = "source-bucket"
destination_bucket_prefix = "destination-bucket"
lambda_code_bucket_prefix = "job-submit-code"

# Safety: prevent accidental data loss in production
s3_force_destroy      = false
s3_versioning_enabled = "Enabled"

# ------------------------------------------------------------------------------
# 4. Amazon SQS & Event Buffering
# ------------------------------------------------------------------------------
sqs_queue_name                 = "job-queue"
sqs_visibility_timeout_seconds = 180
sqs_message_retention_seconds  = 345600  # 4 days
sqs_max_receive_count          = 3       # Route to DLQ after 3 failed attempts
sqs_dlq_retention_seconds      = 1209600 # 14 days retention in DLQ
sqs_batch_size                 = 10
sqs_batch_window_seconds       = 5

# ------------------------------------------------------------------------------
# 5. Amazon DynamoDB State Tracking
# ------------------------------------------------------------------------------
dynamodb_table_name         = "media-watermark-records"
dynamodb_billing_mode       = "PAY_PER_REQUEST"
dynamodb_ttl_attribute_name = "TimeToExist"
dynamodb_ttl_enabled        = true
dynamodb_pitr_enabled       = true # Continuous point-in-time recovery

# ------------------------------------------------------------------------------
# 6. AWS Lambda Orchestrator
# ------------------------------------------------------------------------------
lambda_function_name = "watermark-job-submit"
lambda_runtime       = "python3.12"
lambda_timeout       = 30
lambda_memory_size   = 256

default_watermark_text     = "CONFIDENTIAL"
default_watermark_type     = "text"
default_watermark_position = "bottom-right"
default_watermark_opacity  = "0.8"

# ------------------------------------------------------------------------------
# 7. AWS Batch & Fargate Compute
# ------------------------------------------------------------------------------
batch_compute_environment_name = "batch-compute"
batch_job_queue_name           = "batch-job-queue"
batch_job_definition_name      = "batch-job-definition"

batch_max_vcpus            = 16
batch_default_vcpu         = "2.0"
batch_default_memory       = "4096"
batch_ephemeral_storage_gb = 50 # 50 GiB disk for high-bitrate video
batch_log_retention_days   = 14

ecr_repository_name      = "batch_job"
ecr_image_tag_mutability = "MUTABLE"
ecr_scan_on_push         = true

# ------------------------------------------------------------------------------
# 8. Operational Alarms (CloudWatch)
# ------------------------------------------------------------------------------
enable_alarms            = true
alarm_evaluation_periods = 1
alarm_period_seconds     = 60

