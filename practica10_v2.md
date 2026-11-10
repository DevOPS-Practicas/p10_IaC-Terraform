# Práctica 10 — Infraestructura como código con Terraform

## 1. Objetivo

Implementar con Terraform la infraestructura de la calculadora que se construyó en las prácticas 4 a 9, incorporando:

- Un bootstrap persistente para el state de Terraform en S3.
- Una VPC con dos subredes públicas, ALB, dos Target Groups y Auto Scaling Group.
- ECR con imágenes inmutables para backend y frontend.
- CodeDeploy con despliegue Blue/Green, validación del entorno verde y rollback por alarma.
- CloudWatch Agent, log group, alarmas y dashboard.
- Un pipeline de GitHub Actions con autenticación OIDC, sin access keys.
- Destrucción manual y controlada de la infraestructura principal.

Al terminar, el estudiante debe poder desplegar una versión, verificarla, provocar un rollback por alarma y destruir todo sin dejar recursos huérfanos.

---

## 2. Arquitectura

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
       | (Terraform) |             | (CodeDeploy)|
       +-------------+             +-------------+
              |                           |
       +------+------+             +------+------+
       | EC2 + Docker|             | EC2 + Docker|
       | backend     |             | backend     |
       | frontend    |             | frontend    |
       +-------------+             +-------------+
```

Flujo de un despliegue:

1. Terraform crea la infraestructura base y dos ASG: azul y verde.
2. El pipeline construye backend y frontend y los publica en ECR con el SHA del commit.
3. `prepare_bluegreen.sh` detecta el Target Group de producción, apunta el listener 8080 al Target Group de reemplazo y actualiza el Deployment Group.
4. El pipeline empaqueta `appspec.yml`, `scripts/`, `docker-compose.yml` y `VERSION`, lo sube a S3 y crea un deployment con `--target-instances` apuntando al ASG de reemplazo.
5. CodeDeploy instala la nueva versión en el ASG de reemplazo.
6. El pipeline valida `/api/health` por el listener 8080 y ejecuta `continue-deployment`.
7. CodeDeploy completa el deployment.
8. `promote_bluegreen.sh` cambia el listener 80 al Target Group de reemplazo.
9. El entorno anterior se conserva con `KEEP_ALIVE`; el siguiente despliegue alterna los ASG.
10. Si una alarma de 5xx se activa mientras el deployment está en `Ready`, CodeDeploy se detiene y producción no cambia.

---

## 3. Prerrequisitos

### 3.1. Herramientas

| Herramienta | Versión mínima | Verificación |
|---|---|---|
| AWS CLI | v2 | `aws --version` |
| Terraform | 1.10 | `terraform version` |
| Git | reciente | `git --version` |
| GitHub CLI | reciente | `gh --version` |
| Docker | reciente | `docker --version` |
| zip | reciente | `zip --version` |
| curl y jq | recientes | `curl --version`, `jq --version` |

### 3.2. Cuenta de AWS

- Permisos para crear IAM, VPC, EC2, ECR, S3, ELB, Auto Scaling, CodeDeploy, CloudWatch y SSM.
- Región `us-east-1`.
- Proveedor OIDC de GitHub creado:

```bash
aws iam list-open-id-connect-providers
```

Debe aparecer:

```text
arn:aws:iam::<CUENTA>:oidc-provider/token.actions.githubusercontent.com
```

Si no existe, créalo:

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com
```

### 3.3. Repositorio

```bash
git clone https://github.com/DevOPS-Practicas/IaC-Terraform.git
cd IaC-Terraform
```

### 3.4. Verificación inicial

```bash
aws sts get-caller-identity
gh auth status
terraform version
```

`aws sts get-caller-identity` debe devolver la cuenta y el usuario con el que se trabajará. No uses la cuenta root.

---

## 4. Estructura del repositorio

