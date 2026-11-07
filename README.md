# Event-Driven Media Watermarking Pipeline on AWS Batch & Fargate

[![Terraform](https://img.shields.io/badge/Terraform-1.11+-623CE4.svg?logo=terraform)](https://www.terraform.io/)
[![Python](https://img.shields.io/badge/Python-3.12-3776AB.svg?logo=python)](https://www.python.org/)
[![Docker](https://img.shields.io/badge/Docker-Fargate_Ready-2496ED.svg?logo=docker)](https://www.docker.com/)
[![FFmpeg](https://img.shields.io/badge/FFmpeg-6.1+-007808.svg?logo=ffmpeg)](https://ffmpeg.org/)
[![AWS](https://img.shields.io/badge/AWS-Batch_%7C_Lambda_%7C_DynamoDB_%7C_SQS_%7C_S3-FF9900.svg?logo=amazon-aws)](https://aws.amazon.com/)
[![Tests](https://img.shields.io/badge/Tests-18%2F18_Passing-brightgreen.svg)](tests/)

A production-grade, event-driven serverless media processing pipeline deployed via Terraform. The architecture ingests video and image uploads via Amazon S3, buffers ingestion traffic through Amazon SQS, triggers an AWS Lambda orchestrator to record state in Amazon DynamoDB, and dispatches containerized transcode jobs to AWS Batch on AWS Fargate executing FFmpeg.

---

## Architecture Overview

```
                          ┌────────────────────────────────────────────────────────┐
                          │                      AWS Cloud                         │
                          │                                                        │
   1. Upload Media        │   2. ObjectCreated                                     │
  ─────────────────► [ S3 Source Bucket ] ──────────┐                              │
                            (Versioning)            │                              │
                                                    ▼                              │
                                            [ Amazon SQS ] ──► [ SQS DLQ ]         │
                                             (job-queue)       (Poison Buffer)     │
                                                    │                              │
                                                    │ 3. Event Source Mapping      │
                                                    │    (Batch Size: 10)          │
                                                    ▼                              │
                                            [ AWS Lambda ] ◄───────────────────┐   │
                                        (watermark-job-submit)                 │   │
                                                    │                          │   │
                                    ┌───────────────┴──────────────┐           │   │
                                    │ 4. Track State               │ 5. Submit │   │
                                    ▼                              ▼           │   │
                         [ Amazon DynamoDB ]              [ AWS Batch Queue ]  │   │
                      (media-watermark-records)           (batch-job-queue)    │   │
                           - Hash: RecordId                        │           │   │
                           - Range: filename                       ▼           │   │
                           - TTL: TimeToExist             [ AWS Batch Compute ]│   │
                           - PITR & SSE Enabled           (Private Fargate)    │   │
                                  ▲                                │           │   │
                                  │                                ▼           │   │
                                  │                       [ Fargate Task ]     │   │
                                  │                       - Private Subnets    │   │
                                  │                       - S3 VPC Gateway     │   │
                                  │                       - FFmpeg Transcode   │   │
                                  │                       - 50 GiB Ephemeral   │   │
                                  │                                │           │   │
                                  │ 7. State Change Event          │ 6. Upload │   │
                                  │    (COMPLETED / FAILED)        ▼           │   │
                                  └──────── [ Amazon EventBridge ] ─── [ S3 Dest ] │
                                                                                   │
                          └────────────────────────────────────────────────────────┘
```

### End-to-End Pipeline Workflow

1. **Ingestion**: A user or upstream service uploads a video (`.mp4`, `.mov`, `.mkv`, etc.) or image (`.jpg`, `.png`, etc.) to the source S3 bucket.
2. **Buffering**: S3 generates an `s3:ObjectCreated:*` event notification pushed into the SQS `job-queue`. SQS buffers high-throughput bursts to prevent API rate-limiting.
3. **Dispatch & Sizing**: SQS triggers the `watermark-job-submit` Lambda function via native event source mapping with `ReportBatchItemFailures`. The Lambda function:
   - Decodes the URL-encoded S3 key.
   - Dynamically calculates compute requirements (**2.0 vCPU / 4096 MiB** for video; **0.5 vCPU / 1024 MiB** for images).
   - Sanitizes the job name to conform to AWS Batch specifications (`^[a-zA-Z0-9_-]{1,128}$`).
4. **State Persistence**: Lambda logs an initial record into Amazon DynamoDB (`media-watermark-records`) with status `SUBMITTED`, metadata attributes, and automated TTL (`TimeToExist`).
5. **Batch Execution**: AWS Batch dispatches the container to a serverless AWS Fargate compute environment:
   - The container pulls the application image from Amazon ECR.
   - The Python worker (`src/batch-job/main.py`) streams the media from S3 via multi-threaded multipart download (`TransferConfig`).
   - FFmpeg applies text watermarks (via `drawtext` with TrueType fonts, box contrast, and coordinate positioning) and/or image logos (via `overlay` with dynamic scaling and opacity).
   - Video streams are encoded with `libx264` (`preset medium`, `crf 23`, `pix_fmt yuv420p`, `-movflags +faststart`) and audio is preserved via `aac` (`-map 0:a?` to gracefully support silent media).
6. **Delivery**: The processed media is uploaded to the destination S3 bucket using multipart upload with S3 Server-Side Encryption (`AES256`).
7. **Lifecycle State Callback**: Amazon EventBridge monitors AWS Batch state changes (`SUCCEEDED` / `FAILED`) on `batch-job-queue` and triggers the Lambda orchestrator to update the DynamoDB record to `COMPLETED` or `FAILED` with execution telemetry and exit codes.

---

## Repository Structure

```
.
├── README.md                           # Production architecture and operations guide
├── screenshots/                        # Live AWS console & execution screenshots
│   ├── Screenshot from 2026-11-01 10-16-38.png # Terraform apply outputs
│   ├── Screenshot from 2026-11-01 10-18-00.png # S3 buckets
│   ├── Screenshot from 2026-11-01 10-19-50.png # S3 upload trigger
│   ├── Screenshot from 2026-11-01 10-20-31.png # Batch job queue & execution
│   ├── Screenshot from 2026-11-01 10-21-20.png # Batch compute environment
│   ├── Screenshot from 2026-11-01 10-23-10.png # S3 destination output
│   ├── Screenshot from 2026-11-01 10-24-03.png # CloudWatch logs & FFmpeg telemetry
│   └── Screenshot from 2026-11-01 10-25-59.png # Rendered watermarked video
├── src/
│   ├── batch-job/                      # AWS Batch container application
│   │   ├── Dockerfile                  # Multi-layer hardened Debian/Python 3.12 image
│   │   ├── artifact_push.sh            # ECR build & push script with smart cache skip
│   │   ├── main.py                     # FFmpeg watermarking engine & S3 worker
│   │   ├── lambda.py                   # Module entrypoint alias
│   │   ├── requirements.txt            # Python dependencies (boto3, botocore, urllib3)
│   │   └── .dockerignore               # Docker build context exclusions
│   └── job-submit-function/            # AWS Lambda submission & tracking function
│       ├── __init__.py                 # Package initializer
│       ├── job_submit_function.py      # Entrypoint matching Terraform handler
│       ├── lambda.py                   # Ingestion, validation & DynamoDB tracker
│       ├── main.py                     # CLI & direct invocation alias
│       └── requirements.txt            # Lambda runtime dependencies
├── terraform/
│   ├── main.tf                         # Root Terraform configuration
│   ├── variables.tf                    # Input variable declarations (parameterized)
│   ├── terraform.tfvars                # Active production variable values
│   ├── terraform.tfvars.example        # Reference variable configuration template
│   ├── outputs.tf                      # Exported infrastructure outputs
│   ├── provider.tf                     # AWS provider & region settings
│   ├── files/
│   │   └── job_submit_function.zip     # Packaged Lambda deployment artifact
│   └── modules/
│       ├── batch/                      # AWS Batch module
│       ├── cloudwatch/                 # CloudWatch log group & alarms module
│       ├── dynamodb/                   # DynamoDB state table module
│       ├── ecr/                        # Amazon ECR repository module
│       ├── iam/                        # IAM roles & policies module
│       ├── lambda/                     # AWS Lambda deployment module
│       ├── s3/                         # S3 bucket, CORS & notification module
│       ├── security-groups/            # VPC Security Groups module
│       ├── sqs/                        # SQS queue & dead-letter queue module
│       └── vpc/                        # Multi-AZ VPC with NAT Gateway & S3 Endpoint
└── tests/
    ├── test_main.py                    # Unit tests for Batch FFmpeg worker
    └── test_job_submit_lambda.py       # Unit tests for Lambda submitter & DynamoDB
```

---

## Infrastructure Specifications

### 1. Networking & VPC
* **CIDR Block**: `10.0.0.0/16` across 3 Availability Zones (`us-east-1a`, `us-east-1b`, `us-east-1c`).
* **Subnets**: 3 public subnets (`10.0.1.0/24`, `10.0.2.0/24`, `10.0.3.0/24`) and 3 private subnets (`10.0.4.0/24`, `10.0.5.0/24`, `10.0.6.0/24`).
* **Internet Connectivity & S3 Routing**:
  * Internet Gateway for public subnet egress.
  * Single NAT Gateway providing managed outbound connectivity for Lambda ENIs and ECR container image pulls.
  * **S3 Gateway VPC Endpoint**: Provisioned via `aws_vpc_endpoint.s3` to route all S3 multipart traffic privately across AWS internal network, eliminating NAT data transfer costs.
* **Security Groups**:
  * `${var.project_name}-batch-sg`: Zero inbound rules (`ingress_rules = []`); outbound all traffic (`-1` to `0.0.0.0/0`) for S3, ECR, and CloudWatch.
  * `${var.project_name}-lambda-sg`: Outbound HTTPS (`tcp/443` to `0.0.0.0/0`) for secure communication with AWS service APIs.

### 2. Storage & Queuing
* **Amazon S3**:
  * Source Media Bucket: `${var.source_bucket_prefix}-${region}-${account_id}` with Versioning, Public Access Block, and S3 bucket notifications triggering SQS on `s3:ObjectCreated:*`.
  * Destination Media Bucket: `${var.destination_bucket_prefix}-${region}-${account_id}` with Versioning, Public Access Block, and Lifecycle rule aborting incomplete multipart uploads after 7 days.
  * Lambda Code Bucket: `${var.lambda_code_bucket_prefix}-${region}-${account_id}` storing the zipped function code with MD5 hash tracking.
* **Amazon SQS**:
  * Main Queue: `job-queue` (Max message size: 256 KB, retention: 4 days, visibility timeout: 180s, receive wait time: 20s).
  * Dead Letter Queue: `job-queue-dlq` with `maxReceiveCount = 3` and 14-day retention for poison messages.
  * Policy: Explicit `sqs:SendMessage` authorized strictly for `s3.amazonaws.com` restricted by `aws:SourceArn`.

### 3. State Management & Compute
* **Amazon DynamoDB**:
  * Table: `media-watermark-records`
  * Billing Mode: `PAY_PER_REQUEST` (On-Demand auto-scaling)
  * Partition Key: `RecordId` (String - AWS Batch Job ID or deterministic UUID)
  * Sort Key: `filename` (String - Source S3 object key)
  * Protection: Server-Side Encryption (SSE) and Point-In-Time Recovery (PITR) enabled.
  * TTL: Enabled on `TimeToExist` attribute (automated expiration of historical records).
* **AWS Lambda**:
  * Function Name: `watermark-job-submit`
  * Runtime: `python3.12` | Memory: 256 MB | Timeout: 30s | Tracked via `source_code_hash`.
  * Triggers: SQS Event Source Mapping (`batch_size = 10`, `maximum_batching_window_in_seconds = 5`, `ReportBatchItemFailures`) and EventBridge Batch Job State Change events.
* **AWS Batch & Fargate**:
  * Compute Environment: `${var.project_name}-batch-compute` (Managed Fargate scaling up to 16 vCPUs in private VPC subnets with `assignPublicIp = "DISABLED"`).
  * Ephemeral Storage: **50 GiB** disk space allocated per task to accommodate high-bitrate video transcoding.
  * Job Queue: `batch-job-queue` (Priority 1).
  * Job Definition: `batch-job-definition` (Default allocation: **2.0 vCPU** / **4096 MiB RAM**; overridable dynamically per media type).

---

## Security & Compliance Architecture

* **Principle of Least Privilege (IAM)**:
  * **Lambda Execution Role (`${var.project_name}-lambda-role`)**: Strictly scoped to write CloudWatch logs, invoke `batch:SubmitJob` / `batch:DescribeJobs` / `batch:TagResource` on Batch resources, perform `dynamodb:PutItem` / `dynamodb:UpdateItem` / `dynamodb:GetItem` / `dynamodb:Query` on the state table, consume SQS messages, and manage EC2 ENIs.
  * **ECS Task Execution Role (`${var.project_name}-ecs-execution-role`)**: Attaches `AmazonECSTaskExecutionRolePolicy` and `AmazonEC2ContainerRegistryReadOnly` for ECR image pulling and CloudWatch log streaming.
  * **Container Job Role (`${var.project_name}-task-job-role`)**: Attaches inline policy `batch-job-s3-access` scoped to `s3:GetObject` and `s3:ListBucket` on the source bucket, and `s3:PutObject` and `s3:AbortMultipartUpload` on the destination bucket.
  * **AWS Batch Service Role (`${var.project_name}-batch-service-role`)**: Attaches `AWSBatchServiceRole` allowing AWS Batch to orchestrate underlying compute and networking.
* **Container Hardening**:
  * Base Image: `python:3.12-slim-bookworm` with minimal attack surface.
  * Non-Root User: Runs under dedicated unprivileged system user `appuser:appgroup` (UID/GID `10001`).
  * Signal Trapping: Python entrypoint traps `SIGTERM` and `SIGINT` to gracefully terminate FFmpeg child processes and clean temporary scratch storage (`/tmp`) during ECS instance termination or spot reclamation.
* **ECR Security**: Repository configured with configurable tag mutability (`MUTABLE` by default, switchable to `IMMUTABLE`) and automated CVE vulnerability scanning on push (`scan_on_push = true`).

---

## Prerequisites

Before deployment, ensure you have:

* [Terraform](https://www.terraform.io/downloads.html) >= 1.5.0
* [AWS CLI v2](https://aws.amazon.com/cli/) configured (`aws configure` with Administrator or DevOps privileges)
* [Docker](https://docs.docker.com/get-docker/) daemon installed and running locally
* [Python](https://www.python.org/) 3.12+ (for running local unit tests)
* [zip](https://linux.die.net/man/1/zip) utility (for packaging Lambda function code)

---

## Deployment Guide

### Step 1: Package the Lambda Deployment Artifact

Package the contents of `src/job-submit-function/` into `terraform/files/job_submit_function.zip`:

```bash
# Ensure target files directory exists
mkdir -p terraform/files

# Package the Lambda source files
cd src/job-submit-function
zip -r ../../terraform/files/job_submit_function.zip . -x "*__pycache__*" "*.pytest_cache*"
cd ../..
```

### Step 2: Configure Environment Variables

Create or adjust your `terraform.tfvars` from the provided example template:

```bash
cd terraform

# Copy reference template if starting fresh
cp terraform.tfvars.example terraform.tfvars

# Review and edit project-specific values (region, project_name, VPC CIDR, compute limits)
```

### Step 3: Initialize & Review Terraform

```bash
# Initialize provider plugins and modules
terraform init

# Validate syntax and configuration
terraform validate

# Review proposed changes
terraform plan -out=tfplan
```

### Step 4: Apply Infrastructure

```bash
terraform apply tfplan
```

*During execution, Terraform provisions the VPC, NAT Gateway, S3 buckets, SQS queues, DynamoDB table, Lambda function, and ECR repository.*
*The `null_resource.push_image_to_ecr` provisioner will automatically build `src/batch-job/Dockerfile` and push the container image to Amazon ECR.*

---

## Configuration & Parameters Reference

### Root Terraform Variables (`terraform/variables.tf` & `terraform/terraform.tfvars`)

#### Project & Identity
| Variable | Type | Default | Description |
| :--- | :---: | :---: | :--- |
| `project_name` | `string` | `"media-watermark"` | Base name prefix for all provisioned resources |
| `environment` | `string` | `"prod"` | Target deployment environment (`prod`, `staging`, `dev`) |
| `tags` | `map(string)` | `{Project=..., Environment=..., ManagedBy=Terraform}` | Resource tags applied across all cloud resources |

#### VPC & Networking
| Variable | Type | Default | Description |
| :--- | :---: | :---: | :--- |
| `region` | `string` | `"us-east-1"` | AWS Region for resource deployment |
| `vpc_name` | `string` | `"media-watermark-vpc"` | Name tag assigned to the VPC |
| `vpc_cidr` | `string` | `"10.0.0.0/16"` | CIDR block for the dedicated VPC |
| `azs` | `list(string)` | `["us-east-1a", "us-east-1b", "us-east-1c"]` | Availability Zones for multi-AZ subnet deployment |
| `public_subnets` | `list(string)` | `["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]` | Public Subnet CIDRs for Internet Gateway egress |
| `private_subnets` | `list(string)` | `["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]` | Private Subnet CIDRs for Lambda ENIs & Batch workers |
| `enable_nat_gateway` | `bool` | `true` | Provision NAT Gateway for private subnet outbound access |
| `single_nat_gateway` | `bool` | `true` | Single NAT Gateway across AZs for cost optimization |
| `enable_s3_endpoint` | `bool` | `true` | S3 Gateway VPC Endpoint to avoid NAT data charges |

#### Storage (Amazon S3)
| Variable | Type | Default | Description |
| :--- | :---: | :---: | :--- |
| `source_bucket_prefix` | `string` | `"source-bucket"` | Prefix for the source media uploads S3 bucket |
| `destination_bucket_prefix` | `string` | `"destination-bucket"` | Prefix for the watermarked output media S3 bucket |
| `lambda_code_bucket_prefix` | `string` | `"job-submit-code"` | Prefix for the Lambda deployment artifact S3 bucket |
| `s3_force_destroy` | `bool` | `false` | Prevent accidental S3 bucket deletion in production |
| `s3_versioning_enabled` | `string` | `"Enabled"` | S3 object versioning status (`Enabled` or `Suspended`) |
| `s3_cors_max_age_seconds` | `number` | `3000` | CORS preflight request cache duration in seconds |

#### Queuing & Event Buffering (Amazon SQS)
| Variable | Type | Default | Description |
| :--- | :---: | :---: | :--- |
| `sqs_queue_name` | `string` | `"job-queue"` | Name of the main ingestion SQS queue |
| `sqs_visibility_timeout_seconds` | `number` | `180` | SQS visibility timeout in seconds (>= Lambda timeout) |
| `sqs_message_retention_seconds` | `number` | `345600` | SQS message retention period (4 days) |
| `sqs_max_receive_count` | `number` | `3` | Max delivery attempts before routing to Dead Letter Queue |
| `sqs_dlq_retention_seconds` | `number` | `1209600` | Retention for poison messages in DLQ (14 days) |
| `sqs_receive_wait_time_seconds` | `number` | `20` | Long polling wait duration for receive message calls |
| `sqs_max_message_size` | `number` | `262144` | Maximum message size in bytes (256 KB) |
| `sqs_batch_size` | `number` | `10` | Max SQS records delivered per Lambda invocation batch |
| `sqs_batch_window_seconds` | `number` | `5` | Max batching window in seconds for event source mapping |

#### State Tracking (Amazon DynamoDB)
| Variable | Type | Default | Description |
| :--- | :---: | :---: | :--- |
| `dynamodb_table_name` | `string` | `"media-watermark-records"` | DynamoDB table for job state tracking |
| `dynamodb_billing_mode` | `string` | `"PAY_PER_REQUEST"` | On-Demand auto-scaling billing mode |
| `dynamodb_ttl_attribute_name` | `string` | `"TimeToExist"` | Name of the DynamoDB TTL timestamp attribute |
| `dynamodb_ttl_enabled` | `bool` | `true` | Automated item expiration via TTL |
| `dynamodb_pitr_enabled` | `bool` | `true` | Point-In-Time Recovery continuous automated backups |

#### Orchestration & Ingestion (AWS Lambda)
| Variable | Type | Default | Description |
| :--- | :---: | :---: | :--- |
| `lambda_function_name` | `string` | `"watermark-job-submit"` | Name of the job submitter Lambda function |
| `lambda_runtime` | `string` | `"python3.12"` | Python runtime for the Lambda function |
| `lambda_timeout` | `number` | `30` | Lambda execution timeout in seconds |
| `lambda_memory_size` | `number` | `256` | Lambda memory allocation in MB |
| `default_watermark_text` | `string` | `"CONFIDENTIAL"` | Fallback watermark text when not specified |
| `default_watermark_type` | `string` | `"text"` | Default watermark mode: `text`, `image`, or `both` |
| `default_watermark_position` | `string` | `"bottom-right"` | Default placement (`bottom-right`, `center`, etc.) |
| `default_watermark_opacity` | `string` | `"0.8"` | Default watermark opacity from `0.0` to `1.0` |

#### AWS Batch & Container Compute
| Variable | Type | Default | Description |
| :--- | :---: | :---: | :--- |
| `batch_compute_environment_name` | `string` | `"batch-compute"` | Name suffix for AWS Batch Fargate environment |
| `batch_job_queue_name` | `string` | `"batch-job-queue"` | Name of the AWS Batch job queue |
| `batch_job_definition_name` | `string` | `"batch-job-definition"` | Name of the AWS Batch job definition |
| `batch_max_vcpus` | `number` | `16` | Maximum vCPUs for Batch compute auto-scaling |
| `batch_default_vcpu` | `string` | `"2.0"` | Default vCPU allocated per Batch task |
| `batch_default_memory` | `string` | `"4096"` | Default memory (MiB) allocated per Batch task |
| `batch_ephemeral_storage_gb` | `number` | `50` | Ephemeral disk space (GiB) for Fargate transcode tasks |
| `batch_log_retention_days` | `number` | `14` | CloudWatch log retention in days for `/aws/batch/job` |
| `ecr_repository_name` | `string` | `"batch_job"` | Name of the Amazon ECR container repository |
| `ecr_image_tag_mutability` | `string` | `"MUTABLE"` | Tag mutability for ECR repository |
| `ecr_scan_on_push` | `bool` | `true` | Automated CVE vulnerability scanning on image push |

#### Operational Alarms (Amazon CloudWatch)
| Variable | Type | Default | Description |
| :--- | :---: | :---: | :--- |
| `enable_alarms` | `bool` | `true` | Provision CloudWatch alarms for DLQ & Lambda errors |
| `alarm_evaluation_periods` | `number` | `1` | Evaluation periods before triggering CloudWatch alarms |
| `alarm_period_seconds` | `number` | `60` | Period in seconds over which alarm statistic is applied |

---

### Root Terraform Outputs (`terraform/outputs.tf`)

| Output Name | Type | Description |
| :--- | :---: | :--- |
| `source_bucket_name` | `string` | Source S3 bucket for incoming raw media uploads |
| `destination_bucket_name` | `string` | Destination S3 bucket for processed watermarked media |
| `sqs_queue_name` | `string` | Main SQS queue buffering S3 ObjectCreated events |
| `sqs_dlq_name` | `string` | SQS Dead Letter Queue buffering poison messages |
| `sqs_dlq_url` | `string` | HTTP endpoint URL of the SQS Dead Letter Queue |
| `dynamodb_table_name` | `string` | DynamoDB table tracking job state, timestamps & metadata |
| `lambda_function_name` | `string` | Name of the orchestrator Lambda function |
| `batch_job_queue_name` | `string` | Name of the AWS Batch job queue |
| `job_queue_arn` | `string` | ARN of the AWS Batch job queue |
| `batch_job_definition_name` | `string` | Name of the AWS Batch job definition |
| `job_definition_arn` | `string` | ARN of the AWS Batch job definition |
| `ecr_repository_url` | `string` | ECR repository URL hosting the Batch container image |
| `vpc_id` | `string` | ID of the provisioned multi-AZ VPC |
| `private_subnet_ids` | `list(string)` | Private subnets hosting Lambda ENIs and Batch Fargate tasks |

---

### Lambda Environment Variables

| Variable | Description | Source / Default |
| :--- | :--- | :--- |
| `REGION` | AWS Region | `var.region` |
| `JOB_QUEUE_ARN` | Target AWS Batch Job Queue ARN | `aws_batch_job_queue.batch_job_queue.arn` |
| `JOB_DEFINITION_ARN` | Target AWS Batch Job Definition ARN | `aws_batch_job_definition.batch_job_definition.arn` |
| `DYNAMODB_TABLE` | State Tracking Table | `module.job_metadata_state.name` (`media-watermark-records`) |
| `DESTINATION_BUCKET` | Target S3 Bucket for Watermarked Output | `module.destination_bucket.bucket` |
| `DEFAULT_WATERMARK_TEXT` | Fallback watermark string | `var.default_watermark_text` (`"CONFIDENTIAL"`) |
| `DEFAULT_WATERMARK_TYPE` | Default watermark mode | `var.default_watermark_type` (`"text"`) |
| `DEFAULT_WATERMARK_POSITION`| Default overlay positioning | `var.default_watermark_position` (`"bottom-right"`) |
| `DEFAULT_WATERMARK_OPACITY` | Default overlay opacity | `var.default_watermark_opacity` (`"0.8"`) |
| `WATERMARK_IMAGE_BUCKET` | Optional S3 bucket containing logo overlay | `""` |
| `WATERMARK_IMAGE_KEY` | Optional S3 key for logo overlay PNG | `""` |
| `DYNAMODB_TTL_DAYS` | Days before DynamoDB items expire | `30` |
| `LOG_LEVEL` | Logging verbosity (`DEBUG`, `INFO`, `WARNING`) | `INFO` |

---

### Batch Container CLI & Environment Options (`src/batch-job/main.py`)

| CLI Argument | Environment Fallback | Description | Default |
| :--- | :--- | :--- | :--- |
| `--input-bucket` | `INPUT_BUCKET` | Source S3 bucket name | *Required* |
| `--input-key` | `INPUT_KEY` | Source S3 object key | *Required* |
| `--output-bucket` | `OUTPUT_BUCKET` | Destination S3 bucket name | *Required* |
| `--output-key` | `OUTPUT_KEY` | Destination S3 object key | `watermarked/{input_key}` |
| `--watermark-type` | `WATERMARK_TYPE` | Type of watermark (`text`, `image`, `both`) | `text` |
| `--watermark-text` | `WATERMARK_TEXT` | Text to render overlay | `CONFIDENTIAL` |
| `--watermark-image-bucket` | `WATERMARK_IMAGE_BUCKET` | S3 bucket containing watermark logo | `""` |
| `--watermark-image-key` | `WATERMARK_IMAGE_KEY` | S3 key containing watermark logo PNG | `""` |
| `--position` | `WATERMARK_POSITION` | Placement (`bottom-right`, `bottom-left`, `top-right`, `top-left`, `center`) | `bottom-right` |
| `--opacity` | `WATERMARK_OPACITY` | Opacity from `0.0` to `1.0` | `0.8` |
| `--font-size` | `FONT_SIZE` | Font size in pixels | `28` |
| `--font-color` | `FONT_COLOR` | Font color | `white` |
| `--enable-box` | `ENABLE_BOX` | Render contrast bounding box behind text | `true` |
| `--box-color` | `BOX_COLOR` | Background box color & alpha | `black@0.4` |
| `--margin` | `WATERMARK_MARGIN` | Margin offset in pixels | `24` |

---

## Verification & Testing

### 1. Run Automated Unit Tests

The test suite validates string escaping, compute sizing, S3 event extraction, container overrides, and DynamoDB records without requiring AWS connectivity:

```bash
python3 -m unittest discover tests -v
```

Expected result:
```text
Ran 18 tests in 0.015s
OK
```

### 2. End-to-End Processing Test

Upload a sample video to your provisioned source bucket:

```bash
# Retrieve generated bucket names from Terraform
SOURCE_BUCKET=$(terraform -chdir=terraform output -raw source_bucket_name 2>/dev/null || echo "source-bucket-us-east-1-<your-account-id>")
DEST_BUCKET=$(terraform -chdir=terraform output -raw destination_bucket_name 2>/dev/null || echo "destination-bucket-us-east-1-<your-account-id>")

# Upload sample file
aws s3 cp sample.mp4 s3://${SOURCE_BUCKET}/uploads/sample.mp4
```

### 3. Verify DynamoDB State Tracking

Inspect the state stored in DynamoDB:

```bash
aws dynamodb scan \
  --table-name media-watermark-records \
  --query "Items[*].{RecordId:RecordId.S, filename:filename.S, status:status.S, updated_at:updated_at.S}" \
  --output table
```

### 4. Monitor CloudWatch Logs

Stream live FFmpeg execution logs from AWS Batch:

```bash
aws logs tail /aws/batch/job --follow
```

### 5. Verify Output

Confirm the watermarked output is delivered to the destination bucket:

```bash
aws s3 ls s3://${DEST_BUCKET}/watermarked/uploads/
```

---

## Live Deployment & Pipeline Walkthrough

The following walkthrough demonstrates the end-to-end execution of the media watermarking pipeline across the AWS Console and terminal, verified in `us-east-1` (Account `344626620590`).

### 1. Terraform Apply & Infrastructure Provisioning
Provisioning 74 managed cloud resources across networking, storage, compute, and security with zero configuration drift:

![Terraform Apply Output](screenshots/Screenshot%20from%202026-11-01%2010-16-38.png)

* **Key Observations**:
  * `Apply complete! Resources: 74 added, 0 changed, 0 destroyed.`
  * Successfully exports all deployment ARNs, SQS queue URLs, ECR repository URLs, and S3 bucket identifiers.

---

### 2. Multi-Bucket Storage Architecture (Amazon S3)
Three isolated S3 buckets provisioned with versioning, public access blocks, and server-side encryption:

![Amazon S3 Buckets](screenshots/Screenshot%20from%202026-11-01%2010-18-00.png)

* **Key Observations**:
  * `source-bucket-us-east-1-344626620590`: Primary ingestion bucket configured with S3 Event Notifications to SQS.
  * `destination-bucket-us-east-1-344626620590`: Target bucket for processed media with automated multipart abort lifecycle rules.
  * `job-submit-code-us-east-1-344626620590`: Dedicated artifact bucket storing versioned Lambda function deployment packages.

---

### 3. Media Ingestion & Event Notification Trigger
Uploading a high-definition video file to the source S3 bucket triggers the automated serverless pipeline:

![S3 Upload Ingestion](screenshots/Screenshot%20from%202026-11-01%2010-19-50.png)

* **Key Observations**:
  * `SampleVideo_1280x720_5mb.mp4` (5.0 MB) uploaded directly to `s3://source-bucket-us-east-1-344626620590`.
  * S3 immediately fires an `s3:ObjectCreated:Put` event notification buffered into the Amazon SQS `job-queue`.

---

### 4. Managed Serverless Compute Environment (AWS Batch & Fargate)
The dedicated AWS Batch compute environment running on AWS Fargate:

![AWS Batch Compute Environment](screenshots/Screenshot%20from%202026-11-01%2010-21-20.png)

* **Key Observations**:
  * Compute Environment: `media-watermark-batch-compute`.
  * Provisioning Model: Serverless Fargate in private VPC subnets with `assignPublicIp = "DISABLED"`.
  * Status: `Valid` | State: `Enabled` | Max Capacity: 16 vCPUs auto-scaling.

---

### 5. Job Queue & Dynamic Job Orchestration
The AWS Batch job queue receiving dispatched tasks from the Lambda orchestrator:

![AWS Batch Job Queue Overview](screenshots/Screenshot%20from%202026-11-01%2010-20-31.png)

* **Key Observations**:
  * Job Queue: `batch-job-queue` (Priority 1) linked to the Fargate compute environment.
  * Live status transitions from `Starting` -> `Running` -> `Succeeded: 1` with 0 failures.

---

### 6. Transcoding Telemetry & Execution (Amazon CloudWatch Logs)
Detailed execution telemetry streamed in real time from the containerized FFmpeg transcode task:

![CloudWatch Logs FFmpeg Transcoding](screenshots/Screenshot%20from%202026-11-01%2010-24-03.png)

* **Key Observations**:
  * Real-time FFmpeg encoding frames: `frame= 739 fps= 26 q=-1.0 size= 4817kB time=00:00:29.56 bitrate=1334.7kbits/s speed=1.05x`.
  * Multipart S3 streaming upload: `Transfer 'SampleVideo_1280x720_5mb.mp4': 100.0% (4.7/4.7 MB)`.
  * Clean task completion: `=== AWS Batch Watermark Processing Completed Successfully ===`.

---

### 7. Processed Media Delivery (Destination S3 Bucket)
The final watermarked media delivered to the destination S3 bucket:

![S3 Destination Bucket Delivery](screenshots/Screenshot%20from%202026-11-01%2010-23-10.png)

* **Key Observations**:
  * Processed asset delivered to `s3://destination-bucket-us-east-1-344626620590/watermarked/SampleVideo_1280x720_5mb.mp4`.
  * Encoded size: `4.7 MB` with optimized H.264 stream and `+faststart` metadata for instant web streaming.

---

### 8. Rendered Watermark Output Verification
Playback verification of the output video with the burned-in watermark overlay:

![Watermarked Video Playback](screenshots/Screenshot%20from%202026-11-01%2010-25-59.png)

* **Key Observations**:
  * High-contrast `"CONFIDENTIAL"` watermark burned cleanly into the bottom-right corner with semi-transparent bounding box.
  * Original 720p video stream and AAC audio preserved with optimal quality.

---

## Operational Runbook & Troubleshooting

### Issue: ECR Build Timeout during `terraform apply`
* **Cause**: Slow network connection downloading Debian packages or uploading the ~500 MB image.
* **Resolution**:
  1. Build and push the image out-of-band using the interactive script:
     ```bash
     cd src/batch-job
     bash artifact_push.sh us-east-1
     ```
  2. The script includes a smart cache check (`aws ecr describe-images`). Once the `latest` tag exists in ECR, future runs of `artifact_push.sh` or `terraform apply` will complete in **~1 second**.

### Issue: Batch Job Status `FAILED` with Container Exit Code 137
* **Cause**: Container Out-Of-Memory (OOM) error caused by processing high-resolution (4K/8K) video files with insufficient RAM.
* **Resolution**: The default configuration allocates **2.0 vCPU / 4096 MiB RAM**. For large files, update `resourceRequirements` in `terraform/main.tf` to `VCPU = "4.0"` and `MEMORY = "8192"`.

### Issue: SQS Messages Accumulate without Invoking Lambda
* **Cause**: SQS Event Source Mapping is disabled or IAM permissions are missing.
* **Resolution**:
  1. Verify the mapping status:
     ```bash
     aws lambda list-event-source-mappings --function-name watermark-job-submit
     ```
  2. Confirm `${var.project_name}-lambda-role` has `sqs:ReceiveMessage`, `sqs:DeleteMessage`, and `sqs:GetQueueAttributes` on `module.job_queue.arn`.

### Issue: Lambda Fails with `batch:TagResource` AccessDeniedException
* **Cause**: Submitting jobs with `tags={...}` requires the caller IAM role to have `batch:TagResource` on the job definition and job ARNs.
* **Resolution**:
  1. Ensure `batch:TagResource` is present in the `${var.project_name}-lambda-policy` under `BatchSubmitJob` in [`terraform/main.tf`](file:///home/shiv/mohit/aws-batch/terraform/main.tf).
  2. The Lambda function automatically retries submitting the job without tags if `batch:TagResource` is denied, ensuring jobs are not dropped.

---

## Clean-Up / Teardown

To permanently delete all deployed cloud infrastructure:

```bash
cd terraform

# Empty S3 buckets if force_destroy is disabled
aws s3 rm s3://${SOURCE_BUCKET} --recursive
aws s3 rm s3://${DEST_BUCKET} --recursive

# Destroy infrastructure
terraform destroy -auto-approve
```

---

## License

This project is licensed under the Apache 2.0 License.
