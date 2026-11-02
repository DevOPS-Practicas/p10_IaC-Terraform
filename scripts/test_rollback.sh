#!/bin/bash
# Prueba el rollback por alarma:
# 1. Espera a que el deployment quede en Ready.
# 2. Genera 5xx contra el listener de pruebas 8080.
# 3. Verifica que CodeDeploy se detiene con ALARM_ACTIVE.
# 4. NO promueve el entorno de reemplazo.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOYMENT_ID="${1:?Uso: test_rollback.sh <deployment-id> <alb-dns>}"
ALB_DNS="${2:?Uso: test_rollback.sh <deployment-id> <alb-dns>}"

status_of() {
  aws deploy get-deployment --deployment-id "$DEPLOYMENT_ID" \
    --query 'deploymentInfo.status' --output text
}

echo "Esperando READY para el deployment $DEPLOYMENT_ID..."
READY=0
for _ in $(seq 1 60); do
  STATUS="$(status_of)"
  STATUS_UPPER="$(printf '%s' "$STATUS" | tr '[:lower:]' '[:upper:]')"
  echo "status: $STATUS"

  case "$STATUS_UPPER" in
    READY)
      READY=1
      break
      ;;
    FAILED|STOPPED|SUCCEEDED)
      echo "El deployment termino en $STATUS antes de READY" >&2
      exit 1
      ;;
  esac

  sleep 5
done

if [ "$READY" -ne 1 ]; then
  echo "Timeout esperando READY" >&2
  exit 1
fi

echo "Generando 5xx contra el listener de pruebas..."
"$ROOT_DIR/scripts/generate_5xx.sh" "$ALB_DNS" 300 &
GEN_PID=$!
cleanup() {
  kill "$GEN_PID" 2>/dev/null || true
}
trap cleanup EXIT

FINAL_STATUS=""
for _ in $(seq 1 60); do
  FINAL_STATUS="$(status_of)"
  FINAL_STATUS_UPPER="$(printf '%s' "$FINAL_STATUS" | tr '[:lower:]' '[:upper:]')"
  echo "status: $FINAL_STATUS"

  case "$FINAL_STATUS_UPPER" in
    FAILED|STOPPED)
      break
      ;;
    SUCCEEDED)
      echo "ERROR: el deployment termino correctamente; la alarma no disparo" >&2
      exit 1
      ;;
  esac

  sleep 5
done

cleanup
trap - EXIT

ERROR_CODE="$(aws deploy get-deployment --deployment-id "$DEPLOYMENT_ID" \
  --query 'deploymentInfo.errorInformation.code' --output text)"
echo "error code: $ERROR_CODE"

aws cloudwatch describe-alarms \
  --alarm-names gh-alb-5xx-blue gh-alb-5xx-green \
  --query 'MetricAlarms[].{Name:AlarmName,State:StateValue}' \
  --output table

if [ "$ERROR_CODE" != "ALARM_ACTIVE" ]; then
  echo "FAIL: el deployment no se detuvo por ALARM_ACTIVE (status=$FINAL_STATUS)" >&2
  exit 1
fi

echo "PASS: CodeDeploy se detuvo por ALARM_ACTIVE"
echo "Esperando a que las alarmas vuelvan a OK..."
for _ in $(seq 1 60); do
  ALARM_STATES="$(aws cloudwatch describe-alarms \
    --alarm-names gh-alb-5xx-blue gh-alb-5xx-green \
    --query 'MetricAlarms[].StateValue' --output text)"
  echo "alarm states: $ALARM_STATES"
  if ! printf '%s' "$ALARM_STATES" | grep -q 'ALARM'; then
    echo "PASS: alarmas de vuelta en OK"
    exit 0
  fi
  sleep 10
done

echo "FAIL: las alarmas no volvieron a OK" >&2
exit 1
