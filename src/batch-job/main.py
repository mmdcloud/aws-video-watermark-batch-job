#!/usr/bin/env python3
"""
================================================================================
Production AWS Media Watermarking Pipeline: AWS Batch Job & Lambda Handler
================================================================================
This module serves dual purposes in a decoupled cloud architecture:
  1. AWS Lambda Handler (`lambda_handler`):
     Accepts events from S3 ObjectCreated triggers, SQS queues, or direct JSON
     invocations, validates parameters, and submits an AWS Batch job with
     dynamic container overrides and resource allocations.

  2. AWS Batch Container Entrypoint (`main`):
     Executes within an ECS/Fargate container, parses job parameters, downloads
     media from S3 with multipart streaming, applies watermarks (text, image,
     or both) using FFmpeg with production-grade codecs, and uploads the
     processed file to the destination S3 bucket.
================================================================================
"""

import argparse
import json
import logging
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import boto3
from boto3.s3.transfer import TransferConfig
from botocore.config import Config
from botocore.exceptions import ClientError

# ==============================================================================
# Configuration & Logging Setup
# ==============================================================================
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    level=LOG_LEVEL,
    format="%(asctime)s [%(levelname)s] [%(name)s:%(process)d] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("media-watermarker")

# System & Media Constants
FONT_PATH = os.getenv(
    "WATERMARK_FONT_PATH",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
)
VIDEO_EXTENSIONS = {".mp4", ".mov", ".mkv", ".avi", ".webm", ".m4v", ".flv"}
IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".tiff", ".bmp"}
SUPPORTED_EXTENSIONS = VIDEO_EXTENSIONS | IMAGE_EXTENSIONS

# S3 Transfer Thresholds: 16 MB chunk size, 10 concurrent transfer threads
MULTIPART_CHUNK_SIZE = 16 * 1024 * 1024
transfer_config = TransferConfig(
    multipart_threshold=MULTIPART_CHUNK_SIZE,
    max_concurrency=10,
    multipart_chunksize=MULTIPART_CHUNK_SIZE,
    use_threads=True,
)

# Standard AWS SDK Retry Configuration (Adaptive backoff)
boto_config = Config(
    retries={"max_attempts": 5, "mode": "adaptive"},
    connect_timeout=10,
    read_timeout=30,
)

# Active FFmpeg process reference for graceful signal management
_active_subprocess: Optional[subprocess.Popen] = None
_shutdown_initiated: bool = False


# ==============================================================================
# Signal Handling (Graceful termination for AWS Batch / ECS Spot / Fargate)
# ==============================================================================
def handle_termination_signal(signum: int, frame: Any) -> None:
    """
    Traps SIGTERM and SIGINT from ECS/Batch container stop timeouts.
    Gracefully terminates child FFmpeg processes and exits cleanly.
    """
    global _shutdown_initiated, _active_subprocess
    _shutdown_initiated = True
    sig_name = signal.Signals(signum).name
    logger.warning(
        f"Received signal {sig_name} ({signum}). Initiating graceful shutdown..."
    )

    if _active_subprocess and _active_subprocess.poll() is None:
        logger.info("Terminating active FFmpeg subprocess...")
        _active_subprocess.terminate()
        try:
            _active_subprocess.wait(timeout=5)
            logger.info("FFmpeg subprocess terminated.")
        except subprocess.TimeoutExpired:
            logger.warning("FFmpeg did not exit in 5s. Sending SIGKILL...")
            _active_subprocess.kill()

    # Standard exit code for killed processes (128 + signal number)
    sys.exit(128 + signum)


signal.signal(signal.SIGTERM, handle_termination_signal)
signal.signal(signal.SIGINT, handle_termination_signal)


