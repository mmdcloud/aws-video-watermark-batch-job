# ==============================================================================
# Production AWS Batch Media Watermarking Pipeline: Root Configuration
# ==============================================================================

data "aws_caller_identity" "current" {}

# ------------------------------------------------------------------------------
# 1. IAM Service Role for AWS Batch
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
  name               = "${var.project_name}-batch-service-role"
  assume_role_policy = data.aws_iam_policy_document.batch_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "aws_batch_service_role" {
  role       = aws_iam_role.aws_batch_service_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole"
}

# ------------------------------------------------------------------------------
# 2. VPC & Networking Configuration
# ------------------------------------------------------------------------------
module "vpc" {
  source                     = "./modules/vpc"
  vpc_name                   = var.vpc_name
  vpc_cidr                   = var.vpc_cidr
  azs                        = var.azs
  public_subnets             = var.public_subnets
  private_subnets            = var.private_subnets
  enable_dns_hostnames       = true
  enable_dns_support         = true
  create_igw                 = true
  map_public_ip_on_launch    = true
  enable_nat_gateway         = var.enable_nat_gateway
  single_nat_gateway         = var.single_nat_gateway
  one_nat_gateway_per_az     = false
  enable_s3_endpoint         = var.enable_s3_endpoint
  enable_dynamodb_endpoint   = var.enable_dynamodb_endpoint
  enable_interface_endpoints = var.enable_vpc_interface_endpoints
  enable_batch_endpoint      = var.enable_batch_endpoint
  tags                       = var.tags
}

# Security Groups
module "batch_job_security_group" {
  source        = "./modules/security-groups"
  name          = "${var.project_name}-batch-sg"
  vpc_id        = module.vpc.vpc_id
  ingress_rules = [] # Batch tasks only require outbound connectivity to S3, ECR, and CloudWatch
  egress_rules = [
    {
      description = "Allow all outbound traffic"
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    }
  ]
  tags = var.tags
}

module "lambda_sg" {
  source        = "./modules/security-groups"
  name          = "${var.project_name}-lambda-sg"
  vpc_id        = module.vpc.vpc_id
  ingress_rules = []
  egress_rules = [
    {
      description     = "HTTPS to VPC endpoints and AWS service APIs"
      from_port       = 443
      to_port         = 443
      protocol        = "tcp"
      cidr_blocks     = ["0.0.0.0/0"]
      security_groups = []
    }
  ]
  tags = var.tags
}

# ------------------------------------------------------------------------------
# 3. Amazon ECR Repository & Build Pipeline
# ------------------------------------------------------------------------------
module "ecr" {
  source               = "./modules/ecr"
  name                 = var.ecr_repository_name
  force_delete         = true
  scan_on_push         = var.ecr_scan_on_push
  image_tag_mutability = var.ecr_image_tag_mutability
  tags                 = var.tags
}

resource "null_resource" "build_and_push_image" {
  triggers = {
    dockerfile_hash = filemd5("${path.module}/../src/batch-job/Dockerfile")
    main_py_hash    = filemd5("${path.module}/../src/batch-job/main.py")
    reqs_hash       = filemd5("${path.module}/../src/batch-job/requirements.txt")
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/../src/batch-job/artifact_push.sh ${var.region}"
  }

  depends_on = [
    module.ecr
  ]
}

# ------------------------------------------------------------------------------
# 4. Amazon S3 Storage Buckets
# ------------------------------------------------------------------------------
module "source_bucket" {
  source             = "./modules/s3"
  bucket_name        = "${var.source_bucket_prefix}-${var.region}-${data.aws_caller_identity.current.account_id}"
  objects            = []
  versioning_enabled = var.s3_versioning_enabled
  cors = [
    {
      allowed_headers = ["*"]
      allowed_methods = ["PUT"]
      allowed_origins = ["*"]
      max_age_seconds = var.s3_cors_max_age_seconds
    }
  ]
  bucket_policy = ""
  force_destroy = var.s3_force_destroy
  bucket_notification = {
    queue = [
      {
        queue_arn = module.job_queue.arn
        events    = ["s3:ObjectCreated:*"]
      }
    ]
    lambda_function = []
  }
  tags = var.tags
}

module "destination_bucket" {
  source             = "./modules/s3"
  bucket_name        = "${var.destination_bucket_prefix}-${var.region}-${data.aws_caller_identity.current.account_id}"
  objects            = []
  versioning_enabled = var.s3_versioning_enabled
  cors = [
    {
      allowed_headers = ["*"]
      allowed_methods = ["PUT"]
      allowed_origins = ["*"]
      max_age_seconds = var.s3_cors_max_age_seconds
    }
  ]
  bucket_policy = ""
  force_destroy = var.s3_force_destroy
  bucket_notification = {
    queue           = []
    lambda_function = []
  }
  tags = var.tags
}

module "job_submit_function_code" {
  source      = "./modules/s3"
  bucket_name = "${var.lambda_code_bucket_prefix}-${var.region}-${data.aws_caller_identity.current.account_id}"
  objects = [
    {
      key    = "job_submit_function.zip"
      source = "./files/job_submit_function.zip"
    }
  ]
  cors               = []
  bucket_policy      = ""
  versioning_enabled = var.s3_versioning_enabled
  force_destroy      = true
  tags               = var.tags
}

