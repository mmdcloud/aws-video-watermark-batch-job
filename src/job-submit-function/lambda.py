#!/usr/bin/env python3
"""
================================================================================
AWS Lambda Function: Media Watermark Job Submitter & State Tracker
================================================================================
Location: src/job-submit-function/lambda.py
Handler:  lambda.lambda_handler

Role & Architecture:
  1. Ingestion:
     - Ingests media processing triggers from Amazon S3 (ObjectCreated events),
       Amazon SQS (event queue with ReportBatchItemFailures), or direct JSON
       invocations (API Gateway, Step Functions, or CLI).
  2. Batch Orchestration:
     - Dynamically computes compute requirements (vCPU & Memory) based on
       media extension (video vs image).
     - Assembles all required CLI arguments and environment variables for the
       AWS Batch worker in `src/batch-job/main.py`.
     - Submits jobs to AWS Batch via `boto3.client('batch').submit_job`.
  3. State Management (Amazon DynamoDB):
     - Maintains complete lifecycle state (SUBMITTED, FAILED, etc.) in the
       configured DynamoDB table (`invoice-records`).
     - Uses Hash Key `RecordId` (Job ID or deterministic UUID) and Range Key
       `filename` (Source S3 Key).
     - Sets TTL (`TimeToExist`) for automated table item lifecycle management.
================================================================================
"""

import json
import logging
import os
import re
import time
import urllib.parse
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

# ==============================================================================
# Configuration & Global Setup
# ==============================================================================
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
logger = logging.getLogger("job-submit-function")
logger.setLevel(LOG_LEVEL)

# Standardized logging formatter if running outside default AWS Lambda logger
if not logger.handlers:
    handler = logging.StreamHandler()
    handler.setFormatter(
        logging.Formatter("%(asctime)s [%(levelname)s] [%(name)s] %(message)s")
    )
    logger.addHandler(handler)

# Adaptive retry configuration for AWS SDK clients
boto_config = Config(
    retries={"max_attempts": 5, "mode": "adaptive"},
    connect_timeout=5,
    read_timeout=15,
)

# Initialize AWS clients
batch_client = boto3.client("batch", config=boto_config)
dynamodb_resource = boto3.resource("dynamodb", config=boto_config)

# Environment Variables & Defaults
JOB_QUEUE = os.getenv("JOB_QUEUE_ARN") or os.getenv(
    "BATCH_JOB_QUEUE", "batch-job-queue"
)
JOB_DEFINITION = os.getenv("JOB_DEFINITION_ARN") or os.getenv(
    "BATCH_JOB_DEFINITION", "batch-job-definition"
)
DYNAMODB_TABLE_NAME = os.getenv("DYNAMODB_TABLE") or os.getenv(
    "JOB_METADATA_TABLE", "media-watermark-records"
)
DESTINATION_BUCKET = os.getenv("DESTINATION_BUCKET", "")
DEFAULT_WATERMARK_TEXT = os.getenv("DEFAULT_WATERMARK_TEXT", "CONFIDENTIAL")
DEFAULT_WATERMARK_TYPE = os.getenv("DEFAULT_WATERMARK_TYPE", "text")
DEFAULT_WATERMARK_POSITION = os.getenv(
    "DEFAULT_WATERMARK_POSITION", "bottom-right"
)
DEFAULT_WATERMARK_OPACITY = float(os.getenv("DEFAULT_WATERMARK_OPACITY", "0.8"))
WATERMARK_IMAGE_BUCKET = os.getenv("WATERMARK_IMAGE_BUCKET", "")
WATERMARK_IMAGE_KEY = os.getenv("WATERMARK_IMAGE_KEY", "")
TTL_RETENTION_DAYS = int(os.getenv("DYNAMODB_TTL_DAYS", "30"))

# Media Classification Constants
VIDEO_EXTENSIONS = {".mp4", ".mov", ".mkv", ".avi", ".webm", ".m4v", ".flv"}
IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".tiff", ".bmp"}
SUPPORTED_EXTENSIONS = VIDEO_EXTENSIONS | IMAGE_EXTENSIONS