```text
IaC-Terraform/
├── .github/workflows/
│   ├── ci-terraform.yml
│   ├── cd-terraform-deploy.yml
│   └── destroy-terraform.yml
├── backend/
│   ├── Dockerfile
│   ├── main.py
│   ├── requirements.txt
│   ├── app/
│   │   ├── core/
│   │   ├── routers/
│   │   ├── schemas/
│   │   └── services/
│   └── tests/
├── frontend/
│   ├── Dockerfile
│   ├── nginx.conf.template
│   ├── package.json
│   ├── public/
│   └── src/
├── infra/
│   ├── bootstrap/
│   │   ├── backend.tf
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   └── variables.tf
│   └── main/
│       ├── alb.tf
│       ├── backend.tf
│       ├── codedeploy.tf
│       ├── main.tf
│       ├── observability.tf
│       ├── outputs.tf
│       ├── user_data.sh
│       └── variables.tf
├── scripts/
│   ├── after_install.sh
│   ├── before_install.sh
│   ├── bootstrap_state.sh
│   ├── create_oidc_role.sh
│   ├── deploy_local.sh
│   ├── generate_5xx.sh
│   ├── init_backend.sh
│   ├── prepare_bluegreen.sh
│   ├── promote_bluegreen.sh
│   ├── start_app.sh
│   ├── test_observabilidad.sh
│   ├── test_rollback.sh
│   ├── validate_service.sh
│   └── wait_and_continue.sh
├── appspec.yml
├── docker-compose.yml
├── README.md
└── docs/
    ├── arquitectura.md
    ├── inventario.md
    └── runbook.md
```

---

## 5. Fase 1 — Rol OIDC y variables del repositorio

### 5.1. Crear el rol

El repositorio incluye un script idempotente:

```bash
chmod +x scripts/create_oidc_role.sh
./scripts/create_oidc_role.sh
```

El script:

1. Comprueba que existe el proveedor OIDC.
2. Crea el rol `IaC-Terraform-GitHubActions`.
3. Configura una trust policy limitada al repositorio:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<CUENTA>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": [
            "repo:DevOPS-Practicas/IaC-Terraform:ref:refs/heads/main",
            "repo:DevOPS-Practicas/IaC-Terraform:pull_request",
            "repo:DevOPS-Practicas/IaC-Terraform:environment:production",
            "repo:DevOPS-Practicas@*/IaC-Terraform@*:ref:refs/heads/main",
            "repo:DevOPS-Practicas@*/IaC-Terraform@*:pull_request",
            "repo:DevOPS-Practicas@*/IaC-Terraform@*:environment:production"
          ]
        }
      }
    }
  ]
}
```

4. Adjunta las políticas administradas necesarias para el laboratorio.
5. Imprime el ARN del rol.

El ARN tiene la forma:

```text
arn:aws:iam::<CUENTA>:role/IaC-Terraform-GitHubActions
```

### 5.2. Configurar las variables del repositorio

```bash
ROLE_ARN="$(aws iam get-role \
  --role-name IaC-Terraform-GitHubActions \
  --query 'Role.Arn' --output text)"

gh variable set AWS_ROLE_ARN \
  --repo DevOPS-Practicas/IaC-Terraform \
  --body "$ROLE_ARN"

gh variable set AWS_REGION \
  --repo DevOPS-Practicas/IaC-Terraform \
  --body "us-east-1"
```

Verificación:

```bash
gh variable list --repo DevOPS-Practicas/IaC-Terraform
```

Deben aparecer `AWS_ROLE_ARN` y `AWS_REGION`. Son **variables**, no secrets: no hay access keys en el repositorio.

### 5.3. Comprobar el trust policy

```bash
aws iam get-role \
  --role-name IaC-Terraform-GitHubActions \
  --query 'Role.AssumeRolePolicyDocument' \
  --output json
