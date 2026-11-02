#!/bin/bash
# Verifica la configuracion de alarmas y el estado de los recursos de observabilidad.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_REGION

APP_NAME="$(terraform -chdir="$ROOT_DIR/infra/main" output -raw codedeploy_app_name)"
GROUP_NAME="$(terraform -chdir="$ROOT_DIR/infra/main" output -raw codedeploy_deployment_group_name)"
ALB_DNS="$(terraform -chdir="$ROOT_DIR/infra/main" output -raw alb_dns_name)"
DASHBOARD="$(terraform -chdir="$ROOT_DIR/infra/main" output -raw dashboard_name)"
LOG_GROUP="$(terraform -chdir="$ROOT_DIR/infra/main" output -raw cloudwatch_log_group_name)"
PARAM_NAME="$(terraform -chdir="$ROOT_DIR/infra/main" output -raw ssm_parameter_name)"

echo "== 1. Alarmas registradas en CodeDeploy =="
aws deploy get-deployment-group \
  --application-name "$APP_NAME" \
  --deployment-group-name "$GROUP_NAME" \
  --query 'deploymentGroupInfo.alarmConfiguration' \
  --output json

echo "== 2. Estado de las alarmas =="
aws cloudwatch describe-alarms \
  --alarm-names gh-alb-5xx-blue gh-alb-5xx-green \
  --query 'MetricAlarms[].{Name:AlarmName,State:StateValue}' \
  --output table

echo "== 3. Dashboard =="
aws cloudwatch get-dashboard --dashboard-name "$DASHBOARD" \
  --query 'DashboardName' --output text

echo "== 4. Log group =="
aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" \
  --query 'logGroups[].logGroupName' --output text

echo "== 5. Parametro SSM =="
aws ssm get-parameter --name "$PARAM_NAME" \
  --query 'Parameter.Name' --output text

echo "== 6. Health de produccion =="
curl -fsS "http://$ALB_DNS/api/health"
echo
echo "== 7. Health del listener de pruebas =="
curl -fsS "http://$ALB_DNS:8080/api/health" || true
echo
echo "PASS: configuracion de observabilidad revisada"