# ==============================================================================
# Helper Functions: Sanitization, Parsing & Resource Allocation
# ==============================================================================
def sanitize_batch_job_name(prefix: str, key: str) -> str:
    """
    Sanitizes string to satisfy AWS Batch jobName requirements:
    Matches ^[a-zA-Z0-9_-]{1,128}$
    """
    base = os.path.basename(key)
    sanitized = re.sub(r"[^a-zA-Z0-9_-]", "_", base)
    name = f"{prefix}-{sanitized}-{int(time.time())}"
    return name[:128].strip("_-")


def is_video_file(file_key: str) -> bool:
    """Returns True if the file extension represents a video format."""
    ext = os.path.splitext(file_key)[1].lower()
    return ext in VIDEO_EXTENSIONS


def get_compute_requirements(is_video: bool) -> Tuple[str, str, int]:
    """
    Returns (vCPU, memory_mib, timeout_seconds) based on media type.
    - Video transcoding requires high compute (2.0 vCPU, 4096 MiB).
    - Image processing requires minimal compute (0.5 vCPU, 1024 MiB).
    """
    if is_video:
        vcpu = os.getenv("BATCH_VCPU_VIDEO", "2.0")
        memory = os.getenv("BATCH_MEMORY_VIDEO", "4096")
        timeout = int(os.getenv("BATCH_TIMEOUT_VIDEO", "7200"))
    else:
        vcpu = os.getenv("BATCH_VCPU_IMAGE", "0.5")
        memory = os.getenv("BATCH_MEMORY_IMAGE", "1024")
        timeout = int(os.getenv("BATCH_TIMEOUT_IMAGE", "600"))
    return vcpu, memory, timeout


def extract_s3_records(record_body: Dict[str, Any]) -> List[Tuple[str, str]]:
    """
    Extracts (bucket, decoded_key) tuples from:
      1. Direct S3 event notifications
      2. SQS records wrapping S3 event notifications
      3. SNS records wrapping S3 notifications inside SQS
    """
    results: List[Tuple[str, str]] = []

    # Case 1: SQS Body (JSON string or dict)
    if "body" in record_body:
        raw_body = record_body["body"]
        try:
            body_json = (
                json.loads(raw_body)
                if isinstance(raw_body, str)
                else raw_body
            )
            # Check for SNS wrapper
            if isinstance(body_json, dict) and "Message" in body_json:
                message_content = body_json["Message"]
                body_json = (
                    json.loads(message_content)
                    if isinstance(message_content, str)
                    else message_content
                )

            # Check for S3 Records inside JSON
            if isinstance(body_json, dict) and "Records" in body_json:
                for rec in body_json["Records"]:
                    if "s3" in rec:
                        bucket = rec["s3"]["bucket"]["name"]
                        raw_key = rec["s3"]["object"]["key"]
                        decoded_key = urllib.parse.unquote_plus(raw_key)
                        results.append((bucket, decoded_key))
        except (json.JSONDecodeError, KeyError, TypeError) as e:
            logger.warning(f"Could not parse SQS message body for S3 events: {e}")

    # Case 2: Direct S3 Event Record
    elif "s3" in record_body:
        bucket = record_body["s3"]["bucket"]["name"]
        raw_key = record_body["s3"]["object"]["key"]
        decoded_key = urllib.parse.unquote_plus(raw_key)
        results.append((bucket, decoded_key))

    return results


# ==============================================================================
# DynamoDB State Management
# ==============================================================================
def get_dynamodb_table() -> Optional[Any]:
    """Retrieves the DynamoDB Table resource with error handling."""
    if not DYNAMODB_TABLE_NAME:
        logger.warning(
            "DYNAMODB_TABLE_NAME is not configured; skipping DynamoDB state updates."
        )
        return None
    try:
        return dynamodb_resource.Table(DYNAMODB_TABLE_NAME)
    except Exception as e:
        logger.error(
            f"Failed to access DynamoDB table '{DYNAMODB_TABLE_NAME}': {e}"
        )
        return None


