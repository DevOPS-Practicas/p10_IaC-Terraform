# Inventario de recursos

| Recurso | Nombre | Notas |
|---|---|---|
| Bucket de state | `iac-terraform-tfstate-<cuenta>-us-east-1` | Persistente; no se destruye. |
| VPC | `mi-app-vpc` | `10.0.0.0/16`. |
| Subredes públicas | `mi-app-public-1`, `mi-app-public-2` | Dos AZ. |
| Security Group ALB | `mi-app-alb-sg` | 80 público; 8080 según `allowed_test_cidr`. |
| Security Group instancias | `mi-app-instance-sg` | 3000 solo desde el ALB. |
| ALB | `mi-app-alb` | Internet-facing. |
| Target Group azul | `mi-app-tg-blue` | Puerto 3000, health `/api/health`. |
| Target Group verde | `mi-app-tg-green` | Puerto 3000, health `/api/health`. |
| Listener producción | puerto 80 | CodeDeploy lo conmuta. |
| Listener pruebas | puerto 8080 | El pipeline lo apunta al Target Group de reemplazo. |
| Launch Template | `mi-app-lt-*` | Ubuntu 24.04, Docker, CodeDeploy y CloudWatch Agent. |
| ASG azul | `mi-app-asg-blue` | 2/4 instancias, `health_check_type = EC2`. |
| ASG verde | `mi-app-asg-green` | 2/4 instancias, `health_check_type = EC2`. |
| ECR backend | `mi-app/backend` | Inmutable, scan on push. |
| ECR frontend | `mi-app/frontend` | Inmutable, scan on push. |
| Bucket artefactos | `mi-app-artifacts-<cuenta>-us-east-1` | Versionado y cifrado. |
| CodeDeploy app | `mi-app-app` | Compute platform Server. |
| Deployment Group | `produccion` | Blue/Green, `DISCOVER_EXISTING`, `STOP_DEPLOYMENT` y dos alarmas 5xx. |
| Rol EC2 | `mi-app-ec2-app-role` | ECR, S3, SSM, CloudWatch y CodeDeploy. |
| Rol CodeDeploy | `mi-app-codedeploy-role` | `AWSCodeDeployRole` + permisos Blue/Green. |
| Parámetro SSM | `/mi-app/cloudwatch-agent/config` | Configuración del agente. |
| Log group | `/mi-app/calculadora` | Retención 7 días. |
| Alarmas | `gh-alb-5xx-blue`, `gh-alb-5xx-green`, `gh-tg-healthy-*`, `gh-alb-p99`, `gh-asg-cpu-high`, `gh-asg-mem-high` | CloudWatch. |
| Dashboard | `gh-miAppEstado` | CPU, memoria, 5xx, hosts sanos, p99 y logs. |
| Rol OIDC | `IaC-Terraform-GitHubActions` | Creado fuera de Terraform. |
