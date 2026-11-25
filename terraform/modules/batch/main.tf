data "aws_region" "current" {}

locals {
  region         = var.region != null ? var.region : data.aws_region.current.region
  log_group_name = var.log_group_name != null ? var.log_group_name : "/aws/batch/${var.job_definition_name}"
}

# ------------------------------------------------------------------------------
# 1. CloudWatch Log Group for AWS Batch
# ------------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "batch_logs" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

# ------------------------------------------------------------------------------
# 2. IAM Service Role for AWS Batch
# ------------------------------------------------------------------------------
data "aws_iam_policy_document" "batch_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["batch.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "aws_batch_service_role" {
  count              = var.create_service_role ? 1 : 0
  name               = "${var.project_name}-batch-service-role"
  assume_role_policy = data.aws_iam_policy_document.batch_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "aws_batch_service_role" {
  count      = var.create_service_role ? 1 : 0
  role       = aws_iam_role.aws_batch_service_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole"
}

locals {
  batch_service_role_arn = var.create_service_role ? aws_iam_role.aws_batch_service_role[0].arn : var.service_role_arn
}

# ------------------------------------------------------------------------------
# 3. AWS Batch Compute Environment
# ------------------------------------------------------------------------------
resource "aws_batch_compute_environment" "batch_compute" {
  name = var.compute_environment_name
  type = "MANAGED"

  compute_resources {
    max_vcpus          = var.max_vcpus
    security_group_ids = var.security_group_ids
    subnets            = var.subnets
    type               = var.compute_type
  }

  service_role = local.batch_service_role_arn
  depends_on   = [aws_iam_role_policy_attachment.aws_batch_service_role]
  tags         = var.tags
}

# ------------------------------------------------------------------------------
# 4. AWS Batch Scheduling Policy (Optional Fair Share Scheduling)
# ------------------------------------------------------------------------------
locals {
  scheduling_policy_name = var.scheduling_policy_name != null ? var.scheduling_policy_name : "${var.project_name}-scheduling-policy"
}

resource "aws_batch_scheduling_policy" "batch_scheduling_policy" {
  count = var.create_scheduling_policy ? 1 : 0

  name = local.scheduling_policy_name

  dynamic "fair_share_policy" {
    for_each = var.fair_share_policy != null ? [var.fair_share_policy] : []
    content {
      compute_reservation = try(fair_share_policy.value.compute_reservation, null)
      share_decay_seconds = try(fair_share_policy.value.share_decay_seconds, null)

      dynamic "share_distribution" {
        for_each = try(fair_share_policy.value.share_distribution, [])
        content {
          share_identifier = share_distribution.value.share_identifier
          weight_factor    = try(share_distribution.value.weight_factor, null)
        }
      }
    }
  }

  tags = var.tags
}

locals {
  scheduling_policy_arn = var.create_scheduling_policy ? aws_batch_scheduling_policy.batch_scheduling_policy[0].arn : var.scheduling_policy_arn
}

# ------------------------------------------------------------------------------
# 5. AWS Batch Job Queue
# ------------------------------------------------------------------------------
resource "aws_batch_job_queue" "batch_job_queue" {
  name                  = var.job_queue_name
  state                 = var.job_queue_state
  priority              = var.job_queue_priority
  scheduling_policy_arn = local.scheduling_policy_arn

  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.batch_compute.arn
  }

  tags = var.tags
}