def record_job_state(
    record_id: str,
    filename: str,
    status: str,
    job_id: Optional[str] = None,
    job_name: Optional[str] = None,
    source_bucket: Optional[str] = None,
    destination_bucket: Optional[str] = None,
    destination_key: Optional[str] = None,
    media_type: Optional[str] = None,
    watermark_type: Optional[str] = None,
    watermark_text: Optional[str] = None,
    error_message: Optional[str] = None,
    execution_params: Optional[Dict[str, Any]] = None,
) -> bool:
    """
    Persists or updates the Batch job state in DynamoDB:
      - Hash Key:  RecordId (String)
      - Range Key: filename (String)
      - TTL:       TimeToExist (Number - Unix epoch seconds)
    """
    table = get_dynamodb_table()
    if not table:
        return False

    now_utc = datetime.now(timezone.utc)
    now_iso = now_utc.isoformat()
    ttl_epoch = int(now_utc.timestamp()) + (TTL_RETENTION_DAYS * 86400)

    item: Dict[str, Any] = {
        "RecordId": record_id,
        "filename": filename,
        "status": status,
        "updated_at": now_iso,
        "TimeToExist": ttl_epoch,
    }

    # Populate optional/metadata fields
    if job_id:
        item["job_id"] = job_id
    if job_name:
        item["job_name"] = job_name
    if source_bucket:
        item["source_bucket"] = source_bucket
        item["source_key"] = filename
    if destination_bucket:
        item["destination_bucket"] = destination_bucket
    if destination_key:
        item["destination_key"] = destination_key
    if media_type:
        item["media_type"] = media_type
    if watermark_type:
        item["watermark_type"] = watermark_type
    if watermark_text:
        item["watermark_text"] = watermark_text
    if error_message:
        item["error_message"] = error_message
    if execution_params:
        item["execution_params"] = json.dumps(execution_params)

    # Set created_at if this is a newly submitted job
    if status == "SUBMITTED":
        item["created_at"] = now_iso

    try:
        table.put_item(Item=item)
        logger.info(
            f"Successfully updated DynamoDB state [RecordId={record_id}, filename={filename}, status={status}]"
        )
        return True
    except ClientError as e:
        logger.error(
            f"DynamoDB ClientError updating item (RecordId={record_id}, filename={filename}): {e}"
        )
        return False
    except Exception as e:
        logger.exception(
            f"Unexpected error updating DynamoDB state (RecordId={record_id}): {e}"
        )
        return False


def update_job_status_by_id(
    job_id: str,
    status: str,
    status_reason: str = "",
    exit_code: Optional[int] = None,
    stopped_at: Optional[int] = None,
) -> bool:
    """
    Updates the execution status of an AWS Batch job in DynamoDB when notified
    via EventBridge (e.g. SUCCEEDED -> COMPLETED, FAILED -> FAILED).
    """
    table = get_dynamodb_table()
    if not table:
        return False

    try:
        resp = table.query(
            KeyConditionExpression="RecordId = :rid",
            ExpressionAttributeValues={":rid": job_id},
            Limit=1,
        )
        items = resp.get("Items", [])
        now_iso = datetime.now(timezone.utc).isoformat()

        if not items:
            logger.warning(
                f"No existing DynamoDB record found for RecordId={job_id}. Creating status record."
            )
            table.put_item(
                Item={
                    "RecordId": job_id,
                    "filename": "UNKNOWN",
                    "status": status,
                    "status_reason": status_reason,
                    "exit_code": exit_code,
                    "updated_at": now_iso,
                    "TimeToExist": int(time.time()) + (TTL_RETENTION_DAYS * 86400),
                }
            )
            return True

        filename = items[0]["filename"]
        update_expr = "SET #s = :status, updated_at = :now, status_reason = :reason"
        expr_attr_names = {"#s": "status"}
        expr_attr_values = {
            ":status": status,
            ":now": now_iso,
            ":reason": status_reason,
        }

        if exit_code is not None:
            update_expr += ", exit_code = :exit_code"
            expr_attr_values[":exit_code"] = exit_code

        if stopped_at:
            update_expr += ", completed_at = :stopped_at"
            expr_attr_values[":stopped_at"] = stopped_at

        table.update_item(
            Key={"RecordId": job_id, "filename": filename},
            UpdateExpression=update_expr,
            ExpressionAttributeNames=expr_attr_names,
            ExpressionAttributeValues=expr_attr_values,
        )
        logger.info(
            f"Successfully updated DynamoDB state [RecordId={job_id}, filename={filename}, status={status}]"
        )
        return True
    except Exception as e:
        logger.error(
            f"Failed to update DynamoDB completion state for JobId={job_id}: {e}"
        )
        return False


