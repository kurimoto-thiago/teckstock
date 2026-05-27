#!/bin/bash
# =============================================================================
# setup-backend.sh — Configuração do EC2 Backend TechStock
# Node.js :3000 | PostgreSQL (RDS) | Node Exporter | CloudWatch Agent
# Execução via SSM Session Manager
# =============================================================================

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 1 — VARIÁVEIS FIXAS (não alterar)
# ══════════════════════════════════════════════════════════════════════════════
DB_NAME="techstock"
DB_USER="techstock_user"
DB_PORT="5432"
DB_SSL="true"
NODE_EXPORTER_VERSION="1.7.0"
APP_DIR="/opt/techstock"

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 2 — ENTRADA INTERATIVA DE DADOS
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "============================================"
echo " TechStock — Setup Backend"
echo " $(date)"
echo "============================================"
echo ""

# Região da AWS
while true; do
  echo "Região AWS:"
  echo "  Exemplo: us-east-1, us-west-2, sa-east-1"
  read -p "  → " REGION
  REGION="${REGION// /}"
  [[ -n "$REGION" ]] && break
  echo "  ✗ Obrigatório. Tente novamente."
  echo ""
done
echo "  ✓ REGION: $REGION"
echo ""

# RDS Endpoint — obrigatório
while true; do
  echo "Endpoint do RDS (sem porta):"
  echo "  Exemplo: techstock-db.xxxx.us-east-1.rds.amazonaws.com"
  echo "  Console AWS → RDS → Databases → techstock → Endpoint"
  read -p "  → " DB_HOST
  DB_HOST="${DB_HOST// /}"
  [[ -n "$DB_HOST" ]] && break
  echo "  ✗ Obrigatório. Tente novamente."
  echo ""
done
echo "  ✓ DB_HOST: $DB_HOST"
echo ""

# Senha do RDS — obrigatório
while true; do
  echo "Senha do banco (DB_PASSWORD):"
  read -s -p "  → " DB_PASSWORD
  echo ""
  [[ -n "$DB_PASSWORD" ]] && break
  echo "  ✗ Obrigatório. Tente novamente."
  echo ""
done
echo "  ✓ DB_PASSWORD: (definida)"
echo ""

# ALB DNS para CORS — obrigatório
while true; do
  echo "DNS do ALB (sem http://) para configurar CORS:"
  echo "  Exemplo: techstock-alb-105375070.us-east-1.elb.amazonaws.com"
  read -p "  → " ALB_INPUT
  ALB_INPUT="${ALB_INPUT// /}"
  ALB_INPUT="${ALB_INPUT#http://}"
  ALB_INPUT="${ALB_INPUT#https://}"
  ALB_INPUT="${ALB_INPUT%/}"
  [[ -n "$ALB_INPUT" ]] && break
  echo "  ✗ Obrigatório. Tente novamente."
  echo ""
done
CORS_ORIGIN="http://${ALB_INPUT}"
echo "  ✓ CORS_ORIGIN: $CORS_ORIGIN"
echo ""

# GitHub — URL base do repositório
echo "URL base do repositório GitHub (raw):"
echo "  Exemplo: https://raw.githubusercontent.com/SEU_USER/SEU_REPO/main"
echo "  Como obter: GitHub → arquivo → botão Raw → copie a URL até /main"
read -p "  → " GITHUB_RAW
GITHUB_RAW="${GITHUB_RAW// /}"
GITHUB_RAW="${GITHUB_RAW%/}"
if [[ -n "$GITHUB_RAW" ]]; then
  echo "  ✓ GITHUB_RAW: $GITHUB_RAW"
  echo "  Subdiretório do backend no repo (Enter se raiz):"
  echo "  Exemplo: backend  ou  src/backend"
  read -p "  → " GITHUB_SUBDIR
  GITHUB_SUBDIR="${GITHUB_SUBDIR// /}"
  GITHUB_SUBDIR="${GITHUB_SUBDIR%/}"
  [[ -n "$GITHUB_SUBDIR" ]] && GITHUB_BASE="${GITHUB_RAW}/${GITHUB_SUBDIR}" || GITHUB_BASE="$GITHUB_RAW"
  echo "  ✓ URL arquivos: $GITHUB_BASE"
else
  GITHUB_BASE=""
  echo "  ⚠ Pulado — faça upload manual dos arquivos"
fi
echo ""

