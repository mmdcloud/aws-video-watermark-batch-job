data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------------------
# IAM role for batch 
# -----------------------------------------------------------------------------------------
data "aws_iam_policy_document" "batch_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["batch.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "aws_batch_service_role" {
  name               = "aws-batch-service-role"
  assume_role_policy = data.aws_iam_policy_document.batch_assume_role.json
}

resource "aws_iam_role_policy_attachment" "aws_batch_service_role" {
  role       = aws_iam_role.aws_batch_service_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole"
}

# -----------------------------------------------------------------------------------------
# VPC Configuration
# -----------------------------------------------------------------------------------------
module "vpc" {
  source                  = "./modules/vpc"
  vpc_name                = "vpc"
  vpc_cidr                = "10.0.0.0/16"
  azs                     = var.azs
  public_subnets          = var.public_subnets
  private_subnets         = var.private_subnets
  enable_dns_hostnames    = true
  enable_dns_support      = true
  create_igw              = true
  map_public_ip_on_launch = true
  enable_nat_gateway      = true
  single_nat_gateway      = true
  one_nat_gateway_per_az  = false
  tags = {
    Project = "newsapp-batch"
  }
}

# Security Group
module "batch_job_security_group" {
  source = "./modules/security-groups"
  name   = "batch-job-security-group"
  vpc_id = module.vpc.vpc_id
  ingress_rules = [
    {
      description     = "Traffic"
      from_port       = 0
      to_port         = 0
      protocol        = "tcp"
      security_groups = []
      cidr_blocks     = ["0.0.0.0/0"]
    }
  ]
  egress_rules = [
    {
      description = "Allow all outbound traffic"
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    }
  ]
  tags = {
    Name = "security-group"
  }
}

module "lambda_sg" {
  source = "./modules/security-groups"
  name   = "lambda-sg"
  vpc_id = module.vpc.vpc_id

  ingress_rules = []

  egress_rules = [
    {
      description     = "HTTPS to VPC endpoints and internet"
      from_port       = 443
      to_port         = 443
      protocol        = "tcp"
      cidr_blocks     = ["0.0.0.0/0"]
      security_groups = []
    }
  ]

  tags = {
    Name = "lambda-sg"
  }
}

# -----------------------------------------------------------------------------------------
# ECR Configuration
# -----------------------------------------------------------------------------------------
module "ecr" {
  source               = "./modules/ecr"
  force_delete         = true
  scan_on_push         = true
  image_tag_mutability = "IMMUTABLE"
  bash_command         = "bash ${path.module}/../src/batch-job/artifact_push.sh ${var.region}"
  name                 = "batch_job"
}

# -----------------------------------------------------------------------------------------
# S3 Configuration
# -----------------------------------------------------------------------------------------
module "source_bucket" {
  source             = "./modules/s3"
  bucket_name        = "source-bucket-${var.region}-${data.aws_caller_identity.current.account_id}"
  objects            = []
  versioning_enabled = "Enabled"
  cors = [
    {
      allowed_headers = ["*"]
      allowed_methods = ["PUT"]
      allowed_origins = ["*"]
      max_age_seconds = 3000
    }
  ]
  bucket_policy = ""
  force_destroy = true
  bucket_notification = {
    queue = [
      {
        queue_arn = module.job_queue.arn
        events    = ["s3:ObjectCreated:*"]
      }
    ]
    lambda_function = []
  }
}

module "destination_bucket" {
  source             = "./modules/s3"
  bucket_name        = "destination-bucket-${var.region}-${data.aws_caller_identity.current.account_id}"
  objects            = []
  versioning_enabled = "Enabled"
  cors = [
    {
      allowed_headers = ["*"]
      allowed_methods = ["PUT"]
      allowed_origins = ["*"]
      max_age_seconds = 3000
    }
  ]
  bucket_policy = ""
  force_destroy = true
  bucket_notification = {
    queue           = []
    lambda_function = []
  }
}

module "job_submit_function_code" {
  source      = "./modules/s3"
  bucket_name = "job-submit-code-${var.region}-${data.aws_caller_identity.current.account_id}"
  objects = [
    {
      key    = "job_submit_function.zip"
      source = "./files/job_submit_function.zip"
    }
  ]
  cors               = []
  bucket_policy      = ""
  versioning_enabled = "Enabled"
  force_destroy      = true
  tags = {
    Name = "job-submit-function-code"
  }
}

# -----------------------------------------------------------------------------------------
# SQS Configuration
# -----------------------------------------------------------------------------------------
module "job_queue" {
  source                     = "./modules/sqs"
  queue_name                 = "job-queue"
  delay_seconds              = 0
  maxReceiveCount            = 3
  max_message_size           = 262144
  message_retention_seconds  = 345600
  visibility_timeout_seconds = 180
  receive_wait_time_seconds  = 20

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = "arn:aws:sqs:${var.region}:*:job-queue"
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = module.source_bucket.arn
          }
        }
      }
    ]
  })

  tags = {
    Name = "job-queue"
  }
}