def handle_batch_state_change(event: Dict[str, Any]) -> Dict[str, Any]:
    """
    Processes EventBridge AWS Batch Job State Change events.
    """
    detail = event.get("detail", {})
    job_id = detail.get("jobId")
    batch_status = detail.get("status")
    status_reason = detail.get("statusReason", "")
    container = detail.get("container", {})
    exit_code = container.get("exitCode")
    stopped_at = detail.get("stoppedAt")

    logger.info(
        f"Processing EventBridge Batch Job State Change: JobId={job_id}, Status={batch_status}, Reason={status_reason}"
    )

    if not job_id or not batch_status:
        logger.warning("EventBridge event missing jobId or status.")
        return {"statusCode": 400, "message": "Missing jobId or status"}

    # Map Batch status to final pipeline status
    mapped_status = (
        "COMPLETED"
        if batch_status == "SUCCEEDED"
        else ("FAILED" if batch_status == "FAILED" else batch_status)
    )

    success = update_job_status_by_id(
        job_id=job_id,
        status=mapped_status,
        status_reason=status_reason,
        exit_code=exit_code,
        stopped_at=stopped_at,
    )

    return {
        "statusCode": 200 if success else 500,
        "jobId": job_id,
        "status": mapped_status,
        "updated": success,
    }


# ==============================================================================
# AWS Batch Submission Engine
# ==============================================================================
def build_container_overrides(
    input_bucket: str,
    input_key: str,
    output_bucket: str,
    output_key: str,
    watermark_type: str,
    watermark_text: str,
    watermark_image_bucket: str,
    watermark_image_key: str,
    position: str,
    opacity: float,
    font_size: int,
    font_color: str,
    enable_box: bool,
    box_color: str,
    margin: int,
    is_video: bool,
) -> Tuple[Dict[str, Any], int]:
    """
    Constructs containerOverrides precisely mapped to `src/batch-job/main.py`.
    Provides both command-line flags and environment variables for resilience.
    """
    vcpu, memory, timeout_seconds = get_compute_requirements(is_video)

    # Command arguments for src/batch-job/main.py
    command: List[str] = [
        "--input-bucket",
        input_bucket,
        "--input-key",
        input_key,
        "--output-bucket",
        output_bucket,
        "--output-key",
        output_key,
        "--watermark-type",
        watermark_type,
        "--watermark-text",
        watermark_text,
        "--position",
        position,
        "--opacity",
        str(opacity),
        "--font-size",
        str(font_size),
        "--font-color",
        font_color,
        "--box-color",
        box_color,
        "--margin",
        str(margin),
    ]

    if enable_box:
        command.append("--enable-box")

    if watermark_image_key:
        command.extend([
            "--watermark-image-bucket",
            watermark_image_bucket or input_bucket,
            "--watermark-image-key",
            watermark_image_key,
        ])

    # Environment variables overrides
    environment: List[Dict[str, str]] = [
        {"name": "INPUT_BUCKET", "value": input_bucket},
        {"name": "INPUT_KEY", "value": input_key},
        {"name": "OUTPUT_BUCKET", "value": output_bucket},
        {"name": "OUTPUT_KEY", "value": output_key},
        {"name": "WATERMARK_TYPE", "value": watermark_type},
        {"name": "WATERMARK_TEXT", "value": watermark_text},
        {"name": "WATERMARK_POSITION", "value": position},
        {"name": "WATERMARK_OPACITY", "value": str(opacity)},
        {"name": "FONT_SIZE", "value": str(font_size)},
        {"name": "FONT_COLOR", "value": font_color},
        {"name": "ENABLE_BOX", "value": str(enable_box).lower()},
        {"name": "BOX_COLOR", "value": box_color},
        {"name": "WATERMARK_MARGIN", "value": str(margin)},
        {"name": "LOG_LEVEL", "value": LOG_LEVEL},
    ]

    if watermark_image_key:
        environment.append({
            "name": "WATERMARK_IMAGE_BUCKET",
            "value": watermark_image_bucket or input_bucket,
        })
        environment.append({
            "name": "WATERMARK_IMAGE_KEY",
            "value": watermark_image_key,
        })

    container_overrides: Dict[str, Any] = {
        "command": command,
        "resourceRequirements": [
            {"type": "VCPU", "value": vcpu},
            {"type": "MEMORY", "value": memory},
        ],
        "environment": environment,
    }

    return container_overrides, timeout_seconds