# ==============================================================================
# S3 Transfer Utilities with Progress Monitoring
# ==============================================================================
class S3ProgressTracker:
    """Thread-safe progress logger for S3 multipart downloads and uploads."""

    def __init__(self, filename: str, total_bytes: int, log_interval: float = 10.0):
        self.filename = filename
        self.total_bytes = max(total_bytes, 1)
        self.log_interval = log_interval
        self.bytes_transferred = 0
        self.last_logged = time.time()
        self._lock = threading.Lock()

    def __call__(self, bytes_amount: int) -> None:
        with self._lock:
            self.bytes_transferred += bytes_amount
            now = time.time()
            if (now - self.last_logged >= self.log_interval) or (
                self.bytes_transferred >= self.total_bytes
            ):
                pct = (self.bytes_transferred / self.total_bytes) * 100.0
                curr_mb = self.bytes_transferred / (1024 * 1024)
                total_mb = self.total_bytes / (1024 * 1024)
                logger.info(
                    f"Transfer '{self.filename}': {pct:.1f}% ({curr_mb:.1f}/{total_mb:.1f} MB)"
                )
                self.last_logged = now


def get_s3_client(region: Optional[str] = None) -> Any:
    """Creates a configured Boto3 S3 client."""
    return boto3.client("s3", region_name=region, config=boto_config)


def download_s3_file(
    s3_client: Any, bucket: str, key: str, local_path: str
) -> None:
    """Downloads an S3 object with multipart transfer and progress tracking."""
    logger.info(f"Downloading s3://{bucket}/{key} to {local_path}...")
    try:
        head = s3_client.head_object(Bucket=bucket, Key=key)
        total_size = head.get("ContentLength", 0)
    except ClientError as e:
        logger.error(f"Failed to access source s3://{bucket}/{key}: {e}")
        raise

    progress = S3ProgressTracker(os.path.basename(key), total_size)
    s3_client.download_file(
        Bucket=bucket,
        Key=key,
        Filename=local_path,
        Config=transfer_config,
        Callback=progress,
    )
    logger.info(f"Successfully downloaded s3://{bucket}/{key} ({total_size} bytes)")


def upload_s3_file(
    s3_client: Any,
    local_path: str,
    bucket: str,
    key: str,
    content_type: str,
) -> None:
    """Uploads a local file to S3 with multipart transfer and server-side encryption."""
    file_size = os.path.getsize(local_path)
    logger.info(
        f"Uploading {local_path} ({file_size} bytes) to s3://{bucket}/{key} [Content-Type: {content_type}]..."
    )

    progress = S3ProgressTracker(os.path.basename(key), file_size)
    extra_args: Dict[str, Any] = {
        "ContentType": content_type,
        "ServerSideEncryption": "AES256",
    }

    s3_client.upload_file(
        Filename=local_path,
        Bucket=bucket,
        Key=key,
        ExtraArgs=extra_args,
        Config=transfer_config,
        Callback=progress,
    )
    logger.info(f"Successfully uploaded to s3://{bucket}/{key}")


# ==============================================================================
# FFmpeg Watermarking Engine
# ==============================================================================
def escape_drawtext_string(text: str) -> str:
    """
    Escapes special characters required by FFmpeg drawtext filter syntax:
    Backslashes, single quotes, colons, and percent signs.
    """
    escaped = text.replace("\\", "\\\\")
    escaped = escaped.replace("'", "'\\''")
    escaped = escaped.replace(":", "\\:")
    escaped = escaped.replace("%", "\\%")
    return escaped


def calculate_watermark_positions(
    position: str, margin: int = 24
) -> Tuple[str, str, str, str]:
    """
    Returns FFmpeg coordinate expressions (x, y) for overlay and drawtext filters.
    """
    pos = position.lower().strip()
    if pos == "top-left":
        overlay_x = f"{margin}"
        overlay_y = f"{margin}"
        text_x = f"{margin}"
        text_y = f"{margin}"
    elif pos == "top-right":
        overlay_x = f"main_w-overlay_w-{margin}"
        overlay_y = f"{margin}"
        text_x = f"w-tw-{margin}"
        text_y = f"{margin}"
    elif pos == "bottom-left":
        overlay_x = f"{margin}"
        overlay_y = f"main_h-overlay_h-{margin}"
        text_x = f"{margin}"
        text_y = f"h-th-{margin}"
    elif pos == "center":
        overlay_x = "(main_w-overlay_w)/2"
        overlay_y = "(main_h-overlay_h)/2"
        text_x = "(w-tw)/2"
        text_y = "(h-th)/2"
    else:  # Default to bottom-right
        overlay_x = f"main_w-overlay_w-{margin}"
        overlay_y = f"main_h-overlay_h-{margin}"
        text_x = f"w-tw-{margin}"
        text_y = f"h-th-{margin}"

    return overlay_x, overlay_y, text_x, text_y