# Confirmação
echo "--------------------------------------------"
echo " Resumo da configuração:"
echo "   REGION      = $REGION"
echo "   DB_HOST     = $DB_HOST"
echo "   DB_NAME     = $DB_NAME"
echo "   DB_USER     = $DB_USER"
echo "   DB_PASSWORD = $DB_PASSWORD"
echo "   DB_SSL      = $DB_SSL"
echo "   CORS_ORIGIN = $CORS_ORIGIN"
echo "   GITHUB_BASE = ${GITHUB_BASE:-'(upload manual)'}"
echo "--------------------------------------------"
echo "--------------------------------------------"
echo ""
read -p "Confirma e inicia a instalação? (s/N): " CONFIRM
[[ "$CONFIRM" =~ ^[Ss]$ ]] || { echo "Cancelado."; exit 0; }

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 3 — Atualização do sistema
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [1/8] Atualizando sistema ---"
dnf update -y
dnf install -y nodejs npm postgresql15 git wget
echo "Node.js: $(node --version) | npm: $(npm --version)"

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 4 — Usuário e diretório
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [2/8] Criando usuário e diretório ---"
useradd -r -m -d $APP_DIR -s /bin/bash techstock 2>/dev/null \
  && echo "Usuário techstock: criado" \
  || echo "Usuário techstock: já existe (ok)"
mkdir -p $APP_DIR/public

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 5 — Arquivos da aplicação
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [3/8] Copiando arquivos da aplicação ---"

if [[ -n "$GITHUB_BASE" ]]; then
  echo "Baixando arquivos do GitHub: $GITHUB_BASE"
  mkdir -p $APP_DIR
  for f in server.js package.json schema.sql; do
    echo "  baixando $f..."
    if wget -q -O $APP_DIR/$f "$GITHUB_BASE/$f"; then
      echo "  ✓ $f"
    else
      echo "  ✗ $f — não encontrado em $GITHUB_BASE/$f"
    fi
  done
  # Opcionais
  for f in package-lock.json; do
    wget -q -O $APP_DIR/$f "$GITHUB_BASE/$f" 2>/dev/null && echo "  ✓ $f" || true
  done
  echo ""
  echo "Arquivos baixados:"
  ls -la $APP_DIR/ 2>/dev/null
else
  echo ""
  echo "Copie os arquivos manualmente para $APP_DIR/:"
  echo "  GitHub (raw):"
  echo "    BASE=https://raw.githubusercontent.com/USER/REPO/main"
  echo "    for f in server.js package.json schema.sql; do"
  echo "      wget -O $APP_DIR/\$f \$BASE/\$f"
  echo "    done"
  echo ""
  echo "  scp:"
  echo "    scp -i vockey.pem server.js package.json schema.sql ec2-user@IP:/tmp/"
  echo "    sudo cp /tmp/{server.js,package.json,schema.sql} $APP_DIR/"
  echo ""
  echo "Pressione Enter após copiar os arquivos..."
  read -p ""
fi

for f in server.js package.json; do
  [[ ! -f $APP_DIR/$f ]] && { echo "ERRO: $APP_DIR/$f não encontrado."; exit 1; }
done
echo "Arquivos OK: $(ls $APP_DIR/*.js $APP_DIR/package.json 2>/dev/null | tr '\n' ' ')"

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 6 — npm install
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [4/8] Instalando dependências Node.js ---"
cd $APP_DIR
npm install --omit=dev
echo "Pacotes instalados: $(ls node_modules | wc -l)"

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 7 — Arquivo .env
# CORREÇÃO: permissões definidas antes do chown geral
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [5/8] Criando arquivo .env ---"

cat > $APP_DIR/.env << ENV
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DB_POOL_MIN=1
DB_POOL_MAX=5
DB_SSL=${DB_SSL}
PORT=3000
NODE_ENV=production
CORS_ORIGIN=${CORS_ORIGIN}
AWS_REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "us-east-1")
ENV

# Permissões antes do chown geral
chown techstock:techstock $APP_DIR/.env
chmod 640 $APP_DIR/.env

echo "Permissões do .env:"
ls -la $APP_DIR/.env

# Verifica se o usuário techstock consegue ler
sudo -u techstock cat $APP_DIR/.env | grep -v PASSWORD \
  && echo "Leitura pelo usuário techstock: OK" \
  || { echo "ERRO: techstock não consegue ler o .env!"; exit 1; }

# Aplica ownership no resto
chown -R techstock:techstock $APP_DIR
chmod 755 $APP_DIR

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 8 — Schema do banco
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [6/8] Inicializando schema do banco ---"