def submit_batch_job(
    input_bucket: str,
    input_key: str,
    output_bucket: str,
    output_key: str,
    watermark_type: str = DEFAULT_WATERMARK_TYPE,
    watermark_text: str = DEFAULT_WATERMARK_TEXT,
    watermark_image_bucket: str = WATERMARK_IMAGE_BUCKET,
    watermark_image_key: str = WATERMARK_IMAGE_KEY,
    position: str = DEFAULT_WATERMARK_POSITION,
    opacity: float = DEFAULT_WATERMARK_OPACITY,
    font_size: int = 28,
    font_color: str = "white",
    enable_box: bool = True,
    box_color: str = "black@0.4",
    margin: int = 24,
) -> Dict[str, Any]:
    """
    Submits a watermark processing job to AWS Batch and records state in DynamoDB.
    """
    ext = os.path.splitext(input_key)[1].lower()
    if ext not in SUPPORTED_EXTENSIONS:
        raise ValueError(
            f"File extension '{ext}' for key '{input_key}' is not supported. "
            f"Supported extensions: {sorted(SUPPORTED_EXTENSIONS)}"
        )

    is_video = ext in VIDEO_EXTENSIONS
    media_type = "video" if is_video else "image"
    job_name = sanitize_batch_job_name("wm", input_key)

    container_overrides, timeout_seconds = build_container_overrides(
        input_bucket=input_bucket,
        input_key=input_key,
        output_bucket=output_bucket,
        output_key=output_key,
        watermark_type=watermark_type,
        watermark_text=watermark_text,
        watermark_image_bucket=watermark_image_bucket,
        watermark_image_key=watermark_image_key,
        position=position,
        opacity=opacity,
        font_size=font_size,
        font_color=font_color,
        enable_box=enable_box,
        box_color=box_color,
        margin=margin,
        is_video=is_video,
    )

    logger.info(
        f"Submitting AWS Batch Job '{job_name}' to queue '{JOB_QUEUE}' "
        f"using definition '{JOB_DEFINITION}' for s3://{input_bucket}/{input_key}..."
    )

    try:
        response = batch_client.submit_job(
            jobName=job_name,
            jobQueue=JOB_QUEUE,
            jobDefinition=JOB_DEFINITION,
            containerOverrides=container_overrides,
            retryStrategy={"attempts": 2},
            timeout={"attemptDurationSeconds": timeout_seconds},
            tags={
                "Application": "MediaWatermarking",
                "MediaType": media_type,
                "SourceBucket": input_bucket,
                "DestinationBucket": output_bucket,
            },
        )
    except Exception as e:
        # If tagging fails due to missing batch:TagResource IAM permission, retry without tags
        if "TagResource" in str(e):
            logger.warning(
                f"batch:TagResource permission not granted for '{job_name}'. Retrying submit_job without tags: {e}"
            )
            try:
                response = batch_client.submit_job(
                    jobName=job_name,
                    jobQueue=JOB_QUEUE,
                    jobDefinition=JOB_DEFINITION,
                    containerOverrides=container_overrides,
                    retryStrategy={"attempts": 2},
                    timeout={"attemptDurationSeconds": timeout_seconds},
                )
            except Exception as retry_err:
                logger.error(f"Failed to submit AWS Batch job '{job_name}' even without tags: {retry_err}")
                record_job_state(
                    record_id=f"failed-{int(time.time())}",
                    filename=input_key,
                    status="FAILED",
                    job_name=job_name,
                    source_bucket=input_bucket,
                    destination_bucket=output_bucket,
                    destination_key=output_key,
                    media_type=media_type,
                    error_message=str(retry_err),
                )
                raise
        else:
            logger.error(f"Failed to submit AWS Batch job '{job_name}': {e}")
            # Record failure state in DynamoDB
            record_job_state(
                record_id=f"failed-{int(time.time())}",
                filename=input_key,
                status="FAILED",
                job_name=job_name,
                source_bucket=input_bucket,
                destination_bucket=output_bucket,
                destination_key=output_key,
                media_type=media_type,
                error_message=str(e),
            )
            raise

    job_id = response["jobId"]
    logger.info(f"Successfully submitted AWS Batch job: ID={job_id}, Name={job_name}")

    # Maintain state in DynamoDB: RecordId = job_id, filename = input_key
    record_job_state(
        record_id=job_id,
        filename=input_key,
        status="SUBMITTED",
        job_id=job_id,
        job_name=job_name,
        source_bucket=input_bucket,
        destination_bucket=output_bucket,
        destination_key=output_key,
        media_type=media_type,
        watermark_type=watermark_type,
        watermark_text=watermark_text,
        execution_params={
            "jobQueue": JOB_QUEUE,
            "jobDefinition": JOB_DEFINITION,
            "timeoutSeconds": timeout_seconds,
            "position": position,
            "opacity": opacity,
        },
    )

    return response


