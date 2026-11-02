#!/bin/bash
# Crea el bucket de state con un backend local temporal y luego migra el
# state a S3. El backend.tf original se restaura siempre al terminar.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BOOTSTRAP_DIR="$ROOT_DIR/infra/bootstrap"
cd "$BOOTSTRAP_DIR"

restore_backend() {
  if [ -f backend.tf.disabled ]; then
    mv backend.tf.disabled backend.tf
  fi
}

if [ -f backend.tf ]; then
  mv backend.tf backend.tf.disabled
fi
trap restore_backend EXIT

terraform init -input=false
terraform apply -auto-approve -input=false

BUCKET="$(terraform output -raw state_bucket)"
echo "Bucket de state: $BUCKET"

restore_backend
trap - EXIT

# Forzar la migracion: se elimina la configuracion local del backend para que
# Terraform detecte el state local y lo copie al bucket.
rm -rf .terraform
printf 'yes\n' | terraform init -migrate-state -backend-config="bucket=$BUCKET"

if aws s3api head-object --bucket "$BUCKET" --key "bootstrap/terraform.tfstate" >/dev/null 2>&1; then
  rm -f terraform.tfstate terraform.tfstate.backup
  echo "State migrado a s3://$BUCKET/bootstrap/terraform.tfstate"
else
  echo "ERROR: no se encontro el state en S3" >&2
  exit 1
fi
