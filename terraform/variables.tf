# ==============================================================================
# Production Terraform Variables: Media Watermarking Pipeline on AWS Batch
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. Project & Environment Identity
# ------------------------------------------------------------------------------
variable "project_name" {
  description = "Name of the project used for resource naming and tagging"
  type        = string
  default     = "media-watermark"
}

variable "environment" {
  description = "Target deployment environment (e.g., prod, staging, dev)"
  type        = string
  default     = "prod"
}

variable "tags" {
  description = "Common resource tags applied across all infrastructure resources"
  type        = map(string)
  default = {
    Project     = "media-watermark"
    Environment = "prod"
    ManagedBy   = "Terraform"
  }
}

# ------------------------------------------------------------------------------
# 2. AWS Provider & Networking (VPC)
# ------------------------------------------------------------------------------
variable "region" {
  description = "The AWS region to deploy resources in"
  type        = string
  default     = "us-east-1"
}

variable "vpc_name" {
  description = "Name of the VPC"
  type        = string
  default     = "media-watermark-vpc"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "Availability Zones for multi-AZ subnet deployment"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "public_subnets" {
  description = "Public Subnet CIDR blocks (Internet Gateway egress)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnets" {
  description = "Private Subnet CIDR blocks (Lambda ENIs & Batch Fargate workers)"
  type        = list(string)
  default     = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]
}

variable "enable_nat_gateway" {
  description = "Provision NAT Gateway for private subnet outbound internet access (disabled in Option 2 pure PrivateLink architecture)"
  type        = bool
  default     = false
}

variable "single_nat_gateway" {
  description = "Use a single NAT Gateway across all AZs to optimize costs"
  type        = bool
  default     = false
}

variable "enable_s3_endpoint" {
  description = "Enable S3 Gateway VPC Endpoint to avoid NAT Gateway data transfer charges and enable private ECR layer pulls"
  type        = bool
  default     = true
}

variable "enable_dynamodb_endpoint" {
  description = "Enable DynamoDB Gateway VPC Endpoint for zero-cost private access"
  type        = bool
  default     = true
}

variable "enable_vpc_interface_endpoints" {
  description = "Enable VPC Interface Endpoints (PrivateLink) for ECR API, ECR DKR, and CloudWatch Logs to allow Fargate tasks in private subnets to run without a NAT Gateway"
  type        = bool
  default     = true
}

variable "enable_batch_endpoint" {
  description = "Enable AWS Batch Interface Endpoint (only needed if Lambda or internal compute is inside the VPC)"
  type        = bool
  default     = false
}

# ------------------------------------------------------------------------------
# 3. Storage (S3)
# ------------------------------------------------------------------------------
variable "source_bucket_prefix" {
  description = "Prefix for the source media uploads S3 bucket"
  type        = string
  default     = "source-bucket"
}

variable "destination_bucket_prefix" {
  description = "Prefix for the watermarked output media S3 bucket"
  type        = string
  default     = "destination-bucket"
}

variable "lambda_code_bucket_prefix" {
  description = "Prefix for the Lambda deployment artifact S3 bucket"
  type        = string
  default     = "job-submit-code"
}

variable "s3_force_destroy" {
  description = "Whether to force destroy media S3 buckets containing objects (keep false in prod)"
  type        = bool
  default     = false
}

variable "s3_versioning_enabled" {
  description = "Versioning status for S3 buckets (Enabled or Suspended)"
  type        = string
  default     = "Enabled"
}

variable "s3_cors_max_age_seconds" {
  description = "CORS preflight request cache duration in seconds"
  type        = number
  default     = 3000
}

# ------------------------------------------------------------------------------
# 4. Queuing & Event Buffering (SQS)
# ------------------------------------------------------------------------------
variable "sqs_queue_name" {
  description = "Name of the main ingestion SQS queue"
  type        = string
  default     = "job-queue"
}

variable "sqs_visibility_timeout_seconds" {
  description = "SQS visibility timeout in seconds (must be >= Lambda timeout)"
  type        = number
  default     = 180
}

variable "sqs_message_retention_seconds" {
  description = "SQS message retention period in seconds (default 4 days)"
  type        = number
  default     = 345600
}

variable "sqs_max_receive_count" {
  description = "Number of times a message is delivered before sending to the Dead Letter Queue"
  type        = number
  default     = 3
}

variable "sqs_dlq_retention_seconds" {
  description = "Dead Letter Queue message retention period in seconds (default 14 days)"
  type        = number
  default     = 1209600
}

variable "sqs_receive_wait_time_seconds" {
  description = "Long polling wait duration for receive message calls in seconds"
  type        = number
  default     = 20
}

variable "sqs_max_message_size" {
  description = "Maximum message size in bytes for the SQS queue"
  type        = number
  default     = 262144
}

variable "sqs_batch_size" {
  description = "Maximum number of SQS records delivered to Lambda per batch invocation"
  type        = number
  default     = 10
}

variable "sqs_batch_window_seconds" {
  description = "Maximum batching window in seconds for SQS to Lambda event source mapping"
  type        = number
  default     = 5
}

# ------------------------------------------------------------------------------
# 5. State Tracking (DynamoDB)
# ------------------------------------------------------------------------------
variable "dynamodb_table_name" {
  description = "Name of the DynamoDB table tracking job metadata and execution state"
  type        = string
  default     = "media-watermark-records"
}

variable "dynamodb_billing_mode" {
  description = "DynamoDB billing mode (PAY_PER_REQUEST or PROVISIONED)"
  type        = string
  default     = "PAY_PER_REQUEST"
}

variable "dynamodb_ttl_attribute_name" {
  description = "Name of the DynamoDB TTL timestamp attribute"
  type        = string
  default     = "TimeToExist"
}

variable "dynamodb_ttl_enabled" {
  description = "Enable automated item expiration via TTL on the DynamoDB state table"
  type        = bool
  default     = true
}

variable "dynamodb_pitr_enabled" {
  description = "Enable Point-In-Time Recovery for continuous automated backups"
  type        = bool
  default     = true
}

# ------------------------------------------------------------------------------
# 6. Ingestion & Orchestration (Lambda)
# ------------------------------------------------------------------------------
variable "enable_lambda_vpc" {
  description = "Whether to place the Lambda orchestrator inside the VPC (defaults to false for serverless direct AWS API routing without NAT or ENI overhead)"
  type        = bool
  default     = false
}

variable "lambda_function_name" {
  description = "Name of the job submission Lambda function"
  type        = string
  default     = "watermark-job-submit"
}

variable "lambda_runtime" {
  description = "Python runtime for the Lambda function"
  type        = string
  default     = "python3.12"
}

variable "lambda_timeout" {
  description = "Timeout in seconds for the Lambda function"
  type        = number
  default     = 30
}

variable "lambda_memory_size" {
  description = "Memory allocation in MB for the Lambda function"
  type        = number
  default     = 256
}

variable "default_watermark_text" {
  description = "Default text overlay applied when no text is explicitly specified"
  type        = string
  default     = "CONFIDENTIAL"
}

variable "default_watermark_type" {
  description = "Default watermark mode: text, image, or both"
  type        = string
  default     = "text"
}

variable "default_watermark_position" {
  description = "Default position for the watermark overlay"
  type        = string
  default     = "bottom-right"
}

variable "default_watermark_opacity" {
  description = "Default watermark opacity from 0.0 (transparent) to 1.0 (opaque)"
  type        = string
  default     = "0.8"
}

# ------------------------------------------------------------------------------
# 7. AWS Batch & Container Compute
# ------------------------------------------------------------------------------
variable "batch_compute_environment_name" {
  description = "Name of the AWS Batch managed Fargate compute environment"
  type        = string
  default     = "batch-compute"
}

variable "batch_job_queue_name" {
  description = "Name of the AWS Batch job queue"
  type        = string
  default     = "batch-job-queue"
}

variable "batch_job_definition_name" {
  description = "Name of the AWS Batch job definition"
  type        = string
  default     = "batch-job-definition"
}

variable "batch_max_vcpus" {
  description = "Maximum vCPUs the Batch compute environment can scale up to"
  type        = number
  default     = 16
}

variable "batch_default_vcpu" {
  description = "Default vCPUs allocated to the Batch container task definition"
  type        = string
  default     = "2.0"
}

variable "batch_default_memory" {
  description = "Default memory in MiB allocated to the Batch container task definition"
  type        = string
  default     = "4096"
}

variable "batch_ephemeral_storage_gb" {
  description = "Ephemeral storage in GiB allocated to the Fargate container task (21-200 GiB)"
  type        = number
  default     = 50
}

variable "batch_log_retention_days" {
  description = "CloudWatch log retention period in days for AWS Batch container logs"
  type        = number
  default     = 14
}

variable "ecr_repository_name" {
  description = "Name of the Amazon ECR container repository"
  type        = string
  default     = "batch_job"
}

variable "ecr_image_tag_mutability" {
  description = "Tag mutability for ECR repository (MUTABLE or IMMUTABLE)"
  type        = string
  default     = "MUTABLE"
}

variable "ecr_scan_on_push" {
  description = "Enable automated CVE vulnerability scanning on container push"
  type        = bool
  default     = true
}

# ------------------------------------------------------------------------------
# 8. CloudWatch Alarms & Monitoring
# ------------------------------------------------------------------------------
variable "enable_alarms" {
  description = "Whether to provision operational CloudWatch metric alarms"
  type        = bool
  default     = true
}

variable "alarm_evaluation_periods" {
  description = "Evaluation periods before triggering CloudWatch alarms"
  type        = number
  default     = 1
}

variable "alarm_period_seconds" {
  description = "Period in seconds over which the alarm statistic is applied"
  type        = number
  default     = 60
}