# ------------------------------------------------------------------------------
# 5. Amazon SQS Queuing (Main Queue + DLQ)
# ------------------------------------------------------------------------------
module "job_queue" {
  source                        = "./modules/sqs"
  queue_name                    = var.sqs_queue_name
  delay_seconds                 = 0
  maxReceiveCount               = var.sqs_max_receive_count
  dlq_message_retention_seconds = var.sqs_dlq_retention_seconds
  max_message_size              = var.sqs_max_message_size
  message_retention_seconds     = var.sqs_message_retention_seconds
  visibility_timeout_seconds    = var.sqs_visibility_timeout_seconds
  receive_wait_time_seconds     = var.sqs_receive_wait_time_seconds

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = "arn:aws:sqs:${var.region}:*:${var.sqs_queue_name}"
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = module.source_bucket.arn
          }
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_lambda_event_source_mapping" "sqs_to_lambda" {
  event_source_arn                   = module.job_queue.arn
  function_name                      = module.job_submit_function.arn
  batch_size                         = var.sqs_batch_size
  maximum_batching_window_in_seconds = var.sqs_batch_window_seconds
  function_response_types            = ["ReportBatchItemFailures"]
}

# ------------------------------------------------------------------------------
# 6. Amazon DynamoDB State Tracking Table
# ------------------------------------------------------------------------------
module "job_metadata_state" {
  source = "./modules/dynamodb"
  name   = var.dynamodb_table_name
  attributes = [
    {
      name = "RecordId"
      type = "S"
    },
    {
      name = "filename"
      type = "S"
    }
  ]
  billing_mode          = var.dynamodb_billing_mode
  hash_key              = "RecordId"
  range_key             = "filename"
  ttl_attribute_name    = var.dynamodb_ttl_attribute_name
  ttl_attribute_enabled = var.dynamodb_ttl_enabled
  pitr_enabled          = var.dynamodb_pitr_enabled
  tags                  = var.tags
}

# ------------------------------------------------------------------------------
# 7. CloudWatch Logs for AWS Batch
# ------------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "batch_logs" {
  name              = "/aws/batch/job"
  retention_in_days = var.batch_log_retention_days
  tags              = var.tags
}

# ------------------------------------------------------------------------------
# 8. AWS Lambda Function & Execution Role
# ------------------------------------------------------------------------------
module "job_submit_function_iam_role" {
  source             = "./modules/iam"
  role_name          = "${var.project_name}-lambda-role"
  role_description   = "IAM role for media watermark job submitter lambda function"
  policy_name        = "${var.project_name}-lambda-policy"
  policy_description = "IAM policy granting Batch, DynamoDB, SQS, VPC, and CloudWatch permissions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Sid    = "BatchSubmitJob"
        Effect = "Allow"
        Action = [
          "batch:SubmitJob",
          "batch:DescribeJobs",
          "batch:TerminateJob",
          "batch:TagResource"
        ]
        Resource = [
          aws_batch_job_queue.batch_job_queue.arn,
          aws_batch_job_definition.batch_job_definition.arn,
          "arn:aws:batch:${var.region}:${data.aws_caller_identity.current.account_id}:job-definition/${var.batch_job_definition_name}:*",
          "arn:aws:batch:${var.region}:${data.aws_caller_identity.current.account_id}:job/*"
        ]
      },
      {
        Sid    = "DynamoDBStateManagement"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:GetItem",
          "dynamodb:Query"
        ]
        Resource = module.job_metadata_state.arn
      },
      {
        Sid    = "SQSConsumption"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = [
          module.job_queue.arn,
          module.job_queue.dlq_arn
        ]
      },
      {
        Sid    = "VPCNetworkInterfaces"
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface"
        ]
        Resource = "*"
      }
    ]
  })
}

module "job_submit_function" {
  source        = "./modules/lambda"
  function_name = var.lambda_function_name
  role_arn      = module.job_submit_function_iam_role.arn
  permissions   = []

  vpc_config = var.enable_lambda_vpc ? {
    security_group_ids = [module.lambda_sg.id]
    subnet_ids         = module.vpc.private_subnets
  } : null

  env_variables = {
    REGION                     = var.region
    JOB_QUEUE_ARN              = aws_batch_job_queue.batch_job_queue.arn
    JOB_DEFINITION_ARN         = aws_batch_job_definition.batch_job_definition.arn
    DYNAMODB_TABLE             = module.job_metadata_state.name
    DESTINATION_BUCKET         = module.destination_bucket.bucket
    DEFAULT_WATERMARK_TEXT     = var.default_watermark_text
    DEFAULT_WATERMARK_TYPE     = var.default_watermark_type
    DEFAULT_WATERMARK_POSITION = var.default_watermark_position
    DEFAULT_WATERMARK_OPACITY  = tostring(var.default_watermark_opacity)
  }