def build_ffmpeg_command(
    input_path: str,
    output_path: str,
    is_video: bool,
    watermark_text: Optional[str] = None,
    watermark_img_path: Optional[str] = None,
    position: str = "bottom-right",
    opacity: float = 0.8,
    font_size: int = 28,
    font_color: str = "white",
    enable_box: bool = True,
    box_color: str = "black@0.4",
    margin: int = 24,
) -> List[str]:
    """
    Constructs a hardened, production-ready FFmpeg command line.
    Supports text, image overlay, or dual watermarks with universal playback codecs.
    """
    cmd = ["ffmpeg", "-y", "-hide_banner"]
    inputs = ["-i", input_path]
    filter_chains = []
    current_stream = "0:v"

    overlay_x, overlay_y, text_x, text_y = calculate_watermark_positions(
        position=position, margin=margin
    )

    # 1. Image Watermark Filter (if provided)
    if watermark_img_path and os.path.isfile(watermark_img_path):
        inputs.extend(["-i", watermark_img_path])
        # Scale watermark image up to max 18% width of main video, apply opacity
        img_filter = (
            f"[1:v]scale=w='min(iw,main_w*0.18)':h=-1,format=rgba,"
            f"colorchannelmixer=aa={opacity:.2f}[wm];"
            f"[{current_stream}][wm]overlay=x={overlay_x}:y={overlay_y}[overlaid]"
        )
        filter_chains.append(img_filter)
        current_stream = "overlaid"

        # Shift text if both are present in the same position
        if watermark_text and position == "bottom-right":
            text_x = f"{margin}"
            text_y = f"h-th-{margin}"

    # 2. Text Watermark Filter (if provided)
    if watermark_text:
        escaped_text = escape_drawtext_string(watermark_text)
        box_clause = (
            f":box=1:boxcolor={box_color}:boxborderw=6" if enable_box else ""
        )
        text_filter = (
            f"[{current_stream}]drawtext="
            f"fontfile='{FONT_PATH}':"
            f"text='{escaped_text}':"
            f"fontsize={font_size}:"
            f"fontcolor={font_color}@{opacity:.2f}"
            f"{box_clause}:"
            f"x={text_x}:y={text_y}[v_out]"
        )
        filter_chains.append(text_filter)
        current_stream = "v_out"

    # Assemble inputs and complex filters
    cmd.extend(inputs)
    if filter_chains:
        cmd.extend(["-filter_complex", ";".join(filter_chains)])
        cmd.extend(["-map", f"[{current_stream}]"])
    else:
        cmd.extend(["-map", "0:v"])

    # Codec & Output Parameters
    if is_video:
        # Conditionally map audio stream (map 0:a? ignores if audio does not exist)
        cmd.extend([
            "-map",
            "0:a?",
            "-c:v",
            "libx264",
            "-preset",
            "medium",
            "-crf",
            "23",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "aac",
            "-b:a",
            "192k",
            "-movflags",
            "+faststart",
        ])
    else:
        # High quality image compression
        ext = os.path.splitext(output_path)[1].lower()
        if ext in {".jpg", ".jpeg"}:
            cmd.extend(["-q:v", "2"])
        elif ext == ".png":
            cmd.extend(["-compression_level", "6"])

    cmd.append(output_path)
    return cmd


