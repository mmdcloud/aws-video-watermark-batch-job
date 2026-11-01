output "job_queue_arn" {
  value = aws_batch_job_queue.batch_job_queue.arn
}

output "job_definition_arn" {
  value = aws_batch_job_definition.batch_job_definition.arn
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
  value       = module.job_queue.dlq_name
  description = "SQS Dead Letter Queue buffering poison messages"
}

output "sqs_dlq_url" {
  value       = module.job_queue.dlq_url
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
  value       = aws_batch_job_queue.batch_job_queue.name
  description = "Name of the AWS Batch job queue"
}

output "batch_job_definition_name" {
  value       = aws_batch_job_definition.batch_job_definition.name
  description = "Name of the AWS Batch job definition"
}
