#!/bin/bash
set -euo pipefail

# 1. Install and start Docker
dnf install -y docker
systemctl enable --now docker

# 2. Authenticate to ECR
aws ecr get-login-password --region "${region}" \
  | docker login --username AWS --password-stdin "${account_id}.dkr.ecr.${region}.amazonaws.com"

# 3. Pull the image tag baked into this launch template version
IMAGE="${account_id}.dkr.ecr.${region}.amazonaws.com/${ecr_repo_name}:${image_tag}"
docker pull "$IMAGE"

# 4. Fetch the DB secret from Secrets Manager
DB_SECRET_JSON=$(aws secretsmanager get-secret-value \
  --region "${region}" \
  --secret-id "${db_secret_arn}" \
  --query SecretString --output text)

# 5. Write the non-secret runtime config to disk. scripts/start.sh (shipped
# in the CodeDeploy revision, see appspec.yml) sources this on every
# redeploy so it can restart the container with a freshly-built image
# without needing these values baked into a static, checked-in script. The
# resolved secret itself is deliberately NOT written here — start.sh
# fetches it fresh from Secrets Manager each time, so rotation is honored.
mkdir -p /etc/hisaab
cat > /etc/hisaab/app.env <<EOF
DB_HOST=${db_host}
DB_PORT=${db_port}
DB_NAME=${db_name}
DB_SECRET_ARN=${db_secret_arn}
AWS_REGION=${region}
COGNITO_USER_POOL_ID=${cognito_user_pool_id}
COGNITO_APP_CLIENT_ID=${cognito_app_client_id}
SQS_QUEUE_URL=${sqs_queue_url}
REDIS_HOST=${redis_host}
REDIS_PORT=${redis_port}
EOF
chmod 600 /etc/hisaab/app.env

# 6. Start the container on port 8080 — a cold-start bootstrap so the
# instance is healthy immediately, independent of whether any CodeDeploy
# deployment has ever run against this ASG yet.
docker run -d \
  --name hisaab-api \
  --restart unless-stopped \
  -p 8080:8080 \
  -e DB_HOST="${db_host}" \
  -e DB_PORT="${db_port}" \
  -e DB_NAME="${db_name}" \
  -e DB_SECRET_JSON="$DB_SECRET_JSON" \
  -e AWS_REGION="${region}" \
  -e COGNITO_USER_POOL_ID="${cognito_user_pool_id}" \
  -e COGNITO_APP_CLIENT_ID="${cognito_app_client_id}" \
  -e SQS_QUEUE_URL="${sqs_queue_url}" \
  -e REDIS_HOST="${redis_host}" \
  -e REDIS_PORT="${redis_port}" \
  "$IMAGE"

# 7. Install and start the CodeDeploy agent — deliberately LAST. This agent
# registers with CodeDeploy as soon as it starts, and a brand-new instance
# joining a CodeDeploy-tracked ASG can have an "automatic launch deployment"
# fire immediately on registration (so scale-out instances get the latest
# deployed revision, not whatever's stale in this launch template). Starting
# the agent early raced that automatic deployment's ApplicationStart against
# this same script's own steps 2-6 above — confirmed the hard way, as a
# continuous launch-fail-terminate-relaunch loop: ApplicationStart's
# start.sh needs /etc/hisaab/app.env, written in step 5, which hadn't
# happened yet by the time the agent had already registered and CodeDeploy
# had already started running the deployment. Starting the agent only once
# everything above is done (config written, cold-boot container up) means
# app.env unconditionally exists before CodeDeploy can ever ask for it.
dnf install -y ruby wget
cd /tmp
wget "https://aws-codedeploy-${region}.s3.${region}.amazonaws.com/latest/install"
chmod +x ./install
./install auto
systemctl enable --now codedeploy-agent