def execute_ffmpeg(cmd: List[str]) -> None:
    """Executes FFmpeg with real-time stderr streaming and error aggregation."""
    global _active_subprocess
    logger.info(f"Running FFmpeg: {' '.join(cmd)}")

    _active_subprocess = subprocess.Popen(
        cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )

    stderr_buffer: List[str] = []
    if _active_subprocess.stderr:
        for line in _active_subprocess.stderr:
            clean_line = line.strip()
            if clean_line:
                stderr_buffer.append(clean_line)
                # Filter useful progress updates
                if any(
                    k in clean_line
                    for k in ("time=", "fps=", "frame=", "Error", "Invalid")
                ):
                    logger.info(f"[FFmpeg] {clean_line}")

    return_code = _active_subprocess.wait()
    _active_subprocess = None

    if return_code != 0:
        tail = "\n".join(stderr_buffer[-30:])
        logger.error(f"FFmpeg failed with exit code {return_code}:\n{tail}")
        raise RuntimeError(
            f"FFmpeg process returned non-zero exit code {return_code}"
        )

    logger.info("FFmpeg execution completed successfully.")


# ==============================================================================
# AWS Batch Container Worker Execution Logic
# ==============================================================================
def run_batch_job(args: argparse.Namespace) -> None:
    """Main workflow executed inside the AWS Batch container."""
    logger.info("=== Starting AWS Batch Watermark Processing ===")
    logger.info(
        f"Input: s3://{args.input_bucket}/{args.input_key} -> Destination: s3://{args.output_bucket}/{args.output_key}"
    )

    ext = os.path.splitext(args.input_key)[1].lower()
    if ext not in SUPPORTED_EXTENSIONS:
        raise ValueError(
            f"Unsupported file extension '{ext}'. Supported: {SUPPORTED_EXTENSIONS}"
        )

    is_video = ext in VIDEO_EXTENSIONS
    s3_client = get_s3_client()

    with tempfile.TemporaryDirectory(prefix="batch_wm_") as temp_dir:
        input_file = os.path.join(temp_dir, f"input_media{ext}")
        output_file = os.path.join(temp_dir, f"watermarked_output{ext}")
        logo_file: Optional[str] = None

        # 1. Download source media from S3
        download_s3_file(s3_client, args.input_bucket, args.input_key, input_file)

        # 2. Download watermark image if requested
        if args.watermark_type in ("image", "both") and args.watermark_image_key:
            logo_ext = (
                os.path.splitext(args.watermark_image_key)[1].lower() or ".png"
            )
            logo_file = os.path.join(temp_dir, f"watermark_logo{logo_ext}")
            logo_bucket = args.watermark_image_bucket or args.input_bucket
            download_s3_file(
                s3_client, logo_bucket, args.watermark_image_key, logo_file
            )

        # 3. Assemble and execute FFmpeg watermarking
        text_payload = (
            args.watermark_text
            if args.watermark_type in ("text", "both")
            else None
        )
        cmd = build_ffmpeg_command(
            input_path=input_file,
            output_path=output_file,
            is_video=is_video,
            watermark_text=text_payload,
            watermark_img_path=logo_file,
            position=args.position,
            opacity=args.opacity,
            font_size=args.font_size,
            font_color=args.font_color,
            enable_box=args.enable_box,
            box_color=args.box_color,
            margin=args.margin,
        )
        execute_ffmpeg(cmd)

        # 4. Upload processed output to destination S3 bucket
        content_type = "video/mp4" if is_video else ("image/jpeg" if ext in {".jpg", ".jpeg"} else "image/png")
        upload_s3_file(
            s3_client=s3_client,
            local_path=output_file,
            bucket=args.output_bucket,
            key=args.output_key,
            content_type=content_type,
        )

    logger.info("=== AWS Batch Watermark Processing Completed Successfully ===")


# ==============================================================================
# AWS Lambda Handler (Submits AWS Batch Jobs)
# ==============================================================================
def sanitize_batch_job_name(prefix: str, key: str) -> str:
    """
    Sanitizes string to satisfy AWS Batch jobName requirements:
    Must match [a-zA-Z0-9_-]+, max length 128 characters.
    """
    base = os.path.basename(key)
    sanitized = re.sub(r"[^a-zA-Z0-9_-]", "_", base)
    name = f"{prefix}-{sanitized}-{int(time.time())}"
    return name[:128].strip("_-")


