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

output "dynamodb_table_name" {
  value       = module.job_metadata_state.name
  description = "DynamoDB table tracking media job state and metadata"
}

output "ecr_repository_url" {
  value       = module.ecr.repository_url
  description = "ECR repository URL hosting the Batch container image"
}
