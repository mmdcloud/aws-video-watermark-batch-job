output "job_queue_arn" {
  value       = module.batch.job_queue_arn
  description = "ARN of the AWS Batch job queue"
}

output "job_definition_arn" {
  value       = module.batch.job_definition_arn
  description = "ARN of the AWS Batch job definition"
}

output "source_bucket_name" {
  value       = module.source_bucket.bucket
  description = "Source S3 bucket for incoming media uploads"
}

output "destination_bucket_name" {
  value       = module.destination_bucket.bucket
  description = "Destination S3 bucket for watermarked output media"
}

output "sqs_queue_name" {
  value       = module.job_queue.name
  description = "SQS queue buffering S3 notification events"
}

output "sqs_dlq_name" {
  value       = module.job_queue_dlq.name
  description = "SQS Dead Letter Queue buffering poison messages"
}

output "sqs_dlq_url" {
  value       = module.job_queue_dlq.url
  description = "URL of the SQS Dead Letter Queue"
}

output "dynamodb_table_name" {
  value       = module.job_metadata_state.name
  description = "DynamoDB table tracking media job state and metadata"
}

output "ecr_repository_url" {
  value       = module.ecr.repository_url
  description = "ECR repository URL hosting the Batch container image"
}

output "vpc_id" {
  value       = module.vpc.vpc_id
  description = "ID of the VPC"
}

output "private_subnet_ids" {
  value       = module.vpc.private_subnets
  description = "IDs of the private subnets where Batch tasks and Lambda ENIs run"
}

output "lambda_function_name" {
  value       = module.job_submit_function.function_name
  description = "Name of the orchestrator Lambda function"
}

output "batch_job_queue_name" {
  value       = module.batch.job_queue_name
  description = "Name of the AWS Batch job queue"
}

output "batch_scheduling_policy_arn" {
  value       = module.batch.scheduling_policy_arn
  description = "ARN of the AWS Batch scheduling policy (if enabled)"
}

output "batch_job_definition_name" {
  value       = module.batch.job_definition_name
  description = "Name of the AWS Batch job definition"
}

output "batch_compute_environment_arn" {
  value       = module.batch.compute_environment_arn
  description = "ARN of the AWS Batch compute environment"
}

output "batch_service_role_arn" {
  value       = module.batch.batch_service_role_arn
  description = "ARN of the AWS Batch service role"
}

output "batch_execution_role_arn" {
  value       = module.batch.execution_role_arn
  description = "ARN of the ECS task execution role"
}

output "batch_job_role_arn" {
  value       = module.batch.job_role_arn
  description = "ARN of the container task application job role"
}

output "batch_log_group_arn" {
  value       = module.batch.log_group_arn
  description = "ARN of the CloudWatch Log Group for Batch jobs"
}

output "sqs_dlq_alarm_arn" {
  value       = try(module.sqs_dlq_alarm[0].arn, null)
  description = "ARN of the SQS Dead Letter Queue CloudWatch metric alarm"
}

output "lambda_errors_alarm_arn" {
  value       = try(module.lambda_errors_alarm[0].arn, null)
  description = "ARN of the Lambda errors CloudWatch metric alarm"
}

output "operational_alarm_arns" {
  value       = { for k, alarm in module.operational_alarms : k => alarm.arn }
  description = "Map of additional operational CloudWatch metric alarm ARNs (SQS age, Lambda throttles/duration, Batch failures, EventBridge failures, DynamoDB throttles)"
}

output "s3_endpoint_id" {
  value       = module.vpc.s3_endpoint_id
  description = "ID of the S3 Gateway VPC Endpoint"
}

output "dynamodb_endpoint_id" {
  value       = module.vpc.dynamodb_endpoint_id
  description = "ID of the DynamoDB Gateway VPC Endpoint"
}

output "ecr_api_endpoint_id" {
  value       = module.vpc.ecr_api_endpoint_id
  description = "ID of the ECR API Interface VPC Endpoint"
}

output "ecr_dkr_endpoint_id" {
  value       = module.vpc.ecr_dkr_endpoint_id
  description = "ID of the ECR DKR Interface VPC Endpoint"
}

output "logs_endpoint_id" {
  value       = module.vpc.logs_endpoint_id
  description = "ID of the CloudWatch Logs Interface VPC Endpoint"
}
