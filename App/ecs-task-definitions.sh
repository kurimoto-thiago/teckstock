# ══════════════════════════════════════════════════════════════════════════════
# ecs-task-definitions.sh
# Cria Task Definitions, Cluster e Services no ECS Fargate
# AWS Learner Lab — us-east-1
#
# PRÉ-REQUISITOS:
#   - ECR repos criados (ecs-setup.sh ou manualmente)
#   - VPC, SGs, ALB e Target Groups da stack base existentes
#   - RDS PostgreSQL rodando
# ══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
REGION="us-east-1"
APP="techstock"
ECR_BACKEND="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${APP}-backend"
ECR_FRONTEND="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${APP}-frontend"

# Valores da stack existente — substitua pelos reais
RDS_ENDPOINT="${RDS_ENDPOINT:-COLE_O_ENDPOINT_AQUI}"
ALB_DNS="${ALB_DNS:-COLE_O_DNS_DO_ALB_AQUI}"
VPC_ID="${VPC_ID:-vpc-XXXXXXXX}"
PRIV_A="${PRIV_A:-subnet-XXXXXXXX}"
PRIV_B="${PRIV_B:-subnet-XXXXXXXX}"
SG_BACKEND="${SG_BACKEND:-sg-XXXXXXXX}"
SG_FRONTEND="${SG_FRONTEND:-sg-XXXXXXXX}"
TG_BACKEND="${TG_BACKEND:-arn:aws:elasticloadbalancing:...}"
TG_FRONTEND="${TG_FRONTEND:-arn:aws:elasticloadbalancing:...}"

echo "Account: $ACCOUNT_ID | Region: $REGION"

# ── 1. Armazena segredos no SSM Parameter Store ───────────────────────────────
# Melhor que variáveis de ambiente direto na Task Definition
# A Task Definition faz referência pelo ARN — valor nunca aparece em logs
echo "Armazenando segredos no SSM..."

aws ssm put-parameter \
  --name "/${APP}/db-password" \
  --value "${DB_PASSWORD:-SenhaForte@2024!}" \
  --type "SecureString" \
  --overwrite 2>/dev/null && echo "  /techstock/db-password: OK"

aws ssm put-parameter \
  --name "/${APP}/cors-origin" \
  --value "http://${ALB_DNS}" \
  --type "String" \
  --overwrite 2>/dev/null && echo "  /techstock/cors-origin: OK"

# ── 2. Grupo de logs no CloudWatch ───────────────────────────────────────────
for lg in "/${APP}/backend" "/${APP}/frontend"; do
  aws logs create-log-group --log-group-name "$lg" 2>/dev/null || true
  aws logs put-retention-policy --log-group-name "$lg" --retention-in-days 7
  echo "  Log group: $lg"
done

# ── 3. ECR Repositories ──────────────────────────────────────────────────────
for repo in "${APP}-backend" "${APP}-frontend"; do
  aws ecr create-repository \
    --repository-name "$repo" \
    --image-scanning-configuration scanOnPush=true \
    --region $REGION 2>/dev/null && echo "  ECR: $repo criado" \
  || echo "  ECR: $repo já existe"
done

# ── 4. Build e Push das imagens ───────────────────────────────────────────────
echo "Login no ECR..."
aws ecr get-login-password --region $REGION | \
  docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "Build do backend..."
docker build -f dockerfiles/Dockerfile.backend -t "${ECR_BACKEND}:latest" .
docker push "${ECR_BACKEND}:latest"

echo "Build do frontend..."
docker build -f dockerfiles/Dockerfile.frontend -t "${ECR_FRONTEND}:latest" .
docker push "${ECR_FRONTEND}:latest"


# ── Verifica permissão SSM ANTES de criar o service (evita ResourceInitializationError) ──
echo "Verificando acesso ao SSM Parameter Store..."
aws ssm get-parameter \
  --name "/${APP}/db-password" \
  --with-decryption \
  --query 'Parameter.Value' --output text > /dev/null 2>&1 \
  && echo "  ✓ SSM: LabRole tem permissão ssm:GetParameter" \
  || { echo "  ✗ ERRO: LabRole sem permissão para /${APP}/db-password"; echo "  Execute o passo 2 (SSM) antes de criar o service."; exit 1; }

