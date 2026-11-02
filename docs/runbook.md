# Runbook

## Despliegue normal

```bash
./scripts/deploy_local.sh
```

El script:
1. Lee los outputs de Terraform.
2. Construye y publica las imágenes con el SHA.
3. Empaqueta el bundle.
4. Lo sube a S3 y obtiene el `VersionId`.
5. Crea el deployment.
6. Espera `READY`, valida el listener 8080 y ejecuta `continue-deployment`.

## Verificar el estado

```bash
aws deploy get-deployment --deployment-id <id> \
  --query 'deploymentInfo.{status:status,error:errorInformation}'
```

```bash
ALB_DNS="$(terraform -chdir=infra/main output -raw alb_dns_name)"
curl -i "http://$ALB_DNS/api/health"
curl -i "http://$ALB_DNS:8080/api/health"

TOKEN="$(curl -sS -X POST "http://$ALB_DNS/api/auth/login" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'username=admin&password=admin123' | jq -r .access_token)"
curl -i -X POST "http://$ALB_DNS/api/calculadora/sumar" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"a":2,"b":3}' 
```

## Ver alarmas

```bash
aws cloudwatch describe-alarms \
  --alarm-names gh-alb-5xx-blue gh-alb-5xx-green \
  --query 'MetricAlarms[].{Name:AlarmName,State:StateValue}'
```

## Probar rollback por alarma

```bash
ROLLBACK_TEST=1 VERSION=<tag> ./scripts/deploy_local.sh
```

El script:

1. Prepara el reemplazo y crea el deployment.
2. Espera `Ready`.
3. Genera 5xx contra el listener 8080.
4. Espera a que CodeDeploy se detenga.
5. Verifica `ALARM_ACTIVE` y que la alarma del reemplazo esté en `ALARM`.
6. No promueve el reemplazo; producción sigue sana.

Revisión manual:

```bash
aws deploy get-deployment --deployment-id <id> \
  --query 'deploymentInfo.{status:status,error:errorInformation}'
aws cloudwatch describe-alarms --alarm-names gh-alb-5xx-blue gh-alb-5xx-green \
  --query 'MetricAlarms[].{Name:AlarmName,State:StateValue}'
```

## Destroy

```bash
# 1. Eliminar ASGs creados por CodeDeploy.
TERRAFORM_ASG="$(terraform -chdir=infra/main output -raw autoscaling_group_name)"
aws autoscaling describe-auto-scaling-groups \
  --filters "Name=tag:Project,Values=mi-app" "Name=tag:Practice,Values=10" \
  --query 'AutoScalingGroups[].AutoScalingGroupName' --output text

# 2. Destruir la infraestructura principal.
terraform -chdir=infra/main destroy -auto-approve

# 3. Verificar que el bootstrap sigue existiendo.
aws s3 ls "s3://iac-terraform-tfstate-<cuenta>-us-east-1"
```

## Troubleshooting

| Síntoma | Causa probable | Solución |
|---|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Trust policy o repo mal configurados | Revisar `sub` del rol y el nombre del repo. |
| `Bucket does not exist` en `terraform init` | Bootstrap no aplicado | Ejecutar `infra/bootstrap`. |
| El agente no publica métricas | Falta `CloudWatchAgentServerPolicy` o el parámetro SSM | Revisar IAM y `systemctl status amazon-cloudwatch-agent`. |
| Log group vacío | Ruta del archivo distinta o contenedor sin `tee` | Verificar `/var/log/calculadora/calculadora.log` y `docker inspect`. |
| Deployment en `READY` y no avanza | Falta `continue-deployment` | Ejecutar `aws deploy continue-deployment --deployment-id <id> --deployment-wait-type READY_WAIT`. |
| `HEALTH_CONSTRAINTS` | Instancias no sanas o agente no instalado | Revisar Target Group y logs de user_data. |
| `ALARM_ACTIVE` | La alarma de 5xx se activó | Revisar logs y desplegar una versión sana. |
| Queda un ASG `CodeDeploy_*` | Resto de una prueba anterior con `COPY_AUTO_SCALING_GROUP` | Eliminarlo manualmente antes del destroy. |
| `terraform destroy` falla por un ASG no gestionado | Resto de una prueba anterior | Eliminar el ASG `CodeDeploy_*` primero. |

## Validación local

La práctica se validó localmente con despliegue normal y rollback por alarma antes de publicar el repositorio.
