#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Production script to build and push container image to Amazon ECR
# ==============================================================================
REGION="${1:-us-east-1}"
REPOSITORY_NAME="${2:-batch_job}"
IMAGE_TAG="${3:-latest}"
FORCE_PUSH="${FORCE_PUSH:-false}"

echo "==> [1/5] Resolving AWS Account ID..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
IMAGE_URI="${ECR_REGISTRY}/${REPOSITORY_NAME}:${IMAGE_TAG}"

# Check if image already exists in ECR to prevent redundant re-upload of 500MB
if [ "${FORCE_PUSH}" != "true" ]; then
    echo "==> Checking if image ${IMAGE_TAG} already exists in ${REPOSITORY_NAME}..."
    EXISTING_IMAGE=$(aws ecr describe-images \
        --repository-name "${REPOSITORY_NAME}" \
        --image-ids imageTag="${IMAGE_TAG}" \
        --region "${REGION}" 2>/dev/null || true)

    if [ -n "${EXISTING_IMAGE}" ]; then
        echo "==> Image ${IMAGE_URI} already exists in ECR repository."
        echo "==> Skipping build and push to save time. Set FORCE_PUSH=true to overwrite."
        exit 0
    fi
fi

echo "==> [2/5] Authenticating Docker client to ECR registry (${ECR_REGISTRY})..."
aws ecr get-login-password --region "${REGION}" | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "==> [3/5] Building Docker image (${REPOSITORY_NAME}:${IMAGE_TAG}) with BuildKit..."
DOCKER_BUILDKIT=1 docker build \
    --tag "${REPOSITORY_NAME}:${IMAGE_TAG}" \
    --file Dockerfile .

echo "==> [4/5] Tagging image for Amazon ECR: ${IMAGE_URI}..."
docker tag "${REPOSITORY_NAME}:${IMAGE_TAG}" "${IMAGE_URI}"

echo "==> [5/5] Pushing image to Amazon ECR (this may take a few minutes depending on upload speed)..."
docker push "${IMAGE_URI}"

echo "==> Successfully pushed image to Amazon ECR: ${IMAGE_URI}"
