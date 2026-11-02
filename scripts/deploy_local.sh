#!/bin/bash
# Construye, publica y despliega la aplicacion usando los outputs de Terraform.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AWS_REGION="${AWS_REGION:-us-east-1}"
VERSION="${VERSION:-$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)}"

export AWS_REGION

BACKEND_REPO="$(terraform -chdir="$ROOT_DIR/infra/main" output -raw backend_ecr_repository_url)"
FRONTEND_REPO="$(terraform -chdir="$ROOT_DIR/infra/main" output -raw frontend_ecr_repository_url)"
BACKEND_REPO_NAME="$(terraform -chdir="$ROOT_DIR/infra/main" output -raw backend_ecr_repository_name)"
FRONTEND_REPO_NAME="$(terraform -chdir="$ROOT_DIR/infra/main" output -raw frontend_ecr_repository_name)"
BUCKET="$(terraform -chdir="$ROOT_DIR/infra/main" output -raw artifacts_bucket)"
APP_NAME="$(terraform -chdir="$ROOT_DIR/infra/main" output -raw codedeploy_app_name)"
GROUP_NAME="$(terraform -chdir="$ROOT_DIR/infra/main" output -raw codedeploy_deployment_group_name)"
ALB_DNS="$(terraform -chdir="$ROOT_DIR/infra/main" output -raw alb_dns_name)"
ECR_REGISTRY="${BACKEND_REPO%%/*}"

aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$ECR_REGISTRY"

if aws ecr describe-images --repository-name "$BACKEND_REPO_NAME" \
  --image-ids imageTag="$VERSION" >/dev/null 2>&1; then
  echo "La imagen backend $VERSION ya existe; se omite el push"
else
  docker build -t "$BACKEND_REPO:$VERSION" "$ROOT_DIR/backend"
  docker push "$BACKEND_REPO:$VERSION"
fi

if aws ecr describe-images --repository-name "$FRONTEND_REPO_NAME" \
  --image-ids imageTag="$VERSION" >/dev/null 2>&1; then
  echo "La imagen frontend $VERSION ya existe; se omite el push"
else
  docker build -t "$FRONTEND_REPO:$VERSION" "$ROOT_DIR/frontend"
  docker push "$FRONTEND_REPO:$VERSION"
fi

BUNDLE_DIR="$(mktemp -d)"
trap 'rm -rf "$BUNDLE_DIR"' EXIT

cp "$ROOT_DIR/appspec.yml" "$ROOT_DIR/docker-compose.yml" "$BUNDLE_DIR/"
cp -r "$ROOT_DIR/scripts" "$BUNDLE_DIR/scripts"
echo "$VERSION" > "$BUNDLE_DIR/VERSION"

(
  cd "$BUNDLE_DIR"
  zip -qr "$ROOT_DIR/bundle.zip" .
)

aws s3 cp "$ROOT_DIR/bundle.zip" "s3://$BUCKET/releases/$VERSION.zip"
VERSION_ID="$(aws s3api head-object --bucket "$BUCKET" --key "releases/$VERSION.zip" \
  --query 'VersionId' --output text)"

if [ -z "$VERSION_ID" ] || [ "$VERSION_ID" = "None" ]; then
  echo "No se obtuvo VersionId. Verifica que el bucket tenga versionado." >&2
  exit 1
fi

"$ROOT_DIR/scripts/prepare_bluegreen.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/.bluegreen.env"

DEPLOYMENT_ID="$(aws deploy create-deployment \
  --application-name "$APP_NAME" \
  --deployment-group-name "$GROUP_NAME" \
  --s3-location "bucket=$BUCKET,key=releases/$VERSION.zip,bundleType=zip,version=$VERSION_ID" \
  --target-instances "autoScalingGroups=$REPLACEMENT_ASG" \
  --description "Deploy $VERSION" \
  --query 'deploymentId' --output text)"

echo "Deployment: $DEPLOYMENT_ID"

if [ "${ROLLBACK_TEST:-0}" = "1" ]; then
  "$ROOT_DIR/scripts/test_rollback.sh" "$DEPLOYMENT_ID" "$ALB_DNS"
else
  "$ROOT_DIR/scripts/wait_and_continue.sh" "$DEPLOYMENT_ID" "$ALB_DNS"
fi