```

Debe incluir el repositorio correcto y el `aud` de `sts.amazonaws.com`.

GitHub puede emitir el claim `sub` con IDs inmutables, por ejemplo:

```text
repo:DevOPS-Practicas@<ORG_ID>/IaC-Terraform@<REPO_ID>:pull_request
```

La trust policy de `scripts/create_oidc_role.sh` acepta tanto el formato corto como el de IDs. El workflow de destroy usa `environment: production`, por lo que también debe incluir el subject `...:environment:production`.

---

## 6. Fase 2 — Bootstrap del state

El bootstrap crea el bucket S3 donde Terraform guarda el state. Se aplica una sola vez y **no se destruye** con la práctica.

### 6.1. Ejecutar el bootstrap

El script crea el bucket con un backend local temporal y luego migra el state a S3:

```bash
chmod +x scripts/bootstrap_state.sh
./scripts/bootstrap_state.sh
```

El script:

1. Aparta temporalmente `infra/bootstrap/backend.tf`.
2. Ejecuta `terraform init` y `terraform apply` con state local.
3. Obtiene el nombre del bucket.
4. Restaura `backend.tf`.
5. Ejecuta `terraform init -migrate-state` para mover el state a S3.

El bucket se llama:

```text
iac-terraform-tfstate-<CUENTA>-us-east-1
```

### 6.2. Verificar el state remoto

```bash
BUCKET="iac-terraform-tfstate-$(aws sts get-caller-identity --query Account --output text)-us-east-1"
aws s3 ls "s3://$BUCKET"
```

Debe aparecer `bootstrap/terraform.tfstate`.

---

## 7. Fase 3 — Infraestructura principal

La infraestructura principal está en `infra/main`. Antes de aplicarla, revisa los archivos y entiende las decisiones.

### Archivos y responsabilidades

| Archivo | Responsabilidad |
|---|---|
| `main.tf` | VPC, subredes, IAM, ECR, S3, Launch Template y ASG. |
| `alb.tf` | ALB, Target Groups azul/verde y listeners 80/8080. |
| `codedeploy.tf` | Aplicación y Deployment Group Blue/Green. |
| `observability.tf` | SSM, log group, alarmas y dashboard. |
| `user_data.sh` | Docker, CodeDeploy Agent, CloudWatch Agent y directorio de logs. |
| `variables.tf` | Región, tamaños, CIDR de pruebas y AMI opcional. |
| `outputs.tf` | DNS, ARNs, nombres de ECR, S3 y CodeDeploy. |

### 7.2. Decisiones de diseño

| Decisión | Elección | Razón |
|---|---|---|
| State | S3 con `use_lockfile` | Locking nativo, sin DynamoDB. |
| Terraform | `>= 1.10` | Necesario para `use_lockfile`. |
| ECR | Tags inmutables | Evita sobrescribir imágenes y permite rollback por SHA. |
| ASG | `latest_version` + `instance_refresh` | Reemplazo controlado de instancias. |
| Health check del ASG | `EC2` | Evita churn antes del primer despliegue; el ALB valida con el Target Group. |
| Blue/Green | `DISCOVER_EXISTING` + dos ASG Terraform | CodeDeploy despliega en el ASG de reemplazo ya creado; no hay ASG no gestionados. |
| Tráfico de prueba | Listener 8080 actualizado por `prepare_bluegreen.sh` | Permite validar el entorno de reemplazo sin afectar producción. |
| Rollback | `DEPLOYMENT_FAILURE` + `DEPLOYMENT_STOP_ON_ALARM` | Cubre fallos del script y alarmas. |
| Promoción | `promote_bluegreen.sh` | Cambia el listener 80 al Target Group de reemplazo tras el deployment. |
| Alarmas | Dos de 5xx con `FILL(m1, 0)` | Protegen producción y el entorno de reemplazo; vuelven a OK cuando no hay 5xx. |
| Listener 8080 | `allowed_test_cidr` | Se puede restringir a la IP del estudiante. |

### 7.3. Inicializar el main

```bash
./scripts/init_backend.sh
```

El script calcula el bucket y ejecuta:

```bash
terraform -chdir=infra/main init -backend-config="bucket=iac-terraform-tfstate-<CUENTA>-us-east-1"
```

### 7.4. Validar y planificar

```bash
terraform -chdir=infra/main validate
terraform -chdir=infra/main plan -out=tfplan
```

Revisa el plan. Debe incluir, entre otros:

- 1 VPC, 2 subredes, 1 Internet Gateway y rutas.
- 2 Security Groups.
- 1 ALB, 2 Target Groups y 2 listeners.
- 1 Launch Template y 1 ASG con 2 instancias.
- 2 repositorios ECR.
- 1 bucket de artefactos.
- 1 aplicación y 1 Deployment Group de CodeDeploy.
- 1 parámetro SSM, 1 log group, 7 alarmas y 1 dashboard.

### 7.5. Aplicar

```bash
terraform -chdir=infra/main apply tfplan
```

Guarda los outputs:

```bash
terraform -chdir=infra/main output
```

Los más importantes:

```text
alb_dns_name
backend_ecr_repository_url
frontend_ecr_repository_url
artifacts_bucket
codedeploy_app_name
codedeploy_deployment_group_name
autoscaling_group_name
```

### 7.6. Verificar la infraestructura

```bash
aws elbv2 describe-load-balancers --names mi-app-alb \
  --query 'LoadBalancers[0].[LoadBalancerName,DNSName,State.Code]' --output table

aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names mi-app-asg-blue \
  --query 'AutoScalingGroups[0].[AutoScalingGroupName,MinSize,MaxSize,DesiredCapacity]' --output table

aws ecr describe-repositories \
  --query 'repositories[?starts_with(repositoryName, `mi-app/`)].repositoryName' --output table