# ------------------------------------------------------------------------------
# 5. ECS Task Execution Role (Pulling images from ECR, sending logs to CloudWatch)
# ------------------------------------------------------------------------------
data "aws_iam_policy_document" "ecs_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_task_execution_role" {
  count              = var.create_execution_role ? 1 : 0
  name               = "${var.project_name}-ecs-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role_policy.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  count      = var.create_execution_role ? 1 : 0
  role       = aws_iam_role.ecs_task_execution_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy_attachment" "ecr_registry_role_policy" {
  count      = var.create_execution_role ? 1 : 0
  role       = aws_iam_role.ecs_task_execution_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

locals {
  execution_role_arn = var.create_execution_role ? aws_iam_role.ecs_task_execution_role[0].arn : var.execution_role_arn
}

# ------------------------------------------------------------------------------
# 6. Container Task Job Role (Runtime application permissions with tightly scoped blast radius)
# ------------------------------------------------------------------------------
resource "aws_iam_role" "batch_job_role" {
  count              = var.create_job_role ? 1 : 0
  name               = "${var.project_name}-task-job-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role_policy.json
  tags               = var.tags
}

locals {
  has_source_buckets = length(var.source_bucket_arns) > 0
  has_dest_buckets   = length(var.destination_bucket_arns) > 0
  has_custom_stmts   = length(var.custom_task_policy_statements) > 0
  create_task_policy = var.create_job_role && (local.has_source_buckets || local.has_dest_buckets || local.has_custom_stmts)

  source_resources = flatten([
    for arn in var.source_bucket_arns : [arn, "${arn}/*"]
  ])

  dest_resources = [
    for arn in var.destination_bucket_arns : "${arn}/*"
  ]
}

data "aws_iam_policy_document" "task_permissions" {
  count = local.create_task_policy ? 1 : 0

  dynamic "statement" {
    for_each = local.has_source_buckets ? [1] : []
    content {
      sid     = "ReadSourceBucket"
      effect  = "Allow"
      actions = ["s3:GetObject", "s3:ListBucket"]
      resources = local.source_resources
    }
  }

  dynamic "statement" {
    for_each = local.has_dest_buckets ? [1] : []
    content {
      sid     = "WriteDestinationBucket"
      effect  = "Allow"
      actions = [
        "s3:PutObject",
        "s3:AbortMultipartUpload"
      ]
      resources = local.dest_resources
    }
  }

  dynamic "statement" {
    for_each = var.custom_task_policy_statements
    content {
      sid       = try(statement.value.sid, null)
      effect    = try(statement.value.effect, "Allow")
      actions   = statement.value.actions
      resources = statement.value.resources
      dynamic "condition" {
        for_each = try(statement.value.condition, [])
        content {
          test     = condition.value.test
          variable = condition.value.variable
          values   = condition.value.values
        }
      }
    }
  }
}

resource "aws_iam_role_policy" "batch_job_task_policy" {
  count  = local.create_task_policy ? 1 : 0
  name   = "${var.project_name}-batch-job-task-policy"
  role   = aws_iam_role.batch_job_role[0].id
  policy = data.aws_iam_policy_document.task_permissions[0].json
}

locals {
  job_role_arn = var.create_job_role ? aws_iam_role.batch_job_role[0].arn : var.job_role_arn
}

# ------------------------------------------------------------------------------
# 7. AWS Batch Job Definition
# ------------------------------------------------------------------------------
resource "aws_batch_job_definition" "batch_job_definition" {
  name                  = var.job_definition_name
  type                  = "container"
  platform_capabilities = var.platform_capabilities

  container_properties = jsonencode({
    image            = var.container_image
    command          = length(var.container_command) > 0 ? var.container_command : null
    environment      = var.container_environment
    jobRoleArn       = local.job_role_arn
    executionRoleArn = local.execution_role_arn

    fargatePlatformConfiguration = {
      platformVersion = "LATEST"
    }

    resourceRequirements = [
      { type = "VCPU", value = var.default_vcpu },
      { type = "MEMORY", value = var.default_memory }
    ]

    ephemeralStorage = {
      sizeInGiB = var.ephemeral_storage_gb
    }

    networkConfiguration = {
      assignPublicIp = var.assign_public_ip
    }

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.batch_logs.name
        "awslogs-region"        = local.region
        "awslogs-stream-prefix" = var.log_stream_prefix
      }
    }
  })

  depends_on = [aws_cloudwatch_log_group.batch_logs]
  tags       = var.tags
}