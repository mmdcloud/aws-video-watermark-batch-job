output "vpc_id" {
  value = module.vpc.vpc_id
}

output "public_subnets" {
  value = module.vpc.public_subnets
}

output "private_subnets" {
  value = module.vpc.private_subnets
}

output "s3_endpoint_id" {
  value       = try(aws_vpc_endpoint.s3[0].id, null)
  description = "ID of the S3 Gateway VPC Endpoint"
}

output "dynamodb_endpoint_id" {
  value       = try(aws_vpc_endpoint.dynamodb[0].id, null)
  description = "ID of the DynamoDB Gateway VPC Endpoint"
}

output "ecr_api_endpoint_id" {
  value       = try(aws_vpc_endpoint.ecr_api[0].id, null)
  description = "ID of the ECR API Interface VPC Endpoint"
}

output "ecr_dkr_endpoint_id" {
  value       = try(aws_vpc_endpoint.ecr_dkr[0].id, null)
  description = "ID of the ECR DKR Interface VPC Endpoint"
}

output "logs_endpoint_id" {
  value       = try(aws_vpc_endpoint.logs[0].id, null)
  description = "ID of the CloudWatch Logs Interface VPC Endpoint"
}

output "batch_endpoint_id" {
  value       = try(aws_vpc_endpoint.batch[0].id, null)
  description = "ID of the AWS Batch Interface VPC Endpoint"
}

output "vpc_endpoints_security_group_id" {
  value       = try(aws_security_group.vpc_endpoints[0].id, null)
  description = "Security Group ID attached to the VPC Interface Endpoints"
}