```

Las instancias del ASG pueden aparecer inicialmente **unhealthy** en el Target Group porque todavía no tienen la aplicación. Es normal: el primer despliegue crea el entorno de reemplazo y conmuta el tráfico.

---

## 8. Fase 4 — Aplicación y scripts

### Backend

`backend/main.py` monta una API FastAPI v6 con `root_path="/api"` y tres grupos de rutas:

- `GET /health` y `GET /boom`: health check y endpoint de prueba que devuelve 500 para el rollback.
- `POST /auth/login`: autenticación con JWT. Credenciales de demo: `admin` / `admin123`.
- `POST /calculadora/sumar`, `/restar`, `/multiplicar`, `/dividir`: operaciones protegidas con `Authorization: Bearer <token>`.

La aplicación usa CORS, logging estructurado y separación en capas (`core`, `routers`, `schemas`, `services`). `backend/Dockerfile` usa `python:3.9-alpine`, instala las dependencias y ejecuta Uvicorn en el puerto 8000 con el usuario `appuser`.

### 8.2. Frontend

El frontend es una aplicación React + TypeScript (Create React App). `frontend/Dockerfile` es multi-stage: compila con `node:18-alpine` y sirve el build con `nginxinc/nginx-unprivileged:1.27-alpine`.

`frontend/nginx.conf.template` escucha en 8080, resuelve `BACKEND_HOST` y `BACKEND_PORT`, y proxya:

- `/api/` hacia el backend.
- `/health` hacia el backend.
- El resto hacia `index.html` para el enrutamiento de React.

El contenedor publica `3000:8080`, que es el puerto que usa el Target Group.

### 8.3. Docker Compose

`docker-compose.yml` usa las imágenes de ECR:

```yaml
image: ${ECR_REGISTRY}/mi-app/backend:${APP_VERSION:-latest}
image: ${ECR_REGISTRY}/mi-app/frontend:${APP_VERSION:-latest}
```

El frontend monta `/etc/nginx/conf.d` como `tmpfs` para que el entrypoint renderice la plantilla de nginx. Ambos servicios escriben en `/var/log/calculadora/calculadora.log` con `tee`. No se publica `latest`: la versión es el SHA del commit.

### 8.4. Hooks de CodeDeploy

`appspec.yml` define:

| Hook | Script | Qué hace |
|---|---|---|
| `BeforeInstall` | `scripts/before_install.sh` | Crea directorios y detiene contenedores previos. |
| `AfterInstall` | `scripts/after_install.sh` | Ajusta permisos del directorio de logs. |
| `ApplicationStart` | `scripts/start_app.sh` | Login a ECR, `docker compose pull` y `up -d`. |
| `ValidateService` | `scripts/validate_service.sh` | Espera hasta 300 s a que `/api/health` responda 200. |

El bloque `permissions` de `appspec.yml` debe declarar `type` como lista:

```yaml
permissions:
  - object: /opt/mi-app/scripts
    pattern: "*.sh"
    mode: 755
    type:
      - file
```

Si se usa `type: directory` como cadena, CodeDeploy falla con `undefined method 'each' for "directory":String`.

### 8.5. Scripts de operación

| Script | Uso |
|---|---|
| `scripts/bootstrap_state.sh` | Crea el bucket de state y migra el state a S3. |
| `scripts/init_backend.sh` | Inicializa el backend del main con el bucket correcto. |
| `scripts/prepare_bluegreen.sh` | Detecta producción, apunta el listener 8080 al reemplazo, actualiza el Deployment Group y comprueba que las alarmas estén en OK. |
| `scripts/deploy_local.sh` | Build, push, bundle, subida a S3, deployment y promoción. |
| `scripts/wait_and_continue.sh` | Espera `Ready`, valida 8080, continúa el deployment y promueve. |
| `scripts/promote_bluegreen.sh` | Cambia el listener 80 al Target Group de reemplazo. |
| `scripts/generate_5xx.sh` | Genera tráfico 5xx contra el listener de pruebas. |
| `scripts/test_rollback.sh` | Espera `Ready`, genera 5xx, verifica `ALARM_ACTIVE` y espera a que las alarmas vuelvan a OK. |
| `scripts/test_observabilidad.sh` | Verifica alarmas, dashboard, logs, SSM y health. |
| `scripts/create_oidc_role.sh` | Crea o actualiza el rol OIDC. |

---

## 9. Fase 5 — CI/CD

### Workflow `ci-terraform.yml`

Se dispara en Pull Request. Pasos:

1. Checkout.
2. Credenciales AWS con OIDC (`id-token: write`).
3. `terraform fmt -check`.
4. `terraform validate`.
5. `terraform plan`.
6. Resumen del plan y artefacto con retención de 1 día.

No aplica cambios.

### 9.2. `cd-terraform-deploy.yml`

Se dispara en push a `main`. Pasos:

1. Checkout.
2. Credenciales AWS con OIDC.
3. `terraform init`, `validate`, `plan` y `apply`.
4. Exporta outputs.
5. Login a ECR.
6. Build y push de backend y frontend con el SHA.
7. Ejecuta `prepare_bluegreen.sh` y exporta el ASG de reemplazo.
8. Empaqueta el bundle y lo sube a S3.
9. Crea el deployment con `--target-instances` apuntando al ASG de reemplazo.
10. Espera `Ready`, valida el listener 8080 y ejecuta `continue-deployment`.
11. Ejecuta `promote_bluegreen.sh` para cambiar el listener 80.
12. Health check de producción.

### 9.3. `destroy-terraform.yml`

Se dispara manualmente. Requiere escribir `DESTROY` y usar el environment `production`. Pasos:

1. Credenciales AWS con OIDC.
2. Elimina ASGs huérfanos con prefijo `CodeDeploy_` (si existen).
3. `terraform destroy` sobre `infra/main`.
4. No destruye el bootstrap.

### 9.4. Permisos de los workflows

```yaml
permissions:
  id-token: write
  contents: read