  handler          = "job_submit_function.lambda_handler"
  runtime          = var.lambda_runtime
  timeout          = var.lambda_timeout
  memory_size      = var.lambda_memory_size
  s3_bucket        = module.job_submit_function_code.bucket
  s3_key           = "job_submit_function.zip"
  source_code_hash = filebase64sha256("${path.module}/files/job_submit_function.zip")
  layers           = []

  tags = var.tags
}

# ------------------------------------------------------------------------------
# 9. EventBridge: Batch Job State Change Rule (Updates DynamoDB to COMPLETED / FAILED)
# ------------------------------------------------------------------------------
module "batch_job_events" {
  source      = "./modules/eventbridge"
  name        = "${var.project_name}-batch-state-change"
  description = "Captures AWS Batch job state changes (SUCCEEDED, FAILED) to update DynamoDB"

  event_pattern = jsonencode({
    source      = ["aws.batch"]
    detail-type = ["Batch Job State Change"]
    detail = {
      status   = ["SUCCEEDED", "FAILED"]
      jobQueue = [aws_batch_job_queue.batch_job_queue.arn]
    }
  })

  targets = {
    "watermark-job-submit-lambda" = {
      arn                      = module.job_submit_function.arn
      statement_id             = "AllowExecutionFromEventBridge"
      attach_lambda_permission = true
      lambda_function_name     = module.job_submit_function.function_name
    }
  }

  tags = var.tags
}

# ------------------------------------------------------------------------------
# 10. AWS Batch Compute Environment & Job Roles
# ------------------------------------------------------------------------------
resource "aws_batch_compute_environment" "batch_compute" {
  name = "${var.project_name}-${var.batch_compute_environment_name}"
  compute_resources {
    max_vcpus = var.batch_max_vcpus

    security_group_ids = [
      module.batch_job_security_group.id
    ]

    subnets = module.vpc.private_subnets
    type    = "FARGATE"
  }

  service_role = aws_iam_role.aws_batch_service_role.arn
  type         = "MANAGED"
  depends_on   = [aws_iam_role_policy_attachment.aws_batch_service_role]
  tags         = var.tags
}

# ECS Task Execution Role (Pulling images from ECR, sending logs to CloudWatch)
resource "aws_iam_role" "ecs_task_execution_role" {
  name               = "${var.project_name}-ecs-execution-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role_policy.json
  tags               = var.tags
}

data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy_attachment" "ecr_registry_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Dedicated Container Task Job Role (Runtime application permissions for S3 read/write)
resource "aws_iam_role" "batch_job_role" {
  name               = "${var.project_name}-task-job-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role_policy.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "batch_job_s3_policy" {
  name = "batch-job-s3-access"
  role = aws_iam_role.batch_job_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadSourceBucket"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [module.source_bucket.arn, "${module.source_bucket.arn}/*"]
      },
      {
        Sid    = "WriteDestinationBucket"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:AbortMultipartUpload"
        ]
        Resource = ["${module.destination_bucket.arn}/*"]
      }
    ]
  })
}

resource "aws_batch_job_definition" "batch_job_definition" {
  name                  = var.batch_job_definition_name
  type                  = "container"
  platform_capabilities = ["FARGATE"]
  container_properties = jsonencode({
    image            = "${module.ecr.repository_url}:latest",
    environment      = []
    jobRoleArn       = aws_iam_role.batch_job_role.arn,
    executionRoleArn = aws_iam_role.ecs_task_execution_role.arn,
    fargatePlatformConfiguration = {
      platformVersion = "LATEST"
    },
    resourceRequirements = [
      { type = "VCPU", value = var.batch_default_vcpu },
      { type = "MEMORY", value = var.batch_default_memory }
    ],
    ephemeralStorage = {
      sizeInGiB = var.batch_ephemeral_storage_gb
    },
    networkConfiguration = {
      assignPublicIp = "DISABLED"
    },
    logConfiguration = {
      logDriver = "awslogs",
      options = {
        "awslogs-group"         = "${aws_cloudwatch_log_group.batch_logs.name}",
        "awslogs-region"        = var.region,
        "awslogs-stream-prefix" = "batch"
      }
    }
  })
  depends_on = [aws_cloudwatch_log_group.batch_logs]
  tags       = var.tags
}

resource "aws_batch_job_queue" "batch_job_queue" {
  name     = var.batch_job_queue_name
  state    = "ENABLED"
  priority = 1

  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.batch_compute.arn
  }
  tags = var.tags
}

# ------------------------------------------------------------------------------
# 11. CloudWatch Operational Alarms
# ------------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "sqs_dlq_alarm" {
  count               = var.enable_alarms ? 1 : 0
  alarm_name          = "${var.project_name}-sqs-dlq-messages"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = var.alarm_period_seconds
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "Triggers when poison messages accumulate in the Batch SQS Dead Letter Queue"

  dimensions = {
    QueueName = module.job_queue.dlq_name
  }
  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors_alarm" {
  count               = var.enable_alarms ? 1 : 0
  alarm_name          = "${var.project_name}-lambda-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = var.alarm_period_seconds
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Triggers when watermark job submit Lambda invocations fail"

  dimensions = {
    FunctionName = module.job_submit_function.function_name
  }
  tags = var.tags
}