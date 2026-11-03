# Práctica 10 — Infraestructura como código con Terraform

> Guía completa paso a paso: [practica10_v2.md](practica10_v2.md)

Repositorio de la práctica 10. Implementa en Terraform la infraestructura de la calculadora de las prácticas 4 a 9, con:

- Bootstrap de state remoto en S3.
- VPC, subredes públicas, ALB, dos Target Groups y Auto Scaling Group.
- ECR inmutable para backend y frontend.
- CodeDeploy con despliegue Blue/Green y rollback por alarma.
- CloudWatch Agent, log group, alarmas y dashboard.
- Workflows de GitHub Actions con autenticación OIDC.
- Destrucción manual y controlada.

## Arquitectura

```text
GitHub Actions --OIDC--> IAM Role
       |
       +--> Terraform --> VPC / ALB / ASG / ECR / S3 / CodeDeploy / CloudWatch
       |
       +--> Docker build --> ECR
       |
       +--> bundle.zip --> S3 --> CodeDeploy --> ASG azul/verde --> ALB
```

- Listener 80: tráfico de producción.
- Listener 8080: tráfico de prueba de Blue/Green.
- `gh-tg-blue` y `gh-tg-green`: Target Groups.
- `produccion`: Deployment Group Blue/Green.

## Estructura

```text
.
├── .github/workflows/       CI, CD y destroy
├── backend/                 FastAPI + JWT de la calculadora
├── frontend/                React + Nginx
├── infra/bootstrap/         Bucket S3 del state
├── infra/main/              Infraestructura principal
├── scripts/                 Rol OIDC, despliegue, validación y pruebas
├── appspec.yml              Hooks de CodeDeploy
├── docker-compose.yml       Backend + frontend + logs
└── docs/                    Inventario, arquitectura y runbook
```

## Prerrequisitos

- AWS CLI v2 autenticado con permisos de IAM, EC2, VPC, ECR, S3, ELB, Auto Scaling, CodeDeploy, CloudWatch y SSM.
- Terraform 1.10 o superior.
- GitHub CLI autenticado.
- Docker y zip para el despliegue local.
- Proveedor OIDC de GitHub en IAM (`token.actions.githubusercontent.com`).

## Puesta en marcha

### 1. Crear el rol OIDC

```bash
GITHUB_REPO="<TU_USUARIO>/IaC-Terraform" ./scripts/create_oidc_role.sh
```

El script crea o actualiza `IaC-Terraform-GitHubActions` y muestra su ARN. No guarda secretos.

### 2. Configurar variables del repositorio

```bash
gh variable set AWS_ROLE_ARN --repo <TU_USUARIO>/IaC-Terraform \
  --body "arn:aws:iam::<TU_CUENTA>:role/IaC-Terraform-GitHubActions"
gh variable set AWS_REGION --repo <TU_USUARIO>/IaC-Terraform --body "us-east-1"
```

Deben ser **variables**, no secrets. El workflow las consume con `${{ vars.AWS_ROLE_ARN }}` y `${{ vars.AWS_REGION }}`.

### 3. Crear el bucket de state

```bash
chmod +x scripts/bootstrap_state.sh
./scripts/bootstrap_state.sh
```

### 4. Inicializar la infraestructura principal

```bash
BUCKET="iac-terraform-tfstate-$(aws sts get-caller-identity --query Account --output text)-us-east-1"
terraform -chdir=infra/main init -backend-config="bucket=$BUCKET"
terraform -chdir=infra/main validate
terraform -chdir=infra/main plan -out=tfplan
terraform -chdir=infra/main apply tfplan
```

### 5. Desplegar la aplicación

```bash
./scripts/deploy_local.sh
```

O hacer push a `main` para que lo haga el workflow `CD Terraform Deploy`.

### 6. Verificar

```bash
ALB_DNS="$(terraform -chdir=infra/main output -raw alb_dns_name)"
curl -fsS "http://$ALB_DNS/api/health"
curl -fsS "http://$ALB_DNS:8080/api/health"

TOKEN="$(curl -sS -X POST "http://$ALB_DNS/api/auth/login" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'username=admin&password=admin123' | jq -r .access_token)"
curl -fsS -X POST "http://$ALB_DNS/api/calculadora/sumar" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"a":2,"b":3}'

./scripts/test_observabilidad.sh
```

### 7. Probar Blue/Green y rollback

Despliegue normal:

```bash
./scripts/deploy_local.sh
```

El script prepara el reemplazo, despliega, espera `Ready`, valida el listener 8080, continúa el deployment y promueve el tráfico con `promote_bluegreen.sh`.

Rollback por alarma:

```bash
ROLLBACK_TEST=1 VERSION=<tag> ./scripts/deploy_local.sh
```

El script espera `Ready`, genera 5xx contra el listener 8080, verifica que CodeDeploy se detiene con `ALARM_ACTIVE` y no promueve el reemplazo. Producción sigue respondiendo.

### 8. Destruir

```bash
# Destruye solo infra/main; el bootstrap se conserva.
terraform -chdir=infra/main destroy -auto-approve
```

O ejecutar el workflow `Destroy Terraform` con la confirmación `DESTROY`.

## Workflows

| Workflow | Disparador | Qué hace |
|---|---|---|
| `CI Terraform` | Pull Request a main | `fmt`, `validate`, `plan`, resumen y artefacto. |
| `CD Terraform Deploy` | Push a main | `apply`, build/push a ECR, bundle a S3, deploy Blue/Green y health check. |
| `Destroy Terraform` | Manual | Elimina ASGs de CodeDeploy y destruye `infra/main`; no toca el bootstrap. |

## Seguridad

- Sin access keys: autenticación OIDC.
- `AWS_ROLE_ARN` y `AWS_REGION` como variables del repositorio.
- ECR con tags inmutables.
- Buckets privados, cifrados y con versionado.
- Security Group de instancias solo desde el ALB.
- SSH deshabilitado; usar SSM Session Manager.
- Listener 8080 restringido por `allowed_test_cidr`.
- El rol OIDC usa políticas administradas amplias para el laboratorio. En producción, sustituirlas por una política acotada.