```

`id-token: write` es obligatorio para que GitHub emita el token OIDC. Sin él, `configure-aws-credentials` falla.

---

## 10. Fase 6 — Despliegue local

### 10.1. Ejecutar

```bash
./scripts/deploy_local.sh
```

El script obtiene los outputs de Terraform, construye las imágenes, las publica en ECR, prepara el reemplazo, empaqueta el bundle, lo sube a S3, crea el deployment con `--target-instances`, espera el resultado y promueve el entorno de reemplazo.

### 10.2. Qué esperar

1. Las imágenes aparecen en ECR con el tag del SHA.
2. El bundle aparece en `s3://mi-app-artifacts-<CUENTA>-us-east-1/releases/<SHA>.zip`.
3. `prepare_bluegreen.sh` elige el ASG de reemplazo y apunta el listener 8080 a su Target Group.
4. CodeDeploy despliega en ese ASG.
5. El deployment pasa a `Ready`.
6. El listener 8080 responde 200 en `/api/health`.
7. El script ejecuta `continue-deployment`.
8. El deployment pasa a `Succeeded`.
9. `promote_bluegreen.sh` cambia el listener 80 al Target Group de reemplazo.
10. El listener 80 responde 200 en `/api/health`.

### 10.3. Verificar

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

Resultados esperados:

```text
HTTP/1.1 200 OK
{"status":"ok","version":"2.0.0"}
{"operacion":"suma","a":2.0,"b":3.0,"resultado":5.0}
```

---

## 11. Fase 7 — Despliegue con GitHub Actions

### 11.1. Pull Request

```bash
git checkout -b prueba-ci
# Hacer un cambio menor, por ejemplo en docs/runbook.md
git add .
git commit -m "docs: prueba de CI"
git push -u origin prueba-ci

gh pr create \
  --repo DevOPS-Practicas/IaC-Terraform \
  --base main \
  --head prueba-ci \
  --title "Prueba de CI Terraform" \
  --body "Valida fmt, validate y plan."
```

Observar el workflow:

```bash
gh run list --repo DevOPS-Practicas/IaC-Terraform --limit 5
gh run watch --repo DevOPS-Practicas/IaC-Terraform
```

El workflow `CI Terraform` debe terminar en verde y publicar el resumen del plan.

### 11.2. Merge a main

```bash
gh pr merge --repo DevOPS-Practicas/IaC-Terraform --merge --delete-branch
```

El merge dispara `CD Terraform Deploy`. El workflow aplica Terraform, publica imágenes, crea el bundle y despliega.

Verificación:

```bash
gh run list --repo DevOPS-Practicas/IaC-Terraform --limit 5
```

El workflow `CD Terraform Deploy` debe terminar en verde.

---

## 12. Fase 8 — Blue/Green y rollback por alarma

### 12.1. Comprobar el Deployment Group

```bash
aws deploy get-deployment-group \
  --application-name mi-app-app \
  --deployment-group-name produccion \
  --query 'deploymentGroupInfo.{
    type:deploymentStyle.deploymentType,
    option:deploymentStyle.deploymentOption,
    alarms:alarmConfiguration.alarms,
    rollback:autoRollbackConfiguration.events
  }'
```

Debe mostrar:

