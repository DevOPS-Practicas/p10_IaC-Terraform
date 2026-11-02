#!/bin/bash
set -euo pipefail

APP_DIR="/opt/mi-app"
mkdir -p /var/log/calculadora
chmod 777 /var/log/calculadora || true
cd "$APP_DIR"

TOKEN="$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300" || true)"
AWS_REGION="${AWS_REGION:-$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" \
  "http://169.254.169.254/latest/meta-data/placement/region" || true)}"
AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_REGION

APP_VERSION="$(cat VERSION)"
export APP_VERSION

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
export ECR_REGISTRY

aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$ECR_REGISTRY"

docker compose pull
docker compose down --remove-orphans || true
docker compose up -d
docker image prune -f
