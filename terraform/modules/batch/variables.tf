variable "project_name" {
  description = "Project name prefix for resources and roles"
  type        = string
  default     = "media-watermark"
}

variable "compute_environment_name" {
  description = "Name of the AWS Batch compute environment"
  type        = string
  default     = "batch-compute"
}

variable "job_queue_name" {
  description = "Name of the AWS Batch job queue"
  type        = string
  default     = "batch-job-queue"
}

variable "job_queue_state" {
  description = "State of the job queue (ENABLED or DISABLED)"
  type        = string
  default     = "ENABLED"

  validation {
    condition     = contains(["ENABLED", "DISABLED"], var.job_queue_state)
    error_message = "Valid values for job_queue_state are 'ENABLED' or 'DISABLED'."
  }
}

variable "job_queue_priority" {
  description = "Priority of the job queue (higher integer = higher priority)"
  type        = number
  default     = 1
}

variable "job_definition_name" {
  description = "Name of the AWS Batch job definition"
  type        = string
  default     = "batch-job-definition"
}

variable "compute_type" {
  description = "Compute environment type: FARGATE or FARGATE_SPOT"
  type        = string
  default     = "FARGATE"
}

variable "platform_capabilities" {
  description = "Platform capabilities required by the job definition (e.g. ['FARGATE'] or ['EC2'])"
  type        = list(string)
  default     = ["FARGATE"]
}

variable "max_vcpus" {
  description = "Maximum vCPUs the compute environment can scale up to"
  type        = number
  default     = 16
}

variable "subnets" {
  description = "List of VPC subnet IDs where Batch tasks will execute"
  type        = list(string)
}

variable "security_group_ids" {
  description = "List of Security Group IDs associated with Batch compute tasks"
  type        = list(string)
}

variable "container_image" {
  description = "Container image URI in Amazon ECR"
  type        = string
}

variable "container_command" {
  description = "Command array passed to the container"
  type        = list(string)
  default     = []
}

variable "container_environment" {
  description = "Environment variables for the container definition"
  type = list(object({
    name  = string
    value = string
  }))
  default = []
}

variable "default_vcpu" {
  description = "Default vCPUs allocated to container task"
  type        = string
  default     = "2.0"
}

variable "default_memory" {
  description = "Default memory in MiB allocated to container task"
  type        = string
  default     = "4096"
}

variable "ephemeral_storage_gb" {
  description = "Ephemeral storage in GiB for Fargate container task (21-200 GiB)"
  type        = number
  default     = 50
}

variable "assign_public_ip" {
  description = "Whether to assign a public IP to container tasks: ENABLED or DISABLED"
  type        = string
  default     = "DISABLED"
}

variable "log_group_name" {
  description = "Name of CloudWatch Log Group for Batch container logs"
  type        = string
  default     = null
}

variable "log_retention_days" {
  description = "Retention period in days for CloudWatch logs"
  type        = number
  default     = 14
}

variable "log_stream_prefix" {
  description = "Prefix for CloudWatch log streams"
  type        = string
  default     = "batch"
}

variable "region" {
  description = "AWS Region where logs and resources are deployed"
  type        = string
  default     = null
}

variable "source_bucket_arns" {
  description = "List of S3 bucket ARNs that the batch container task is authorized to read from (GetObject, ListBucket)"
  type        = list(string)
  default     = []
}

variable "destination_bucket_arns" {
  description = "List of S3 bucket ARNs that the batch container task is authorized to write to (PutObject, AbortMultipartUpload)"
  type        = list(string)
  default     = []
}

variable "custom_task_policy_statements" {
  description = "Additional IAM policy statements to attach to the container task job role"
  type        = list(any)
  default     = []
}

variable "create_service_role" {
  description = "Whether to create the AWS Batch service role"
  type        = bool
  default     = true
}

variable "service_role_arn" {
  description = "Existing IAM role ARN for AWS Batch service (required if create_service_role is false)"
  type        = string
  default     = null
}

variable "create_execution_role" {
  description = "Whether to create the ECS task execution role (ECR image pull, CloudWatch logs)"
  type        = bool
  default     = true
}

variable "execution_role_arn" {
  description = "Existing IAM role ARN for ECS task execution (required if create_execution_role is false)"
  type        = string
  default     = null
}

variable "create_job_role" {
  description = "Whether to create the container task job role (runtime application permissions)"
  type        = bool
  default     = true
}

variable "job_role_arn" {
  description = "Existing IAM role ARN for container task job (required if create_job_role is false)"
  type        = string
  default     = null
}

variable "tags" {
  description = "Common resource tags applied across all Batch resources"
  type        = map(string)
  default     = {}
}