```text
type: BLUE_GREEN
option: WITH_TRAFFIC_CONTROL
alarms: [gh-alb-5xx-blue, gh-alb-5xx-green]
rollback: [DEPLOYMENT_FAILURE, DEPLOYMENT_STOP_ON_ALARM]
```

### 12.2. Verificar el listener de pruebas

```bash
ALB_DNS="$(terraform -chdir=infra/main output -raw alb_dns_name)"
curl -i "http://$ALB_DNS:8080/api/health"
```

Debe responder 200. El listener 8080 es el listener de pruebas; `scripts/prepare_bluegreen.sh` lo apunta al Target Group de reemplazo antes de cada despliegue.

### 12.3. Provocar el rollback

En una terminal, genera 5xx contra el entorno de reemplazo:

```bash
./scripts/generate_5xx.sh "$ALB_DNS" 300
```

En otra terminal, dispara un despliegue:

```bash
git commit --allow-empty -m "test: rollback por alarma"
git push origin main
```

El workflow crea el deployment. Mientras el entorno de reemplazo recibe `/api/boom`, la alarma del Target Group de reemplazo (`gh-alb-5xx-green` o `gh-alb-5xx-blue`) pasa a `ALARM`. CodeDeploy detiene el despliegue y revierte.

Verificación:

```bash
aws cloudwatch describe-alarms \
  --alarm-names gh-alb-5xx-green \
  --query 'MetricAlarms[0].{name:AlarmName,state:StateValue}'

aws deploy list-deployments \
  --application-name mi-app-app \
  --deployment-group-name produccion \
  --include-only-statuses FAILED STOPPED \
  --max-items 5
```

El deployment debe aparecer como `STOPPED` o `FAILED` con error `ALARM_ACTIVE`.

Producción debe seguir respondiendo:

```bash
curl -i "http://$ALB_DNS/api/health"
```

### 12.4. Recuperar una versión sana

Detén `generate_5xx.sh` con `Ctrl+C` y vuelve a desplegar:

```bash
git commit --allow-empty -m "test: despliegue sano"
git push origin main
```

El nuevo deployment debe terminar en `SUCCEEDED` y el listener 80 debe quedar en el entorno de reemplazo.

### 12.5. Prueba automatizada de rollback

El repositorio incluye `scripts/test_rollback.sh`, que automatiza la prueba:

```bash
ROLLBACK_TEST=1 VERSION=<tag> ./scripts/deploy_local.sh
```

El script:

1. Prepara el Blue/Green y comprueba que las alarmas estén en OK.
2. Crea el deployment y espera `Ready`.
3. Genera 5xx contra el listener 8080.
4. Espera a que CodeDeploy se detenga.
5. Verifica que el error sea `ALARM_ACTIVE`.
6. Espera a que ambas alarmas vuelvan a `OK`.
7. No promueve el entorno de reemplazo.

Salida esperada:

```text
status: Ready
Generando 5xx contra el listener de pruebas...
status: Stopped
error code: ALARM_ACTIVE
PASS: CodeDeploy se detuvo por ALARM_ACTIVE
alarm states: OK OK
PASS: alarmas de vuelta en OK
```

Producción debe seguir respondiendo 200 durante toda la prueba.

`prepare_bluegreen.sh` también espera a que las alarmas estén en `OK` antes de crear un nuevo deployment. Así se evita que un rollback reciente bloquee el siguiente despliegue.

### 12.6. Comprobar la alarma azul

```bash
aws cloudwatch describe-alarms \
  --alarm-names gh-alb-5xx-blue gh-alb-5xx-green \
  --query 'MetricAlarms[].{name:AlarmName,state:StateValue}' --output table
```

Ambas alarmas deben volver a `OK` cuando el tráfico 5xx cesa.

---

## 13. Fase 9 — Observabilidad

### 13.1. Ejecutar el script

```bash
./scripts/test_observabilidad.sh
```

El script verifica:

1. Alarmas registradas en CodeDeploy.
2. Estado de `gh-alb-5xx-blue` y `gh-alb-5xx-green`.
3. Dashboard `gh-miAppEstado`.
4. Log group `/mi-app/calculadora`.
5. Parámetro SSM `/mi-app/cloudwatch-agent/config`.
6. Health de producción y del listener de pruebas.

Las alarmas de 5xx usan la expresión `FILL(m1, 0)`: si no hay tráfico 5xx, el valor evaluado es `0` y la alarma vuelve a `OK`. Esto evita que una alarma quede bloqueada en `ALARM` después de un rollback y que el siguiente despliegue se detenga al inicio.

### 13.2. Verificar métricas y logs