resource "aws_lambda_event_source_mapping" "sqs_to_lambda" {
  event_source_arn                   = module.job_queue.arn
  function_name                      = module.job_submit_function.arn
  batch_size                         = 10
  maximum_batching_window_in_seconds = 5
  function_response_types            = ["ReportBatchItemFailures"]
}

# -----------------------------------------------------------------------------------------
# Cloudwatch logs for Batch job
# -----------------------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "batch_logs" {
  name              = "/aws/batch/job"
  retention_in_days = 7
}

# -----------------------------------------------------------------------------------------
# DynamoDb Configuration ( For storing job metadata and state)
# -----------------------------------------------------------------------------------------
module "job_metadata_state" {
  source = "./modules/dynamodb"
  name   = "invoice-records"
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
  billing_mode          = "PAY_PER_REQUEST"
  hash_key              = "RecordId"
  range_key             = "filename"
  ttl_attribute_name    = "TimeToExist"
  ttl_attribute_enabled = true
}

# -----------------------------------------------------------------------------------------
# Lambda Configuration
# -----------------------------------------------------------------------------------------
module "job_submit_function_iam_role" {
  source             = "./modules/iam"
  role_name          = "job-submit-function-iam-role"
  role_description   = "IAM role for media watermark job submitter lambda function"
  policy_name        = "job-submit-function-iam-policy"
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
          "arn:aws:batch:${var.region}:${data.aws_caller_identity.current.account_id}:job-definition/${aws_batch_job_definition.batch_job_definition.name}:*",
          "arn:aws:batch:${var.region}:${data.aws_caller_identity.current.account_id}:job/*"
        ]
      },
      {
        Sid    = "DynamoDBStateManagement"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:GetItem"
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
        Resource = module.job_queue.arn
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
  function_name = "watermark-job-submit"
  role_arn      = module.job_submit_function_iam_role.arn
  permissions   = []

  vpc_config = {
    security_group_ids = [module.lambda_sg.id]
    subnet_ids         = module.vpc.private_subnets
  }

  env_variables = {
    REGION                 = var.region
    JOB_QUEUE_ARN          = aws_batch_job_queue.batch_job_queue.arn
    JOB_DEFINITION_ARN     = aws_batch_job_definition.batch_job_definition.arn
    DYNAMODB_TABLE         = module.job_metadata_state.name
    DESTINATION_BUCKET     = module.destination_bucket.bucket
    DEFAULT_WATERMARK_TEXT = "CONFIDENTIAL"
  }


  handler   = "job_submit_function.lambda_handler"
  runtime   = "python3.12"
  s3_bucket = module.job_submit_function_code.bucket
  s3_key    = "job_submit_function.zip"
  layers    = []

  tags = {
    Name = "watermark-job-submit"
  }
}

# -----------------------------------------------------------------------------------------
# Batch Configuration
# -----------------------------------------------------------------------------------------
resource "aws_batch_compute_environment" "batch_compute" {
  # name = "batch-compute"
  compute_resources {
    max_vcpus = 16

    security_group_ids = [
      module.batch_job_security_group.id
    ]

    subnets = module.vpc.public_subnets
    type    = "FARGATE"
  }

  service_role = aws_iam_role.aws_batch_service_role.arn
  type         = "MANAGED"
  depends_on   = [aws_iam_role_policy_attachment.aws_batch_service_role]
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name               = "ecs_task_execution_role"
  assume_role_policy = data.aws_iam_policy_document.assume_role_policy.json
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

resource "aws_iam_role_policy_attachment" "ecs_cloudwatch_logs" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
}

resource "aws_iam_role_policy" "batch_job_s3_policy" {
  name = "batch-job-s3-access"
  role = aws_iam_role.ecs_task_execution_role.id

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
        Sid      = "WriteDestinationBucket"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = ["${module.destination_bucket.arn}/*"]
      }
    ]
  })
}

resource "aws_batch_job_definition" "batch_job_definition" {
  name                  = "batch-job-definition"
  type                  = "container"
  platform_capabilities = ["FARGATE"]
  container_properties = jsonencode({
    image       = "${module.ecr.repository_url}:latest",
    environment = []
    jobRoleArn  = aws_iam_role.ecs_task_execution_role.arn,
    fargatePlatformConfiguration = {
      platformVersion = "LATEST"
    },
    resourceRequirements = [
      { type = "VCPU", value = "2.0" },
      { type = "MEMORY", value = "4096" }
    ],

    executionRoleArn = aws_iam_role.ecs_task_execution_role.arn,
    networkConfiguration = {
      assignPublicIp = "ENABLED"
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
}

resource "aws_batch_job_queue" "batch_job_queue" {
  name     = "batch-job-queue"
  state    = "ENABLED"
  priority = 1

  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.batch_compute.arn
  }
}
