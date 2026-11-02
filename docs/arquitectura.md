# Arquitectura

```text
                         Internet
                            |
                            v
                    +----------------+
                    |  ALB :80       |  producción
                    |  ALB :8080     |  pruebas Blue/Green
                    +-------+--------+
                            |
              +-------------+-------------+
              |                           |
       +------+------+             +------+------+
       | TG azul     |             | TG verde    |
       +------+------+             +------+------+
              |                           |
       +------+------+             +------+------+
       | ASG azul    |             | ASG verde   |
       | (Terraform) |             | (Terraform) |
       +-------------+             +-------------+
              |                           |
       +------+------+             +------+------+
       | EC2 + Docker|             | EC2 + Docker|
       | backend     |             | backend     |
       | frontend    |             | frontend    |
       +-------------+             +-------------+
```

## Flujo de despliegue

1. El pipeline ejecuta `terraform apply` sobre `infra/main`.
2. Construye backend y frontend, los publica en ECR con el SHA.
3. Empaqueta `appspec.yml`, `scripts/`, `docker-compose.yml` y `VERSION`.
4. Sube el bundle a S3 y obtiene el `VersionId`.
5. Crea un deployment en CodeDeploy.
6. CodeDeploy copia el ASG azul y crea el entorno verde.
7. Instala la revisión en las instancias verdes.
8. El listener 8080 enruta tráfico de prueba al entorno verde.
9. El pipeline valida `/api/health` y ejecuta `continue-deployment`.
10. CodeDeploy conmuta el listener 80 al Target Group verde.
11. CodeDeploy conserva el entorno anterior con `KEEP_ALIVE`; el workflow de destroy elimina los ASGs no gestionados.

## Rollback

- `auto_rollback_configuration`: `DEPLOYMENT_FAILURE` y `DEPLOYMENT_STOP_ON_ALARM`.
- Alarmas registradas: `gh-alb-5xx-blue` y `gh-alb-5xx-green`.
- Si cualquiera entra en ALARM durante el despliegue, CodeDeploy se detiene y revierte.

## Observabilidad

- CloudWatch Agent con métricas de CPU, memoria, disco y swap.
- Logs de backend y frontend en `/var/log/calculadora/calculadora.log`.
- Dashboard `gh-miAppEstado`.
- Alarmas de 5xx, hosts sanos, p99, CPU y memoria.

## Límites conocidos

- Ambos ASG los crea Terraform. CodeDeploy usa el ASG de reemplazo con `DISCOVER_EXISTING`; no quedan ASG no gestionados.
- El listener 80 lo cambia `promote_bluegreen.sh`; el listener 8080 lo cambia `prepare_bluegreen.sh`. Terraform ignora cambios en `default_action`.
- El Deployment Group se actualiza en cada despliegue con `prepare_bluegreen.sh`; Terraform lo revierte a su valor base en el siguiente apply y el pipeline lo vuelve a preparar.
- El listener 8080 queda expuesto según `allowed_test_cidr`; en producción debe restringirse o cerrarse.
