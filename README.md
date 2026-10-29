# Event-Driven Media Watermarking Pipeline on AWS Batch & Fargate

[![Terraform](https://img.shields.io/badge/Terraform-1.11+-623CE4.svg?logo=terraform)](https://www.terraform.io/)
[![Python](https://img.shields.io/badge/Python-3.12-3776AB.svg?logo=python)](https://www.python.org/)
[![Docker](https://img.shields.io/badge/Docker-Fargate_Ready-2496ED.svg?logo=docker)](https://www.docker.com/)
[![FFmpeg](https://img.shields.io/badge/FFmpeg-6.1+-007808.svg?logo=ffmpeg)](https://ffmpeg.org/)
[![AWS](https://img.shields.io/badge/AWS-Batch_%7C_Lambda_%7C_DynamoDB_%7C_SQS_%7C_S3-FF9900.svg?logo=amazon-aws)](https://aws.amazon.com/)
[![Tests](https://img.shields.io/badge/Tests-16%2F16_Passing-brightgreen.svg)](tests/)

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
                                            [ Amazon SQS ]                         │
                                             (job-queue)                           │
                                                    │                              │
                                                    │ 3. Event Source Mapping      │
                                                    │    (Batch Size: 10)          │
                                                    ▼                              │
                                            [ AWS Lambda ]                         │
                                        (watermark-job-submit)                     │
                                                    │                              │
                                    ┌───────────────┴──────────────┐               │
                                    │ 4. Track State               │ 5. Submit Job │
                                    ▼                              ▼               │
                         [ Amazon DynamoDB ]              [ AWS Batch Queue ]      │
                          (invoice-records)               (batch-job-queue)        │
                           - Hash: RecordId                        │               │
                           - Range: filename                       ▼               │
                           - TTL: TimeToExist             [ AWS Batch Compute ]    │
                                                        (Fargate - Auto Scaled)    │
                                                                   │               │
                                                                   ▼               │
                                                          [ Fargate Task ]         │
                                                          - ECR Container Image    │
                                                          - S3 Multipart Download  │
                                                          - FFmpeg Transcoding     │
                                                          - S3 Multipart Upload    │
                                                                   │               │
                                    6. Deliver Output              ▼               │
                                 ◄───────────────────── [ S3 Destination Bucket ]  │
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
4. **State Persistence**: Lambda logs an initial record into Amazon DynamoDB (`invoice-records`) with status `SUBMITTED`, metadata attributes, and automated TTL (`TimeToExist`).
5. **Batch Execution**: AWS Batch dispatches the container to a serverless AWS Fargate compute environment:
   - The container pulls the application image from Amazon ECR.
   - The Python worker (`src/batch-job/main.py`) streams the media from S3 via multi-threaded multipart download (`TransferConfig`).
   - FFmpeg applies text watermarks (via `drawtext` with TrueType fonts, box contrast, and coordinate positioning) and/or image logos (via `overlay` with dynamic scaling and opacity).
   - Video streams are encoded with `libx264` (`preset medium`, `crf 23`, `pix_fmt yuv420p`, `-movflags +faststart`) and audio is preserved via `aac` (`-map 0:a?` to gracefully support silent media).
6. **Delivery**: The processed media is uploaded to the destination S3 bucket using multipart upload with S3 Server-Side Encryption (`AES256`).

---

## Repository Structure

```
.
├── README.md                           # Production architecture and operations guide
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
│   ├── variables.tf                    # Input variable declarations
│   ├── outputs.tf                      # Output resource exports
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
│       └── vpc/                        # Multi-AZ VPC with NAT Gateway module
└── tests/
    ├── test_main.py                    # Unit tests for Batch FFmpeg worker
    └── test_job_submit_lambda.py       # Unit tests for Lambda submitter & DynamoDB
```

---

## Infrastructure Specifications

### 1. Networking & VPC
* **CIDR Block**: `10.0.0.0/16` across 3 Availability Zones (`us-east-1a`, `us-east-1b`, `us-east-1c`).
* **Subnets**: 3 public subnets (`10.0.1.0/24`, `10.0.2.0/24`, `10.0.3.0/24`) and 3 private subnets (`10.0.4.0/24`, `10.0.5.0/24`, `10.0.6.0/24`).
* **Internet Connectivity**: Internet Gateway for public subnets; Single NAT Gateway (`enable_nat_gateway = true`) providing secure egress for Lambda functions placed in private subnets.
* **Security Groups**:
  * `batch-job-security-group`: Outbound all traffic (`-1` to `0.0.0.0/0`) for Fargate container orchestration and S3 HTTPS transfers.
  * `lambda-sg`: Outbound HTTPS (`tcp/443` to `0.0.0.0/0`) for secure communication with AWS service endpoints.

### 2. Storage & Queuing
* **Amazon S3**:
  * Source Media Bucket: `source-bucket-${region}-${account_id}` with Versioning enabled and S3 bucket notifications triggering SQS.
  * Destination Media Bucket: `destination-bucket-${region}-${account_id}` with Versioning enabled.
  * Lambda Code Bucket: `job-submit-code-${region}-${account_id}`.
* **Amazon SQS**:
  * Main Queue: `job-queue` (Max message size: 256 KB, retention: 4 days, visibility timeout: 180s).
  * Policy: Explicit `sqs:SendMessage` authorized strictly for `s3.amazonaws.com` restricted by `aws:SourceArn`.

### 3. State Management & Compute
* **Amazon DynamoDB**:
  * Table: `invoice-records`
  * Billing Mode: `PAY_PER_REQUEST` (On-Demand auto-scaling)
  * Partition Key: `RecordId` (String - AWS Batch Job ID or UUID)
  * Sort Key: `filename` (String - Source S3 object key)
  * TTL: Enabled on `TimeToExist` (automated deletion after retention expires)
* **AWS Lambda**:
  * Function Name: `watermark-job-submit`
  * Runtime: `python3.12` | Memory: 256 MB | Timeout: 30s
* **AWS Batch & Fargate**:
  * Compute Environment: Managed Fargate environment scaling up to 16 vCPUs.
  * Job Queue: `batch-job-queue` (Priority 1).
  * Job Definition: `batch-job-definition` (Default allocation: **2.0 vCPU** / **4096 MiB RAM**; overridable per media type).

---

## Security & Compliance Architecture

* **Principle of Least Privilege (IAM)**:
  * **Lambda Role (`job-submit-function-iam-role`)**: Strictly scoped to write CloudWatch logs, invoke `batch:SubmitJob` / `batch:DescribeJobs` on specific queue/definition ARNs, perform `dynamodb:PutItem` / `dynamodb:UpdateItem` on the state table, consume SQS messages, and manage VPC ENIs.
  * **Container Job Role (`batch_job_s3_policy`)**: Scoped to `s3:GetObject` and `s3:ListBucket` on the source bucket and `s3:PutObject` on the destination bucket.
  * **Separation of Roles**: The ECS Task Execution Role (ECR pull, CloudWatch logging) is decoupled from the Container Task Job Role (runtime S3 read/write permissions).
* **Container Hardening**:
  * Base Image: `python:3.12-slim-bookworm` with minimal package surface.
  * Non-Root User: Runs under dedicated unprivileged system user `appuser:appgroup` (UID/GID `10001`).
  * Signal Trapping: Python entrypoint traps `SIGTERM` and `SIGINT` to gracefully terminate FFmpeg child processes and clean temporary scratch storage (`/tmp`) during ECS instance termination or spot reclamation.
* **ECR Security**: Repository configured with `image_tag_mutability = "IMMUTABLE"` and `scan_on_push = true` for automated CVE vulnerability detection.

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

### Step 2: Initialize & Review Terraform

```bash
cd terraform

# Initialize provider plugins and modules
terraform init

# Validate syntax and configuration
terraform validate

# Review proposed changes
terraform plan -out=tfplan
```

### Step 3: Apply Infrastructure

```bash
terraform apply tfplan
```

*During execution, Terraform provisions the VPC, NAT Gateway, S3 buckets, SQS queues, DynamoDB table, Lambda function, and ECR repository.*
*The `null_resource.push_image_to_ecr` provisioner will automatically build `src/batch-job/Dockerfile` and push the container image to Amazon ECR.*

---

## Configuration & Parameters Reference

### Root Terraform Variables (`terraform/variables.tf`)

| Variable | Type | Default | Description |
| :--- | :---: | :---: | :--- |
| `region` | `string` | `"us-east-1"` | AWS Region for resource deployment |
| `azs` | `list(string)` | `["us-east-1a", "us-east-1b", "us-east-1c"]` | Availability Zones for VPC subnets |
| `public_subnets` | `list(string)` | `["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]` | Public Subnet CIDRs (Batch Fargate) |
| `private_subnets` | `list(string)` | `["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]` | Private Subnet CIDRs (Lambda ENIs) |

### Lambda Environment Variables

| Variable | Description | Source / Default |
| :--- | :--- | :--- |
| `REGION` | AWS Region | `var.region` |
| `JOB_QUEUE_ARN` | Target AWS Batch Job Queue ARN | `aws_batch_job_queue.batch_job_queue.arn` |
| `JOB_DEFINITION_ARN` | Target AWS Batch Job Definition ARN | `aws_batch_job_definition.batch_job_definition.arn` |
| `DYNAMODB_TABLE` | State Tracking Table | `module.job_metadata_state.name` (`invoice-records`) |
| `DESTINATION_BUCKET` | Target S3 Bucket for Watermarked Output | `module.destination_bucket.bucket` |
| `DEFAULT_WATERMARK_TEXT` | Fallback watermark string | `"CONFIDENTIAL"` |

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
Ran 16 tests in 0.015s
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
  --table-name invoice-records \
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
  2. Confirm `job-submit-function-iam-role` has `sqs:ReceiveMessage`, `sqs:DeleteMessage`, and `sqs:GetQueueAttributes` on `module.job_queue.arn`.

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