```bash
aws logs describe-log-streams \
  --log-group-name /mi-app/calculadora \
  --order-by LastEventTime --descending --max-items 5

aws cloudwatch get-dashboard \
  --dashboard-name gh-miAppEstado \
  --query 'DashboardName' --output text
```

En la consola de CloudWatch:

- `CWAgent` debe mostrar `mem_used_percent` y métricas de CPU.
- El dashboard debe mostrar CPU, memoria, 5xx, hosts sanos, p99 y logs.
- El log group debe tener un stream por instancia.

### 13.3. Verificar el agente en una instancia

```bash
INSTANCE_ID="$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names mi-app-asg-blue \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)"

aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["systemctl status amazon-cloudwatch-agent --no-pager","systemctl status codedeploy-agent --no-pager"]' \
  --query 'Command.CommandId' --output text
```

---

## 14. Fase 10 — Destrucción

### 14.1. Destruir la infraestructura principal

```bash
# 1. Eliminar ASGs creados por CodeDeploy que no están en el state.
TERRAFORM_ASG="$(terraform -chdir=infra/main output -raw autoscaling_group_name)"
aws autoscaling describe-auto-scaling-groups \
  --filters "Name=tag:Project,Values=mi-app" "Name=tag:Practice,Values=10" \
  --query 'AutoScalingGroups[].AutoScalingGroupName' --output text

# 2. Destruir.
terraform -chdir=infra/main destroy -auto-approve
```

El workflow `Destroy Terraform` hace lo mismo, pero requiere confirmación y el environment `production`. Por eso el rol OIDC debe confiar en el subject `...:environment:production`.

### 14.2. Verificar que el bootstrap sigue existiendo

```bash
aws s3 ls "s3://iac-terraform-tfstate-<CUENTA>-us-east-1"
```

Debe seguir existiendo `bootstrap/terraform.tfstate`.

### 14.3. Verificar que no quedan recursos

```bash
aws elbv2 describe-load-balancers --names mi-app-alb
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names mi-app-asg
aws ecr describe-repositories \
  --query 'repositories[?starts_with(repositoryName, `mi-app/`)].repositoryName'
```

Los comandos deben devolver listas vacías o errores de “no encontrado”.

---

## 15. Pruebas y criterios de aceptación

| Prueba | Cómo | Resultado esperado | Evidencia |
|---|---|---|---|
| Bootstrap | `terraform apply` en `infra/bootstrap` | Bucket creado y state migrado. | `aws s3 ls` |
| Init del main | `./scripts/init_backend.sh` | Backend S3 configurado. | `.terraform/terraform.tfstate` |
| Validate | `terraform validate` | Sin errores. | Salida del comando |
| Plan | `terraform plan` | Recursos esperados, sin reemplazos inesperados. | `tfplan` |
| Apply | `terraform apply tfplan` | Infraestructura creada. | Salida del apply |
| CI | Pull Request | `fmt`, `validate` y `plan` en verde. | Workflow |
| CD | Push a main | Apply, build, bundle y deployment exitoso. | Workflow |
| Health | `curl /api/health` | HTTP 200. | Salida de curl |
| Autenticación | `POST /api/auth/login` con `admin/admin123` | Token JWT válido. | Salida de curl |
| Cálculo | Login + `POST /api/calculadora/sumar` | `resultado: 5.0`. | Salida de curl |
| Blue/Green | Despliegue normal | El entorno de reemplazo recibe tráfico y el anterior se conserva. | CodeDeploy |
| Rollback | `generate_5xx.sh` + deploy | Alarma del TG de reemplazo en ALARM y deployment detenido. | CloudWatch y CodeDeploy |
| Recuperación | Tras el rollback, esperar alarmas OK y desplegar de nuevo | Deployment `Succeeded` y producción sana. | CodeDeploy |
| Alarmas | `test_observabilidad.sh` | Ambas alarmas registradas. | Salida del script |
| Logs | Log group | Streams por instancia y eventos. | CloudWatch Logs |
| Dashboard | Consola | Widgets con datos. | Captura |
| Destroy | `terraform destroy` | Infra principal eliminada; bootstrap intacto. | Salida del destroy |
| Reconstrucción | Apply + deploy | Todo vuelve a funcionar. | Workflow y health |

### Definición de terminado

