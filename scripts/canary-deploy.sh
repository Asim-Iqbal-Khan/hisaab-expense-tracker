#!/bin/bash
set -euo pipefail

# Ad hoc SSM Run Command script for the canary instance (asg-hisaab-canary,
# modules/compute) — NOT a CodeDeploy lifecycle hook like scripts/start.sh.
# The canary instance is deliberately outside CodeDeploy's deployment group,
# so it never receives an appspec bundle or an image_tag.txt; the canary
# orchestrator (modules/pipeline/codebuild.tf, canary-buildspec.yml) sets
# IMAGE_TAG directly as an environment variable before this script runs
# (SSM's RunShellScript document executes every "commands" line as one
# script, so an earlier IMAGE_TAG=... line stays in scope here — unlike
# CodeBuild's own buildspec, where each command list item is a separate
# shell).
#
# Kept in lockstep with scripts/start.sh's docker run invocation — same env
# vars, same image — so the canary genuinely tests what the real fleet is
# about to run, not a divergent code path.

: "${IMAGE_TAG:?IMAGE_TAG must be set}"

source /etc/hisaab/app.env

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$AWS_REGION")
ECR_REPO="hisaab-api"
IMAGE="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO:$IMAGE_TAG"

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

docker pull "$IMAGE"

DB_SECRET_JSON=$(aws secretsmanager get-secret-value \
  --region "$AWS_REGION" \
  --secret-id "$DB_SECRET_ARN" \
  --query SecretString --output text)

# Idempotent by design — this script can run again on the same instance for
# the next deploy, so any container left over from a prior run (passed or
# failed) must not block a fresh docker run.
docker rm -f hisaab-api 2>/dev/null || true

docker run -d \
  --name hisaab-api \
  --restart unless-stopped \
  -p 8080:8080 \
  -e DB_HOST="$DB_HOST" \
  -e DB_PORT="$DB_PORT" \
  -e DB_NAME="$DB_NAME" \
  -e DB_SECRET_JSON="$DB_SECRET_JSON" \
  -e AWS_REGION="$AWS_REGION" \
  -e COGNITO_USER_POOL_ID="$COGNITO_USER_POOL_ID" \
  -e COGNITO_APP_CLIENT_ID="$COGNITO_APP_CLIENT_ID" \
  -e SQS_QUEUE_URL="$SQS_QUEUE_URL" \
  -e REDIS_HOST="$REDIS_HOST" \
  -e REDIS_PORT="$REDIS_PORT" \
  "$IMAGE"
