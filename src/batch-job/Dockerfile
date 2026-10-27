# ==============================================================================
# Production Dockerfile for AWS Batch Media Watermarking Job
# ==============================================================================
# Base Image: Python 3.12 on Debian Bookworm Slim
FROM python:3.12-slim-bookworm

# Metadata
LABEL maintainer="Cloud Engineering Team" \
      description="Production container for AWS Batch video and image watermarking using FFmpeg"

# Prevent interactive prompts during build and configure Python environment
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    FONTCONFIG_PATH=/etc/fonts \
    HOME=/app

# 1. Install runtime dependencies:
#    - ffmpeg: video/audio/image processing engine
#    - fontconfig & fonts-dejavu-core: provides TrueType fonts required for FFmpeg drawtext filter
#    - ca-certificates: required for secure HTTPS AWS S3/Batch API requests
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ffmpeg \
        fontconfig \
        fonts-dejavu-core \
        ca-certificates && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# 2. Security hardening: Create non-root system user and group (UID/GID 10001)
RUN groupadd -g 10001 appgroup && \
    useradd -u 10001 -g appgroup -d /app -m -s /bin/bash appuser && \
    mkdir -p /tmp/watermark_scratch && \
    chown -R appuser:appgroup /app /tmp/watermark_scratch

WORKDIR /app

# 3. Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 4. Copy application source files
COPY --chown=appuser:appgroup main.py lambda.py ./

# Ensure files are executable/readable
RUN chmod 755 main.py lambda.py

# 5. Switch to non-root user for principle of least privilege
USER 10001:10001

# 6. Container entrypoint using exec form so SIGTERM/SIGINT signals from ECS/AWS Batch propagate
ENTRYPOINT ["python3", "main.py"]
