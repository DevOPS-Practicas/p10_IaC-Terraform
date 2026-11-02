#!/bin/bash
# Prepara un despliegue Blue/Green con dos ASG gestionados por Terraform.
# 1. Detecta el Target Group que hoy recibe produccion.
# 2. Configura el listener de pruebas 8080 hacia el Target Group de reemplazo.
# 3. Actualiza el Deployment Group con el ASG original y el TG de reemplazo.
# 4. Escribe .bluegreen.env con el ASG que se pasara a --target-instances.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

ALB_ARN="$(terraform -chdir="$ROOT_DIR/infra/main" output -raw alb_arn)"
BLUE_ARN="$(terraform -chdir="$ROOT_DIR/infra/main" output -raw blue_target_group_arn)"
GREEN_ARN="$(terraform -chdir="$ROOT_DIR/infra/main" output -raw green_target_group_arn)"
BLUE_NAME="$(terraform -chdir="$ROOT_DIR/infra/main" output -raw blue_target_group_name)"
GREEN_NAME="$(terraform -chdir="$ROOT_DIR/infra/main" output -raw green_target_group_name)"
BLUE_ASG="$(terraform -chdir="$ROOT_DIR/infra/main" output -raw blue_autoscaling_group_name)"
GREEN_ASG="$(terraform -chdir="$ROOT_DIR/infra/main" output -raw green_autoscaling_group_name)"
APP_NAME="$(terraform -chdir="$ROOT_DIR/infra/main" output -raw codedeploy_app_name)"
GROUP_NAME="$(terraform -chdir="$ROOT_DIR/infra/main" output -raw codedeploy_deployment_group_name)"

PROD_LISTENER_ARN="$(aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[?Port==`80`].ListenerArn' --output text)"

TEST_LISTENER_ARN="$(aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[?Port==`8080`].ListenerArn' --output text)"

CURRENT_TG_ARN="$(aws elbv2 describe-listeners \
  --listener-arns "$PROD_LISTENER_ARN" \
  --query 'Listeners[0].DefaultActions[0].TargetGroupArn' --output text)"

if [ "$CURRENT_TG_ARN" = "$BLUE_ARN" ]; then
  ORIGINAL_ASG="$BLUE_ASG"
  REPLACEMENT_ASG="$GREEN_ASG"
  REPLACEMENT_ARN="$GREEN_ARN"
  REPLACEMENT_NAME="$GREEN_NAME"
  REPLACEMENT_COLOR="green"
else
  ORIGINAL_ASG="$GREEN_ASG"
  REPLACEMENT_ASG="$BLUE_ASG"
  REPLACEMENT_ARN="$BLUE_ARN"
  REPLACEMENT_NAME="$BLUE_NAME"
  REPLACEMENT_COLOR="blue"
fi

echo "Produccion actual: $CURRENT_TG_ARN"
echo "ASG original: $ORIGINAL_ASG"
echo "ASG de reemplazo: $REPLACEMENT_ASG ($REPLACEMENT_COLOR)"

aws elbv2 modify-listener \
  --listener-arn "$TEST_LISTENER_ARN" \
  --default-actions "Type=forward,TargetGroupArn=$REPLACEMENT_ARN"

aws deploy update-deployment-group \
  --application-name "$APP_NAME" \
  --current-deployment-group-name "$GROUP_NAME" \
  --load-balancer-info "targetGroupInfoList=[{name=$REPLACEMENT_NAME}]" \
  --auto-scaling-groups "$ORIGINAL_ASG"

cat > "$ROOT_DIR/.bluegreen.env" <<EOF
ORIGINAL_ASG=$ORIGINAL_ASG
REPLACEMENT_ASG=$REPLACEMENT_ASG
REPLACEMENT_TG=$REPLACEMENT_ARN
REPLACEMENT_COLOR=$REPLACEMENT_COLOR
EOF

echo "Preparado: listener 8080 -> $REPLACEMENT_NAME; target instances -> $REPLACEMENT_ASG"
