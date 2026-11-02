#!/bin/bash
# Espera a que CodeDeploy deje el despliegue en READY, valida el entorno
# verde por el listener 8080 y continua el cambio de trafico.
set -euo pipefail

DEPLOYMENT_ID="${1:?Uso: wait_and_continue.sh <deployment-id> <alb-dns>}"
ALB_DNS="${2:?Uso: wait_and_continue.sh <deployment-id> <alb-dns>}"

STATUS=""
for _ in $(seq 1 60); do
  STATUS="$(aws deploy get-deployment --deployment-id "$DEPLOYMENT_ID" \
    --query 'deploymentInfo.status' --output text)"
  STATUS_UPPER="$(printf '%s' "$STATUS" | tr '[:lower:]' '[:upper:]')"
  echo "deployment status: $STATUS"

  case "$STATUS_UPPER" in
    READY) break ;;
    FAILED|STOPPED|SUCCEEDED)
      echo "El despliegue termino en $STATUS antes de estar READY" >&2
      exit 1
      ;;
  esac

  sleep 10
done

if [ "$STATUS_UPPER" != "READY" ]; then
  echo "Timeout esperando READY" >&2
  exit 1
fi

for _ in $(seq 1 30); do
  if curl -fsS "http://$ALB_DNS:8080/api/health" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

if ! curl -fsS "http://$ALB_DNS:8080/api/health" >/dev/null 2>&1; then
  echo "Health check del entorno verde fallo; se detiene el despliegue" >&2
  aws deploy stop-deployment --deployment-id "$DEPLOYMENT_ID" --auto-rollback-enabled || true
  exit 1
fi

aws deploy continue-deployment \
  --deployment-id "$DEPLOYMENT_ID" \
  --deployment-wait-type READY_WAIT

for _ in $(seq 1 90); do
  STATUS="$(aws deploy get-deployment --deployment-id "$DEPLOYMENT_ID" \
    --query 'deploymentInfo.status' --output text)"
  STATUS_UPPER="$(printf '%s' "$STATUS" | tr '[:lower:]' '[:upper:]')"
  echo "deployment status: $STATUS"

  case "$STATUS_UPPER" in
    SUCCEEDED)
      echo "Despliegue completado correctamente"
      "$(dirname "$0")/promote_bluegreen.sh"
      exit 0
      ;;
    FAILED|STOPPED)
      echo "Despliegue terminado en $STATUS" >&2
      exit 1
      ;;
  esac

  sleep 10
done

echo "Timeout esperando el resultado final del despliegue" >&2
exit 1
