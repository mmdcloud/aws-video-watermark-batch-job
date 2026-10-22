#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Production script to build and push container image to Amazon ECR
# ==============================================================================
REGION="${1:-us-east-1}"
REPOSITORY_NAME="${2:-batch_job}"
IMAGE_TAG="${3:-latest}"

echo "==> Resolving AWS Account ID..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
IMAGE_URI="${ECR_REGISTRY}/${REPOSITORY_NAME}:${IMAGE_TAG}"

echo "==> Authenticating Docker client to ECR registry (${ECR_REGISTRY})..."
aws ecr get-login-password --region "${REGION}" | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "==> Building Docker image (${REPOSITORY_NAME}:${IMAGE_TAG})..."
docker build -t "${REPOSITORY_NAME}:${IMAGE_TAG}" -f Dockerfile .

echo "==> Tagging image for Amazon ECR: ${IMAGE_URI}..."
docker tag "${REPOSITORY_NAME}:${IMAGE_TAG}" "${IMAGE_URI}"

echo "==> Pushing image to Amazon ECR..."
docker push "${IMAGE_URI}"

echo "==> Successfully pushed image to Amazon ECR: ${IMAGE_URI}"