if [[ -f $APP_DIR/schema.sql ]]; then
  echo "Executando schema.sql em $DB_HOST..."
  PGPASSWORD="$DB_PASSWORD" psql \
    -h "$DB_HOST" \
    -U "$DB_USER" \
    -d "$DB_NAME" \
    --set=sslmode=require \
    -f $APP_DIR/schema.sql \
    && echo "Schema: OK" \
    || echo "AVISO: erro no schema — execute manualmente se necessário"
else
  echo "schema.sql não encontrado. Execute depois:"
  echo "  PGPASSWORD='...' psql -h $DB_HOST -U $DB_USER -d $DB_NAME --set=sslmode=require -f schema.sql"
fi

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 9 — Serviço systemd
# CORREÇÃO: EnvironmentFile garante variáveis mesmo se dotenv falhar
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [7/8] Configurando serviço systemd ---"

cat > /etc/systemd/system/techstock.service << SVC
[Unit]
Description=TechStock Backend API
After=network.target

[Service]
Type=simple
User=techstock
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
ExecStart=/usr/bin/node server.js
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=techstock

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable techstock
systemctl start techstock
sleep 4

echo ""
echo "Status do serviço:"
systemctl is-active techstock

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 10 — Node Exporter + CloudWatch Agent
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [8/8] Instalando Node Exporter + CloudWatch Agent ---"

wget -q \
  "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz" \
  -O /tmp/node_exporter.tar.gz
tar xzf /tmp/node_exporter.tar.gz -C /tmp/
cp /tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter /usr/local/bin/
chmod +x /usr/local/bin/node_exporter

cat > /etc/systemd/system/node_exporter.service << 'NE'
[Unit]
Description=Node Exporter
After=network.target
[Service]
Type=simple
User=nobody
ExecStart=/usr/local/bin/node_exporter
Restart=on-failure
[Install]
WantedBy=multi-user.target
NE

dnf install -y amazon-cloudwatch-agent

REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "us-east-1")
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << CW
{
  "logs": {
    "logs_collected": {
      "systemd": {
        "collect_list": [
          {
            "log_group_name": "/techstock/app",
            "log_stream_name": "{instance_id}",
            "log_system_journal_id": "techstock"
          }
        ]
      }
    }
  },
  "metrics": {
    "namespace": "TechStock/EC2",
    "metrics_collected": {
      "cpu":  { "measurement": ["cpu_usage_active"],  "metrics_collection_interval": 60 },
      "mem":  { "measurement": ["mem_used_percent"],   "metrics_collection_interval": 60 },
      "disk": { "measurement": ["disk_used_percent"],  "resources": ["/"], "metrics_collection_interval": 60 }
    }
  }
}
CW

systemctl daemon-reload
systemctl enable node_exporter amazon-cloudwatch-agent
systemctl start  node_exporter amazon-cloudwatch-agent

# ══════════════════════════════════════════════════════════════════════════════
# VERIFICAÇÃO FINAL
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "============================================"
echo " Verificação Final"
echo "============================================"

echo ""
echo "Serviços:"
for svc in techstock node_exporter amazon-cloudwatch-agent; do
  STATUS=$(systemctl is-active $svc 2>/dev/null)
  ICON=$([[ "$STATUS" == "active" ]] && echo "✓" || echo "✗")
  echo "  $ICON $svc: $STATUS"
done

echo ""
echo "Teste da API:"
sleep 2
curl -s http://localhost:3000/api/health | python3 -m json.tool 2>/dev/null \
  || curl -s http://localhost:3000/api/health

echo ""
echo "Teste CORS:"
curl -s -I -H "Origin: $CORS_ORIGIN" \
  http://localhost:3000/api/produtos 2>&1 | grep -i "access-control" \
  || echo "  (sem header CORS — verifique CORS_ORIGIN)"

echo ""
echo "Node Exporter:"
curl -s http://localhost:9100/metrics | grep "^node_load1" | head -1

echo ""
echo "============================================"
echo " Setup CONCLUÍDO: $(date)"
echo "============================================"
echo ""
MY_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null)
echo "IP privado desta instância: $MY_IP"
echo ""
echo "Para ver logs:"
echo "  sudo journalctl -u techstock -f"
echo ""
echo "Para alterar variáveis:"
echo "  sudo nano $APP_DIR/.env"
echo "  sudo systemctl restart techstock"
echo ""
echo "PENDÊNCIAS MANUAIS (Console AWS):"
echo "  1. Adicionar este EC2 ao Target Group do ALB (porta 3000)"
echo "  2. SG do Backend: liberar 3000 e 9100 para o SG do EC2 Monitoring"