- [ ] El rol OIDC existe y las variables del repositorio están configuradas.
- [ ] El bucket de state existe y el bootstrap usa state remoto.
- [ ] El main usa state remoto y locking nativo.
- [ ] `terraform validate` y `terraform plan` pasan sin errores.
- [ ] El apply crea VPC, ALB, ASG, ECR, S3, CodeDeploy y observabilidad.
- [ ] El pipeline de CI ejecuta `fmt`, `validate` y `plan`.
- [ ] El pipeline de CD despliega la aplicación.
- [ ] `/api/health` responde 200 en producción y en el listener de pruebas.
- [ ] El login devuelve un token y la suma autenticada devuelve `5.0`.
- [ ] El despliegue Blue/Green cambia el tráfico y conserva el entorno anterior para inspección.
- [ ] Las dos alarmas de 5xx están registradas en CodeDeploy.
- [ ] El rollback por alarma detiene el despliegue y producción sigue sana.
- [ ] El dashboard y el log group muestran datos.
- [ ] El destroy elimina la infraestructura principal y conserva el bootstrap.
- [ ] El ciclo apply + deploy + destroy se puede repetir.

---

## 16. Troubleshooting

| Síntoma | Causa probable | Solución |
|---|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | La trust policy no coincide con el `sub` real | Revisar el `sub` (puede incluir IDs inmutables) y añadir el subject `environment:production` si el job usa environment. |
| `Bucket does not exist` en `terraform init` | Bootstrap no aplicado | Ejecutar `infra/bootstrap` y migrar el state. |
| `Error: creating EC2 ... UnauthorizedOperation` | El rol OIDC no tiene permisos | Revisar las políticas adjuntas al rol. |
| El agente no publica métricas | Falta `CloudWatchAgentServerPolicy` o el parámetro SSM | Revisar IAM y `systemctl status amazon-cloudwatch-agent`. |
| Log group vacío | Ruta distinta o contenedor sin `tee` | Verificar `/var/log/calculadora/calculadora.log` y `docker inspect`. |
| Deployment en `Ready` y no avanza | Falta `continue-deployment` o el script no normaliza el estado | Ejecutar `aws deploy continue-deployment --deployment-id <id> --deployment-wait-type READY_WAIT`; el script compara en mayúsculas. |
| `undefined method 'each' for "directory":String` | `permissions.type` es una cadena en `appspec.yml` | Declarar `type` como lista: `- file`. |
| 502 justo después de promover | Propagación del ALB | Esperar 20–30 s y repetir el health check. |
| `HEALTH_CONSTRAINTS` | Instancias no sanas o agente no instalado | Revisar Target Group y logs de user_data. |
| `ALARM_ACTIVE` | La alarma de 5xx se activó | Revisar logs, detener el tráfico 5xx y desplegar una versión sana. |
| El deployment se detiene antes de `Ready` después de un rollback | La alarma sigue en `ALARM` | Esperar a que vuelva a `OK`; `prepare_bluegreen.sh` y `test_rollback.sh` ya esperan. |
| El ASG de reemplazo queda huérfano | CodeDeploy no lo elimina tras un fallo | Eliminarlo manualmente antes del destroy. |
| `terraform destroy` falla por el ASG de reemplazo | El ASG no está en el state | Eliminar el ASG de reemplazo primero. |
| `ResourceInUse` al destruir el ALB | Quedan Target Groups o reglas | Destruir en orden: ASG, ALB, TG. |
| El listener 8080 no responde | Security Group o `allowed_test_cidr` | Revisar el CIDR y el listener. |

---

## 17. Seguridad

- Autenticación OIDC, sin access keys en GitHub.
- `AWS_ROLE_ARN` y `AWS_REGION` como variables del repositorio.
- ECR con tags inmutables y escaneo al hacer push.
- Buckets privados, cifrados, con versionado y bloqueo de acceso público.
- Security Group de instancias solo desde el ALB.
- SSH deshabilitado; usar SSM Session Manager.
- Listener 8080 restringido por `allowed_test_cidr`.
- El rol OIDC usa políticas administradas amplias para el laboratorio. En producción, sustituirlas por una política acotada.
- No guardar secretos en el repositorio.
- Revisar el plan antes de aplicar.

---

## 18. Conclusión

La práctica integra Terraform, GitHub Actions, CodeDeploy y CloudWatch en un flujo completo:

1. El bootstrap crea el state remoto.
2. Terraform crea la infraestructura.
3. El pipeline construye y publica las imágenes.
4. CodeDeploy despliega en el ASG de reemplazo, el pipeline valida y `promote_bluegreen.sh` conmuta el tráfico.
5. Las alarmas protegen producción y el entorno de reemplazo.
6. El destroy elimina la infraestructura principal y conserva el bootstrap.

El resultado es un despliegue reproducible, verificable y con rollback automático.
