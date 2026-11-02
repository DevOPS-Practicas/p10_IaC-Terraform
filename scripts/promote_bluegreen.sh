#!/bin/bash
# Promueve el entorno de reemplazo a produccion cambiando el listener 80.
# Se ejecuta despues de que CodeDeploy completa el despliegue.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [ ! -f "$ROOT_DIR/.bluegreen.env" ]; then
  echo "ERROR: falta .bluegreen.env; ejecuta prepare_bluegreen.sh primero" >&2
  exit 1
fi

# shellcheck disable=SC1091
source "$ROOT_DIR/.bluegreen.env"

ALB_ARN="$(terraform -chdir="$ROOT_DIR/infra/main" output -raw alb_arn)"
ALB_DNS="$(terraform -chdir="$ROOT_DIR/infra/main" output -raw alb_dns_name)"

PROD_LISTENER_ARN="$(aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[?Port==`80`].ListenerArn' --output text)"

aws elbv2 modify-listener \
  --listener-arn "$PROD_LISTENER_ARN" \
  --default-actions "Type=forward,TargetGroupArn=$REPLACEMENT_TG"

for _ in $(seq 1 24); do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$ALB_DNS/api/health" || true)"
  if [ "$CODE" = "200" ]; then
    echo "Produccion promovida a $REPLACEMENT_COLOR ($REPLACEMENT_TG)"
    exit 0
  fi
  sleep 5
done

echo "ERROR: produccion no responde 200 despues de la promocion" >&2
exit 1
