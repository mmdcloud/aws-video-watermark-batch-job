# ==============================================================================
# Production-Grade Reusable EventBridge Module: Rule, Targets & Permissions
# ==============================================================================

# Optional Custom Event Bus
resource "aws_cloudwatch_event_bus" "this" {
  count = var.create_event_bus ? 1 : 0
  name  = var.event_bus_name
  tags  = var.tags
}

# EventBridge Event Rule
resource "aws_cloudwatch_event_rule" "this" {
  count = var.create_rule ? 1 : 0

  name                = var.name
  name_prefix         = var.name_prefix
  description         = var.description
  event_bus_name      = var.create_event_bus ? aws_cloudwatch_event_bus.this[0].name : var.event_bus_name
  event_pattern       = var.event_pattern
  schedule_expression = var.schedule_expression
  state               = var.state
  role_arn            = var.role_arn

  tags = merge(
    var.name != null ? { Name = var.name } : {},
    var.tags
  )
}

# EventBridge Event Targets
resource "aws_cloudwatch_event_target" "this" {
  for_each = var.create_rule ? var.targets : {}

  rule           = aws_cloudwatch_event_rule.this[0].name
  event_bus_name = var.create_event_bus ? aws_cloudwatch_event_bus.this[0].name : var.event_bus_name
  target_id      = coalesce(each.value.target_id, each.key)
  arn            = each.value.arn
  role_arn       = each.value.role_arn
  input          = each.value.input
  input_path     = each.value.input_path

  dynamic "input_transformer" {
    for_each = each.value.input_transformer != null ? [each.value.input_transformer] : []
    content {
      input_paths    = input_transformer.value.input_paths
      input_template = input_transformer.value.input_template
    }
  }

  dynamic "retry_policy" {
    for_each = each.value.retry_policy != null ? [each.value.retry_policy] : []
    content {
      maximum_event_age_in_seconds = retry_policy.value.maximum_event_age_in_seconds
      maximum_retry_attempts       = retry_policy.value.maximum_retry_attempts
    }
  }

  dynamic "dead_letter_config" {
    for_each = each.value.dead_letter_config != null ? [each.value.dead_letter_config] : []
    content {
      arn = dead_letter_config.value.arn
    }
  }
}

# Optional Automatic Lambda Permission for Lambda Targets
resource "aws_lambda_permission" "this" {
  for_each = {
    for k, v in(var.create_rule ? var.targets : {}) : k => v
    if try(v.attach_lambda_permission, false)
  }

  statement_id  = coalesce(each.value.statement_id, "AllowExecutionFromEventBridge-${each.key}")
  action        = "lambda:InvokeFunction"
  function_name = coalesce(each.value.lambda_function_name, each.value.arn)
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.this[0].arn
}
