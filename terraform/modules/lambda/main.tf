# Lambda Function
resource "aws_lambda_function" "function" {
  function_name = var.function_name
  role          = var.role_arn
  handler       = var.handler
  runtime       = var.runtime
  s3_bucket     = var.s3_bucket
  s3_key        = var.s3_key
  dynamic "dead_letter_config" {
    for_each = var.dead_letter_config == null ? [] : [var.dead_letter_config]
    content {
      target_arn = dead_letter_config.value.target_arn
    }
  }
  dynamic "vpc_config" {
    for_each = var.vpc_config == null ? [] : [var.vpc_config]
    content {
      security_group_ids = vpc_config.value.security_group_ids
      subnet_ids         = vpc_config.value.subnet_ids
    }
  }
  environment {
    variables = var.env_variables
  }
  layers                  = var.layers
  code_signing_config_arn = var.code_signing_config_arn
  tags = merge(
    {
      Name = var.function_name
    },
    var.tags
  )
}

# Granting permissions for lambda
resource "aws_lambda_permission" "lambda_function_permission" {
  count         = length(var.permissions)
  statement_id  = var.permissions[count.index].statement_id
  function_name = aws_lambda_function.function.arn
  action        = var.permissions[count.index].action
  principal     = var.permissions[count.index].principal
  source_arn    = var.permissions[count.index].source_arn
}
