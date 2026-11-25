output "compute_environment_name" {
  description = "Name of the AWS Batch compute environment"
  value       = aws_batch_compute_environment.batch_compute.name
}

output "compute_environment_arn" {
  description = "ARN of the AWS Batch compute environment"
  value       = aws_batch_compute_environment.batch_compute.arn
}

output "job_queue_name" {
  description = "Name of the AWS Batch job queue"
  value       = aws_batch_job_queue.batch_job_queue.name
}

output "job_queue_arn" {
  description = "ARN of the AWS Batch job queue"
  value       = aws_batch_job_queue.batch_job_queue.arn
}

output "scheduling_policy_name" {
  description = "Name of the AWS Batch scheduling policy"
  value       = try(aws_batch_scheduling_policy.batch_scheduling_policy[0].name, null)
}

output "scheduling_policy_arn" {
  description = "ARN of the AWS Batch scheduling policy"
  value       = local.scheduling_policy_arn
}

output "job_definition_name" {
  description = "Name of the AWS Batch job definition"
  value       = aws_batch_job_definition.batch_job_definition.name
}

output "job_definition_arn" {
  description = "ARN of the AWS Batch job definition"
  value       = aws_batch_job_definition.batch_job_definition.arn
}

output "job_definition_revision" {
  description = "Revision number of the AWS Batch job definition"
  value       = aws_batch_job_definition.batch_job_definition.revision
}

output "batch_service_role_arn" {
  description = "ARN of the IAM role used by the AWS Batch service"
  value       = local.batch_service_role_arn
}

output "execution_role_arn" {
  description = "ARN of the ECS task execution role"
  value       = local.execution_role_arn
}

output "job_role_arn" {
  description = "ARN of the container task application job role"
  value       = local.job_role_arn
}

output "log_group_name" {
  description = "Name of the CloudWatch Log Group for Batch jobs"
  value       = aws_cloudwatch_log_group.batch_logs.name
}

output "log_group_arn" {
  description = "ARN of the CloudWatch Log Group for Batch jobs"
  value       = aws_cloudwatch_log_group.batch_logs.arn
}
