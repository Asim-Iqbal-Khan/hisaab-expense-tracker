#!/bin/bash
set -euo pipefail

# Written once at instance boot by user_data.sh.tpl (modules/compute) — the
# non-secret runtime config shared between the boot-time bootstrap container
# and every subsequent CodeDeploy-driven redeploy.
source /etc/hisaab/app.env

# A bare relative path here depends on CodeDeploy's working directory
# when it runs this hook, which doesn't match this script's own location
# in the deployment archive (confirmed the hard way: "cat: image_tag.txt:
# No such file or directory" even though the file is right there next to
# scripts/). Resolving relative to the script itself sidesteps whatever
# CWD CodeDeploy actually uses.
IMAGE_TAG=$(cat "$(dirname "$0")/../image_tag.txt")
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$AWS_REGION")
ECR_REPO="hisaab-api"
IMAGE="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO:$IMAGE_TAG"

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

docker pull "$IMAGE"

# Fetched fresh on every deploy (not cached in app.env) so RDS-managed
# secret rotation is always honored.
DB_SECRET_JSON=$(aws secretsmanager get-secret-value \
  --region "$AWS_REGION" \
  --secret-id "$DB_SECRET_ARN" \
  --query SecretString --output text)

# ApplicationStop (scripts/stop.sh) doesn't run before a CodeDeploy
# instance's *first* install — from CodeDeploy's perspective there's
# nothing of its own to stop yet, even though user_data.sh.tpl's
# cold-start bootstrap already has a container running under this same
# name. Confirmed the hard way: "Conflict. The container name
# /hisaab-api is already in use". Removing defensively here makes this
# script idempotent regardless of whether ApplicationStop already ran.
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