# ── 5. Task Definition — Backend ─────────────────────────────────────────────
# networkMode: awsvpc → cada task tem sua própria ENI e IP privado
# requiresCompatibilities: FARGATE → sem EC2 para gerenciar
# CPU/Memory: unidades de CPU (1024=1vCPU) e MB
cat > /tmp/task-backend.json << TASKEOF
{
  "family": "${APP}-backend",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "executionRoleArn": "arn:aws:iam::${ACCOUNT_ID}:role/LabRole",
  "taskRoleArn":      "arn:aws:iam::${ACCOUNT_ID}:role/LabRole",
  "containerDefinitions": [
    {
      "name": "${APP}-backend",
      "image": "${ECR_BACKEND}:latest",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 3000,
          "protocol": "tcp",
          "name": "api"
        }
      ],
      "environment": [
        {"name": "DB_HOST",     "value": "${RDS_ENDPOINT}"},
        {"name": "DB_PORT",     "value": "5432"},
        {"name": "DB_NAME",     "value": "techstock"},
        {"name": "DB_USER",     "value": "techstock_user"},
        {"name": "DB_SSL",      "value": "true"},
        {"name": "DB_POOL_MIN", "value": "1"},
        {"name": "DB_POOL_MAX", "value": "5"},
        {"name": "PORT",        "value": "3000"},
        {"name": "NODE_ENV",    "value": "production"},
        {"name": "AWS_REGION",  "value": "${REGION}"}
      ],
      "secrets": [
        {
          "name": "DB_PASSWORD",
          "valueFrom": "arn:aws:ssm:${REGION}:${ACCOUNT_ID}:parameter/${APP}/db-password"
        },
        {
          "name": "CORS_ORIGIN",
          "valueFrom": "arn:aws:ssm:${REGION}:${ACCOUNT_ID}:parameter/${APP}/cors-origin"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group":         "/${APP}/backend",
          "awslogs-region":        "${REGION}",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "healthCheck": {
        "command":     ["CMD-SHELL", "wget -qO- http://localhost:3000/api/health || exit 1"],
        "interval":    30,
        "timeout":     10,
        "retries":     3,
        "startPeriod": 60
      },
      "readonlyRootFilesystem": false,
      "ulimits": [
        {"name": "nofile", "softLimit": 65536, "hardLimit": 65536}
      ]
    }
  ]
}
TASKEOF

BACKEND_TASK_DEF=$(aws ecs register-task-definition \
  --cli-input-json file:///tmp/task-backend.json \
  --query 'taskDefinition.taskDefinitionArn' --output text)
echo "Task Definition Backend: $BACKEND_TASK_DEF"

# ── 6. Task Definition — Frontend ────────────────────────────────────────────
cat > /tmp/task-frontend.json << TASKEOF
{
  "family": "${APP}-frontend",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "arn:aws:iam::${ACCOUNT_ID}:role/LabRole",
  "taskRoleArn":      "arn:aws:iam::${ACCOUNT_ID}:role/LabRole",
  "containerDefinitions": [
    {
      "name": "${APP}-frontend",
      "image": "${ECR_FRONTEND}:latest",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 80,
          "protocol": "tcp",
          "name": "http"
        }
      ],
      "environment": [
        {"name": "BACKEND_URL", "value": "http://${ALB_DNS}"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group":         "/${APP}/frontend",
          "awslogs-region":        "${REGION}",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "healthCheck": {
        "command":     ["CMD-SHELL", "wget -qO- http://localhost/health || exit 1"],
        "interval":    30,
        "timeout":     5,
        "retries":     3,
        "startPeriod": 30
      }
    }
  ]
}
TASKEOF

FRONTEND_TASK_DEF=$(aws ecs register-task-definition \
  --cli-input-json file:///tmp/task-frontend.json \
  --query 'taskDefinition.taskDefinitionArn' --output text)
echo "Task Definition Frontend: $FRONTEND_TASK_DEF"

# ── 7. ECS Cluster ────────────────────────────────────────────────────────────
# FARGATE_SPOT: até 70% mais barato, pode ser interrompido (OK para lab)
# FARGATE: on-demand, garantido (use em produção para tarefas críticas)
aws ecs create-cluster \
  --cluster-name "${APP}-cluster" \
  --capacity-providers FARGATE FARGATE_SPOT \
  --default-capacity-provider-strategy \
    capacityProvider=FARGATE,weight=1,base=1 \
  --settings name=containerInsights,value=enabled \
  2>/dev/null && echo "Cluster criado" || echo "Cluster já existe"

# ── 8. Services ───────────────────────────────────────────────────────────────
# desiredCount=2: sempre 2 tasks para HA
# minimumHealthyPercent=50: permite remover 50% durante updates
# maximumPercent=200: permite ter 200% temporariamente (rolling deploy sem downtime)

echo "Criando service Backend..."
aws ecs create-service \
  --cluster "${APP}-cluster" \
  --service-name "${APP}-backend" \
  --task-definition "$BACKEND_TASK_DEF" \
  --desired-count 2 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={
    subnets=[${PRIV_A},${PRIV_B}],
    securityGroups=[${SG_BACKEND}],
    assignPublicIp=DISABLED
  }" \
  --load-balancers "targetGroupArn=${TG_BACKEND},containerName=${APP}-backend,containerPort=3000" \
  --deployment-configuration \
    "minimumHealthyPercent=50,maximumPercent=200,deploymentCircuitBreaker={enable=true,rollback=true}" \
  --health-check-grace-period-seconds 60

echo "Criando service Frontend..."
aws ecs create-service \
  --cluster "${APP}-cluster" \
  --service-name "${APP}-frontend" \
  --task-definition "$FRONTEND_TASK_DEF" \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={
    subnets=[${PRIV_A},${PRIV_B}],
    securityGroups=[${SG_FRONTEND}],
    assignPublicIp=DISABLED
  }" \
  --load-balancers "targetGroupArn=${TG_FRONTEND},containerName=${APP}-frontend,containerPort=80" \
  --deployment-configuration \
    "minimumHealthyPercent=100,maximumPercent=200,deploymentCircuitBreaker={enable=true,rollback=true}"

echo ""
echo "=== ECS Deploy Concluído ==="
echo ""
echo "Monitorar:"
echo "  aws ecs list-tasks --cluster ${APP}-cluster"
echo "  aws logs tail /${APP}/backend --follow"
echo "  aws logs tail /${APP}/frontend --follow"
echo ""
echo "Frontend: http://${ALB_DNS}/"
echo "API:      http://${ALB_DNS}/api/health"
