#!/usr/bin/env bash
# Crea (o actualiza) el rol OIDC que usan los workflows de GitHub Actions.
# Uso:
#   ./scripts/create_oidc_role.sh
# Requiere: aws CLI autenticado con permisos de IAM.
set -euo pipefail

ROLE_NAME="${ROLE_NAME:-IaC-Terraform-GitHubActions}"
GITHUB_REPO="${GITHUB_REPO:-LauraGabrielSantes/IaC-Terraform}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
OIDC_PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" >/dev/null 2>&1; then
  echo "ERROR: no existe el proveedor OIDC $OIDC_PROVIDER_ARN" >&2
  echo "Créalo primero con:" >&2
  echo "  aws iam create-open-id-connect-provider \\" >&2
  echo "    --url https://token.actions.githubusercontent.com \\" >&2
  echo "    --client-id-list sts.amazonaws.com" >&2
  exit 1
fi

TRUST_POLICY="$(mktemp)"
trap 'rm -f "$TRUST_POLICY"' EXIT

cat > "$TRUST_POLICY" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${OIDC_PROVIDER_ARN}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": [
            "repo:${GITHUB_REPO}:ref:refs/heads/main",
            "repo:${GITHUB_REPO}:pull_request"
          ]
        }
      }
    }
  ]
}
JSON

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "Actualizando trust policy del rol $ROLE_NAME..."
  aws iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document "file://${TRUST_POLICY}"
else
  echo "Creando rol $ROLE_NAME..."
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://${TRUST_POLICY}" \
    --description "GitHub Actions OIDC role for ${GITHUB_REPO}" >/dev/null
fi

# Permisos amplios de laboratorio. Para producción, sustituir por una política acotada.
POLICIES=(
  IAMFullAccess
  AmazonVPCFullAccess
  AmazonEC2FullAccess
  AmazonEC2ContainerRegistryFullAccess
  AmazonS3FullAccess
  CloudWatchFullAccess
  CloudWatchLogsFullAccess
  AWSCodeDeployFullAccess
  AutoScalingFullAccess
  ElasticLoadBalancingFullAccess
  AmazonSSMFullAccess
)

for policy in "${POLICIES[@]}"; do
  aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/${policy}"
done

ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)"
echo "Rol listo: ${ROLE_ARN}"