# ==============================================================================
# AWS Lambda Handler
# ==============================================================================
def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    AWS Lambda Function Entrypoint.
    Handles:
      1. EventBridge AWS Batch Job State Change events (SUCCEEDED / FAILED)
      2. SQS messages (containing S3 upload events) with ReportBatchItemFailures
      3. Direct S3 event notifications
      4. Direct JSON invocation payloads
    """
    logger.info(f"Received invocation event: {json.dumps(event)[:600]}")

    # Scenario A: EventBridge AWS Batch Job State Change Event
    if (
        event.get("source") == "aws.batch"
        and event.get("detail-type") == "Batch Job State Change"
    ):
        return handle_batch_state_change(event)

    batch_item_failures: List[Dict[str, str]] = []
    processed_jobs: List[Dict[str, Any]] = []

    # Scenario B: Event-driven Records (SQS or S3)
    if "Records" in event and isinstance(event["Records"], list):
        for record in event["Records"]:
            message_id = record.get("messageId", "direct_s3_record")
            try:
                s3_items = extract_s3_records(record)
                if not s3_items:
                    logger.warning(
                        f"No valid S3 records found in event message {message_id}"
                    )
                    continue

                for in_bucket, in_key in s3_items:
                    ext = os.path.splitext(in_key)[1].lower()
                    if ext not in SUPPORTED_EXTENSIONS:
                        logger.info(
                            f"Skipping unsupported file extension: '{ext}' for s3://{in_bucket}/{in_key}"
                        )
                        continue

                    out_bucket = DESTINATION_BUCKET or in_bucket
                    out_key = f"watermarked/{in_key}"
                    wm_type = "both" if WATERMARK_IMAGE_KEY else DEFAULT_WATERMARK_TYPE

                    batch_resp = submit_batch_job(
                        input_bucket=in_bucket,
                        input_key=in_key,
                        output_bucket=out_bucket,
                        output_key=out_key,
                        watermark_type=wm_type,
                        watermark_text=DEFAULT_WATERMARK_TEXT,
                        watermark_image_bucket=WATERMARK_IMAGE_BUCKET,
                        watermark_image_key=WATERMARK_IMAGE_KEY,
                        position=DEFAULT_WATERMARK_POSITION,
                        opacity=DEFAULT_WATERMARK_OPACITY,
                    )

                    processed_jobs.append({
                        "jobId": batch_resp["jobId"],
                        "jobName": batch_resp["jobName"],
                        "source": f"s3://{in_bucket}/{in_key}",
                        "destination": f"s3://{out_bucket}/{out_key}",
                        "status": "SUBMITTED",
                    })

            except Exception as e:
                logger.exception(
                    f"Failed to process message {message_id}: {str(e)}"
                )
                batch_item_failures.append({"itemIdentifier": message_id})

        return {
            "statusCode": 200,
            "processedCount": len(processed_jobs),
            "submittedJobs": processed_jobs,
            "batchItemFailures": batch_item_failures,
        }

    # Scenario B: Direct JSON Invocation Payload
    try:
        in_bucket = event.get("input_bucket") or event.get("source_bucket")
        in_key = event.get("input_key") or event.get("key")

        if not in_bucket or not in_key:
            raise ValueError(
                "Missing required parameters 'input_bucket' and 'input_key' in event payload"
            )

        out_bucket = (
            event.get("output_bucket")
            or event.get("destination_bucket")
            or DESTINATION_BUCKET
            or in_bucket
        )
        out_key = event.get("output_key") or f"watermarked/{in_key}"
        wm_type = event.get("watermark_type", DEFAULT_WATERMARK_TYPE)
        wm_text = event.get("watermark_text", DEFAULT_WATERMARK_TEXT)
        wm_img_bucket = event.get(
            "watermark_image_bucket", WATERMARK_IMAGE_BUCKET
        )
        wm_img_key = event.get("watermark_image_key", WATERMARK_IMAGE_KEY)
        pos = event.get("position", DEFAULT_WATERMARK_POSITION)
        opacity = float(event.get("opacity", DEFAULT_WATERMARK_OPACITY))
        font_size = int(event.get("font_size", 28))
        font_color = event.get("font_color", "white")
        enable_box = bool(event.get("enable_box", True))
        box_color = event.get("box_color", "black@0.4")
        margin = int(event.get("margin", 24))

        batch_resp = submit_batch_job(
            input_bucket=in_bucket,
            input_key=in_key,
            output_bucket=out_bucket,
            output_key=out_key,
            watermark_type=wm_type,
            watermark_text=wm_text,
            watermark_image_bucket=wm_img_bucket,
            watermark_image_key=wm_img_key,
            position=pos,
            opacity=opacity,
            font_size=font_size,
            font_color=font_color,
            enable_box=enable_box,
            box_color=box_color,
            margin=margin,
        )

        return {
            "statusCode": 200,
            "message": "AWS Batch watermark job submitted and recorded successfully",
            "jobId": batch_resp["jobId"],
            "jobName": batch_resp["jobName"],
            "status": "SUBMITTED",
            "dynamodbTable": DYNAMODB_TABLE_NAME,
            "source": f"s3://{in_bucket}/{in_key}",
            "destination": f"s3://{out_bucket}/{out_key}",
        }

    except Exception as e:
        logger.exception(f"Direct invocation failed: {str(e)}")
        return {
            "statusCode": 500,
            "error": str(e),
        }

