#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AWS_REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="iac-terraform-tfstate-${ACCOUNT_ID}-${AWS_REGION}"

echo "Bucket de state: $BUCKET"
terraform -chdir="$ROOT_DIR/infra/main" init -backend-config="bucket=$BUCKET"