def extract_s3_events(record_data: Dict[str, Any]) -> List[Tuple[str, str]]:
    """Extracts (bucket, key) from S3 notifications or SQS-wrapped S3 notifications."""
    events: List[Tuple[str, str]] = []

    # Case 1: SQS record wrapping S3 event
    if "body" in record_data:
        try:
            body_json = json.loads(record_data["body"])
            if "Message" in body_json:  # SNS-wrapped S3 event
                body_json = json.loads(body_json["Message"])
            if "Records" in body_json:
                for rec in body_json["Records"]:
                    if "s3" in rec:
                        b = rec["s3"]["bucket"]["name"]
                        k = urllib.parse.unquote_plus(
                            rec["s3"]["object"]["key"]
                        )
                        events.append((b, k))
        except (json.JSONDecodeError, KeyError) as e:
            logger.warning(f"Could not parse SQS message body as S3 event: {e}")

    # Case 2: Direct S3 event record
    elif "s3" in record_data:
        b = record_data["s3"]["bucket"]["name"]
        k = urllib.parse.unquote_plus(record_data["s3"]["object"]["key"])
        events.append((b, k))

    return events


def submit_aws_batch_job(
    batch_client: Any,
    job_queue: str,
    job_definition: str,
    input_bucket: str,
    input_key: str,
    output_bucket: str,
    output_key: str,
    watermark_type: str = "text",
    watermark_text: str = "CONFIDENTIAL",
    watermark_image_bucket: str = "",
    watermark_image_key: str = "",
    position: str = "bottom-right",
    opacity: float = 0.8,
) -> Dict[str, Any]:
    """Submits a watermark processing job to AWS Batch with container overrides."""
    ext = os.path.splitext(input_key)[1].lower()
    is_video = ext in VIDEO_EXTENSIONS
    job_name = sanitize_batch_job_name("wm", input_key)

    # Dynamic compute resource allocation based on media type
    vcpu, memory = ("2.0", "4096") if is_video else ("0.5", "1024")

    command = [
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
    ]

    if watermark_image_key:
        command.extend([
            "--watermark-image-bucket",
            watermark_image_bucket or input_bucket,
            "--watermark-image-key",
            watermark_image_key,
        ])

    container_overrides: Dict[str, Any] = {
        "command": command,
        "resourceRequirements": [
            {"type": "VCPU", "value": vcpu},
            {"type": "MEMORY", "value": memory},
        ],
        "environment": [
            {"name": "LOG_LEVEL", "value": LOG_LEVEL},
            {"name": "INPUT_BUCKET", "value": input_bucket},
            {"name": "INPUT_KEY", "value": input_key},
            {"name": "OUTPUT_BUCKET", "value": output_bucket},
            {"name": "OUTPUT_KEY", "value": output_key},
        ],
    }

    logger.info(
        f"Submitting Batch job '{job_name}' to queue '{job_queue}' [VCPU: {vcpu}, Memory: {memory}MiB]"
    )

    response = batch_client.submit_job(
        jobName=job_name,
        jobQueue=job_queue,
        jobDefinition=job_definition,
        containerOverrides=container_overrides,
        retryStrategy={"attempts": 2},
        timeout={"attemptDurationSeconds": 7200 if is_video else 600},
        tags={
            "Application": "MediaWatermarking",
            "MediaType": "video" if is_video else "image",
            "SourceBucket": input_bucket,
        },
    )

    logger.info(
        f"Successfully submitted AWS Batch job. Job ID: {response['jobId']}"
    )
    return response


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    AWS Lambda entrypoint. Accepts:
      1. Direct JSON payload: {"input_bucket": "...", "input_key": "...", "output_bucket": "..."}
      2. S3 Event notifications
      3. SQS Event notifications (with ReportBatchItemFailures support)
    """
    logger.info(f"Lambda received invocation event: {json.dumps(event)[:500]}")

    job_queue = os.environ.get("JOB_QUEUE_ARN") or os.environ.get(
        "BATCH_JOB_QUEUE", "batch-job-queue"
    )
    job_definition = os.environ.get("JOB_DEFINITION_ARN") or os.environ.get(
        "BATCH_JOB_DEFINITION", "batch-job-definition"
    )
    destination_bucket = os.environ.get("DESTINATION_BUCKET", "")
    default_watermark = os.environ.get("DEFAULT_WATERMARK_TEXT", "CONFIDENTIAL")
    default_wm_img_bucket = os.environ.get("WATERMARK_IMAGE_BUCKET", "")
    default_wm_img_key = os.environ.get("WATERMARK_IMAGE_KEY", "")

    batch_client = boto3.client("batch", config=boto_config)
    batch_item_failures = []
    submitted_jobs = []

    # Scenario A: Event-driven Records (S3 or SQS)
    if "Records" in event and isinstance(event["Records"], list):
        for record in event["Records"]:
            message_id = record.get("messageId", "direct_record")
            try:
                s3_items = extract_s3_events(record)
                for in_bucket, in_key in s3_items:
                    ext = os.path.splitext(in_key)[1].lower()
                    if ext not in SUPPORTED_EXTENSIONS:
                        logger.info(
                            f"Skipping unsupported file extension for {in_key}"
                        )
                        continue

                    out_bucket = destination_bucket or in_bucket
                    out_key = f"watermarked/{in_key}"
                    resp = submit_aws_batch_job(
                        batch_client=batch_client,
                        job_queue=job_queue,
                        job_definition=job_definition,
                        input_bucket=in_bucket,
                        input_key=in_key,
                        output_bucket=out_bucket,
                        output_key=out_key,
                        watermark_type="both"
                        if default_wm_img_key
                        else "text",
                        watermark_text=default_watermark,
                        watermark_image_bucket=default_wm_img_bucket,
                        watermark_image_key=default_wm_img_key,
                    )
                    submitted_jobs.append({
                        "jobId": resp["jobId"],
                        "jobName": resp["jobName"],
                        "inputKey": in_key,
                    })

            except Exception as e:
                logger.exception(
                    f"Failed to process record {message_id}: {str(e)}"
                )
                batch_item_failures.append({"itemIdentifier": message_id})

        return {
            "statusCode": 200,
            "submittedJobs": submitted_jobs,
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
            or destination_bucket
            or in_bucket
        )
        out_key = event.get("output_key") or f"watermarked/{in_key}"
        wm_type = event.get("watermark_type", "text")
        wm_text = event.get("watermark_text", default_watermark)
        wm_img_bucket = event.get(
            "watermark_image_bucket", default_wm_img_bucket
        )
        wm_img_key = event.get("watermark_image_key", default_wm_img_key)
        pos = event.get("position", "bottom-right")
        opacity = float(event.get("opacity", 0.8))

        resp = submit_aws_batch_job(
            batch_client=batch_client,
            job_queue=job_queue,
            job_definition=job_definition,
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
        )

        return {
            "statusCode": 200,
            "message": "AWS Batch watermark job submitted successfully",
            "jobId": resp["jobId"],
            "jobName": resp["jobName"],
            "destination": f"s3://{out_bucket}/{out_key}",
        }

    except Exception as e:
        logger.exception(f"Error handling direct invocation: {str(e)}")
        return {
            "statusCode": 500,
            "error": str(e),
        }


# ==============================================================================
# CLI Entrypoint for AWS Batch Container Execution
# ==============================================================================
def parse_arguments() -> argparse.Namespace:
    """Parses CLI arguments with environment variable fallbacks."""
    parser = argparse.ArgumentParser(
        description="Production AWS Batch Media Watermarker"
    )

    parser.add_argument(
        "--input-bucket",
        default=os.getenv("INPUT_BUCKET"),
        help="Source S3 bucket name",
    )
    parser.add_argument(
        "--input-key",
        default=os.getenv("INPUT_KEY"),
        help="Source S3 object key",
    )
    parser.add_argument(
        "--output-bucket",
        default=os.getenv("OUTPUT_BUCKET"),
        help="Destination S3 bucket name",
    )
    parser.add_argument(
        "--output-key",
        default=os.getenv("OUTPUT_KEY"),
        help="Destination S3 object key",
    )
    parser.add_argument(
        "--watermark-type",
        choices=["text", "image", "both"],
        default=os.getenv("WATERMARK_TYPE", "text"),
        help="Type of watermark to apply",
    )
    parser.add_argument(
        "--watermark-text",
        default=os.getenv("WATERMARK_TEXT", "CONFIDENTIAL"),
        help="Text string for text watermark",
    )
    parser.add_argument(
        "--watermark-image-bucket",
        default=os.getenv("WATERMARK_IMAGE_BUCKET", ""),
        help="S3 bucket containing watermark logo image",
    )
    parser.add_argument(
        "--watermark-image-key",
        default=os.getenv("WATERMARK_IMAGE_KEY", ""),
        help="S3 key containing watermark logo image",
    )
    parser.add_argument(
        "--position",
        choices=[
            "bottom-right",
            "bottom-left",
            "top-right",
            "top-left",
            "center",
        ],
        default=os.getenv("WATERMARK_POSITION", "bottom-right"),
        help="Placement of watermark on media canvas",
    )
    parser.add_argument(
        "--opacity",
        type=float,
        default=float(os.getenv("WATERMARK_OPACITY", "0.8")),
        help="Watermark opacity from 0.0 to 1.0",
    )
    parser.add_argument(
        "--font-size",
        type=int,
        default=int(os.getenv("FONT_SIZE", "28")),
        help="Font size in pixels for text watermark",
    )
    parser.add_argument(
        "--font-color",
        default=os.getenv("FONT_COLOR", "white"),
        help="Color for text watermark",
    )
    parser.add_argument(
        "--enable-box",
        action="store_true",
        default=os.getenv("ENABLE_BOX", "true").lower() in ("true", "1", "yes"),
        help="Draw bounding contrast box behind text",
    )
    parser.add_argument(
        "--box-color",
        default=os.getenv("BOX_COLOR", "black@0.4"),
        help="Box color and transparency",
    )
    parser.add_argument(
        "--margin",
        type=int,
        default=int(os.getenv("WATERMARK_MARGIN", "24")),
        help="Margin in pixels from edge",
    )

    # Optional mode to trigger Lambda submission from CLI
    parser.add_argument(
        "--submit-batch-job",
        action="store_true",
        help="Run as job submitter rather than container worker",
    )

    args = parser.parse_args()

    # If running as batch worker, validate mandatory parameters
    if not args.submit_batch_job:
        missing = []
        if not args.input_bucket:
            missing.append("--input-bucket")
        if not args.input_key:
            missing.append("--input-key")
        if not args.output_bucket:
            missing.append("--output-bucket")
        if not args.output_key:
            # Default output key if missing
            if args.input_key:
                args.output_key = f"watermarked/{args.input_key}"
            else:
                missing.append("--output-key")

        if missing:
            parser.error(
                f"Missing required arguments for Batch worker: {', '.join(missing)}"
            )

    return args


def main() -> None:
    """CLI Entrypoint."""
    args = parse_arguments()

    if args.submit_batch_job:
        # CLI submission mode
        event = {
            "input_bucket": args.input_bucket,
            "input_key": args.input_key,
            "output_bucket": args.output_bucket,
            "output_key": args.output_key,
            "watermark_type": args.watermark_type,
            "watermark_text": args.watermark_text,
            "watermark_image_bucket": args.watermark_image_bucket,
            "watermark_image_key": args.watermark_image_key,
            "position": args.position,
            "opacity": args.opacity,
        }
        res = lambda_handler(event, None)
        print(json.dumps(res, indent=2))
        sys.exit(0 if res.get("statusCode") == 200 else 1)
    else:
        # Container execution mode
        try:
            run_batch_job(args)
            sys.exit(0)
        except Exception as e:
            logger.exception(f"Fatal error during watermark job: {e}")
            sys.exit(1)


if __name__ == "__main__":
    main()
