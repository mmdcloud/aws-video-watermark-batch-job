data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

# SQS queue (supports both Standard and FIFO queues)
resource "aws_sqs_queue" "queue" {
  name                       = var.queue_name
  delay_seconds              = var.delay_seconds
  max_message_size           = var.max_message_size
  message_retention_seconds  = var.message_retention_seconds
  visibility_timeout_seconds = var.visibility_timeout_seconds
  receive_wait_time_seconds  = var.receive_wait_time_seconds
  redrive_policy             = var.redrive_policy

  # Encryption (KMS CMK takes precedence over SQS-managed SSE)
  sqs_managed_sse_enabled           = var.kms_master_key_id == null ? var.sqs_managed_sse_enabled : null
  kms_master_key_id                 = var.kms_master_key_id
  kms_data_key_reuse_period_seconds = var.kms_master_key_id != null ? var.kms_data_key_reuse_period_seconds : null

  # FIFO configuration (FIFO-only attributes remain null for Standard queues)
  fifo_queue                  = var.fifo_queue
  content_based_deduplication = var.fifo_queue ? var.content_based_deduplication : null
  deduplication_scope         = var.fifo_queue ? var.deduplication_scope : null
  fifo_throughput_limit       = var.fifo_queue ? var.fifo_throughput_limit : null

  tags = merge(
    {
      Name = var.queue_name
    },
    var.tags
  )

  lifecycle {
    precondition {
      condition     = var.fifo_queue ? endswith(var.queue_name, ".fifo") : !endswith(var.queue_name, ".fifo")
      error_message = "FIFO queues (fifo_queue = true) must have a queue_name ending in '.fifo', and Standard queues (fifo_queue = false) must not end in '.fifo'."
    }

    precondition {
      condition     = var.fifo_queue || (var.deduplication_scope == null && var.fifo_throughput_limit == null && !var.content_based_deduplication)
      error_message = "FIFO-only settings (content_based_deduplication, deduplication_scope, fifo_throughput_limit) cannot be set when fifo_queue = false."
    }

    precondition {
      condition     = var.fifo_throughput_limit != "perMessageGroupId" || var.deduplication_scope == "messageGroup"
      error_message = "High-throughput FIFO (fifo_throughput_limit = 'perMessageGroupId') requires deduplication_scope = 'messageGroup'."
    }
  }
}

# Build generic IAM policy document for SQS queue policy
data "aws_iam_policy_document" "queue_policy_document" {
  count = (var.policy != null && var.policy != "") || var.enforce_tls || length(var.queue_policy_statements) > 0 ? 1 : 0

  source_policy_documents = (var.policy != null && var.policy != "") ? [var.policy] : []

  dynamic "statement" {
    for_each = var.enforce_tls ? [1] : []
    content {
      sid     = "EnforceTLSRequestsOnly"
      effect  = "Deny"
      actions = ["sqs:*"]

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      resources = [aws_sqs_queue.queue.arn]

      condition {
        test     = "Bool"
        variable = "aws:SecureTransport"
        values   = ["false"]
      }
    }
  }

  dynamic "statement" {
    for_each = var.queue_policy_statements
    content {
      sid       = statement.value.sid
      effect    = statement.value.effect
      actions   = statement.value.actions
      resources = try(length(statement.value.resources) > 0, false) ? statement.value.resources : [aws_sqs_queue.queue.arn]

      dynamic "principals" {
        for_each = statement.value.principals
        content {
          type        = principals.value.type
          identifiers = principals.value.identifiers
        }
      }

      dynamic "condition" {
        for_each = statement.value.conditions
        content {
          test     = condition.value.test
          variable = condition.value.variable
          values   = condition.value.values
        }
      }
    }
  }
}

# SQS queue policy resource
resource "aws_sqs_queue_policy" "queue_policy" {
  count     = length(data.aws_iam_policy_document.queue_policy_document) > 0 ? 1 : 0
  queue_url = aws_sqs_queue.queue.url
  policy    = data.aws_iam_policy_document.queue_policy_document[0].json
}

# SQS queue redrive allow policy resource (for Dead Letter Queues)
resource "aws_sqs_queue_redrive_allow_policy" "redrive_allow" {
  count     = (var.redrive_allow_policy != null && var.redrive_allow_policy != "") || var.redrive_permission != null ? 1 : 0
  queue_url = aws_sqs_queue.queue.url
  redrive_allow_policy = (var.redrive_allow_policy != null && var.redrive_allow_policy != "") ? var.redrive_allow_policy : (
    var.redrive_permission == "byQueue" ? jsonencode({
      redrivePermission = "byQueue"
      sourceQueueArns = concat(
        var.redrive_allow_source_queue_arns,
        [for name in var.redrive_allow_source_queue_names : "arn:${data.aws_partition.current.partition}:sqs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${name}"]
      )
      }) : jsonencode({
      redrivePermission = var.redrive_permission
    })
  )

  lifecycle {
    precondition {
      condition = (
        (var.redrive_allow_policy != null && var.redrive_allow_policy != "") ||
        var.redrive_permission != "byQueue" ||
        (length(var.redrive_allow_source_queue_arns) + length(var.redrive_allow_source_queue_names)) > 0
      )
      error_message = "When redrive_permission is 'byQueue', at least one source queue ARN or name must be provided."
    }

    precondition {
      condition = !var.fifo_queue || alltrue(concat(
        [for arn in var.redrive_allow_source_queue_arns : endswith(arn, ".fifo")],
        [for name in var.redrive_allow_source_queue_names : endswith(name, ".fifo")]
      ))
      error_message = "A FIFO DLQ (fifo_queue = true) can only allow FIFO source queues ending in '.fifo'."
    }

    precondition {
      condition = var.fifo_queue || alltrue(concat(
        [for arn in var.redrive_allow_source_queue_arns : !endswith(arn, ".fifo")],
        [for name in var.redrive_allow_source_queue_names : !endswith(name, ".fifo")]
      ))
      error_message = "A Standard DLQ (fifo_queue = false) cannot allow FIFO source queues ending in '.fifo'."
    }
  }
}
