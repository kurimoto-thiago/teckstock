#!/bin/bash
# =============================================================================
# setup-backend.sh — Configuração do EC2 Backend
# TechStock | Execução interativa via SSM Session Manager ou SSH
#
# COMO USAR:
#   sudo bash setup-backend.sh
#   OU copie e cole cada seção manualmente no terminal
#
# CORREÇÕES APLICADAS:
#   - DB_SSL=true para RDS PostgreSQL (exige SSL)
#   - EnvironmentFile no systemd (garante .env mesmo se dotenv falhar)
#   - Permissões do .env definidas antes do chown geral
#   - Verificação de leitura do .env pelo usuário techstock
# =============================================================================

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 1 — VARIÁVEIS (edite antes de executar)
# ══════════════════════════════════════════════════════════════════════════════

DB_HOST="COLE_O_ENDPOINT_DO_RDS_AQUI"
# Exemplo: techstock-db.abc123.us-east-1.rds.amazonaws.com

DB_PASSWORD="SenhaForte@2024!"

CORS_ORIGIN="http://COLE_O_DNS_DO_ALB_AQUI"
# Exemplo: http://techstock-lb-105375070.us-east-1.elb.amazonaws.com
# Para S3: http://techstock-CONTA.s3-website-us-east-1.amazonaws.com
# IMPORTANTE: sem barra no final, com http://, sem espaços

DB_SSL="true"
# RDS PostgreSQL → true (obrigatório)
# EC2 PostgreSQL sem SSL → false

S3_BUCKET=""
# Opcional: nome do bucket com os arquivos do backend

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 2 — Valida variáveis
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "============================================"
echo " TechStock — Setup Backend"
echo " $(date)"
echo "============================================"
echo ""

if [[ "$DB_HOST" == "COLE_O_ENDPOINT_DO_RDS_AQUI" ]]; then
  echo "ERRO: edite DB_HOST na SEÇÃO 1 antes de continuar."
  exit 1
fi
if [[ "$CORS_ORIGIN" == *"COLE_O_DNS"* ]]; then
  echo "AVISO: CORS_ORIGIN não configurado — usando * (qualquer origem)"
  CORS_ORIGIN="*"
fi

echo "Configurações:"
echo "  DB_HOST     = $DB_HOST"
echo "  DB_SSL      = $DB_SSL"
echo "  CORS_ORIGIN = $CORS_ORIGIN"
echo ""
read -p "Confirma? (s/N): " CONFIRM
[[ "$CONFIRM" =~ ^[Ss]$ ]] || { echo "Cancelado."; exit 0; }

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 3 — Atualização do sistema
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "--- [1/8] Atualizando sistema ---"
dnf update -y
dnf install -y nodejs npm postgresql15 git wget curl
echo "Node.js: $(node --version) | npm: $(npm --version)"

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 4 — Usuário e diretório
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "--- [2/8] Criando usuário e diretório ---"
useradd -r -m -d /opt/techstock -s /bin/bash techstock 2>/dev/null \
  && echo "Usuário techstock: criado" \
  || echo "Usuário techstock: já existe (ok)"

mkdir -p /opt/techstock/public

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 5 — Arquivos da aplicação
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "--- [3/8] Copiando arquivos da aplicação ---"

if [[ -n "$S3_BUCKET" ]]; then
  echo "Copiando do S3: s3://$S3_BUCKET/backend/"
  aws s3 sync s3://$S3_BUCKET/backend/ /opt/techstock/
else
  echo "S3_BUCKET não definido. Copie os arquivos manualmente:"
  echo "  scp -i vockey.pem backend/* ec2-user@IP:/tmp/"
  echo "  sudo cp /tmp/{server.js,package.json,schema.sql} /opt/techstock/"
  echo ""
  echo "Após copiar, pressione Enter para continuar..."
  read -p ""
fi

for f in server.js package.json; do
  if [[ ! -f /opt/techstock/$f ]]; then
    echo "ERRO: /opt/techstock/$f não encontrado."
    exit 1
  fi
done
echo "Arquivos OK: $(ls /opt/techstock/*.js /opt/techstock/package.json 2>/dev/null | tr '\n' ' ')"

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 6 — npm install
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "--- [4/8] Instalando dependências Node.js ---"
cd /opt/techstock
npm install --omit=dev
echo "Pacotes instalados: $(ls node_modules | wc -l)"

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 7 — Arquivo .env
# CORREÇÃO: permissões definidas imediatamente após criar o arquivo
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "--- [5/8] Criando arquivo .env ---"

cat > /opt/techstock/.env << ENV
DB_HOST=${DB_HOST}
DB_PORT=5432
DB_NAME=techstock
DB_USER=techstock_user
DB_PASSWORD=${DB_PASSWORD}
DB_POOL_MIN=1
DB_POOL_MAX=5
DB_SSL=${DB_SSL}
PORT=3000
NODE_ENV=production
CORS_ORIGIN=${CORS_ORIGIN}
AWS_REGION=us-east-1
ENV

# CRÍTICO: permissões antes do chown geral
chown techstock:techstock /opt/techstock/.env
chmod 640 /opt/techstock/.env

echo "Permissões do .env:"
ls -la /opt/techstock/.env

# Verifica se techstock consegue ler
echo "Teste de leitura pelo usuário techstock:"
sudo -u techstock cat /opt/techstock/.env | grep -v PASSWORD \
  && echo "Leitura: OK" \
  || { echo "ERRO: techstock não consegue ler o .env!"; exit 1; }

# Aplica ownership no resto do diretório
chown -R techstock:techstock /opt/techstock
chmod 755 /opt/techstock

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 8 — Schema do banco
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "--- [6/8] Inicializando schema do banco ---"

if [[ -f /opt/techstock/schema.sql ]]; then
  echo "Executando schema.sql no RDS ($DB_HOST)..."
  PGPASSWORD="$DB_PASSWORD" psql \
    -h "$DB_HOST" \
    -U techstock_user \
    -d techstock \
    --set=sslmode=require \
    -f /opt/techstock/schema.sql \
    && echo "Schema: OK" \
    || echo "AVISO: erro no schema — execute manualmente se necessário"
else
  echo "schema.sql não encontrado. Execute depois:"
  echo "  PGPASSWORD='...' psql -h $DB_HOST -U techstock_user -d techstock --set=sslmode=require -f schema.sql"
fi

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 9 — Serviço systemd
# CORREÇÃO: EnvironmentFile carrega o .env no nível do systemd
# (garante variáveis mesmo se o dotenv do Node.js não encontrar o arquivo)
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "--- [7/8] Configurando serviço systemd ---"

cat > /etc/systemd/system/techstock.service << 'SVC'
[Unit]
Description=TechStock Backend API
After=network.target

[Service]
Type=simple
User=techstock
WorkingDirectory=/opt/techstock

# Carrega variáveis do .env no nível do systemd
# Garante funcionamento mesmo que o dotenv falhe ao encontrar o arquivo
EnvironmentFile=/opt/techstock/.env

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
sleep 3

echo ""
echo "Status do serviço:"
systemctl status techstock --no-pager -l

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 10 — Node Exporter + CloudWatch Agent
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "--- [8/8] Instalando Node Exporter + CloudWatch Agent ---"

# Node Exporter
NODE_EXPORTER_VERSION="1.7.0"
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

# CloudWatch Agent
dnf install -y amazon-cloudwatch-agent

cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CW'
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
echo "Teste da API local:"
sleep 2
curl -s http://localhost:3000/api/health | python3 -m json.tool 2>/dev/null \
  || curl -s http://localhost:3000/api/health

echo ""
echo "Teste CORS (deve retornar access-control-allow-origin):"
curl -s -I -H "Origin: $CORS_ORIGIN" \
  -X OPTIONS http://localhost:3000/api/produtos 2>&1 | grep -i "access-control" \
  || echo "(sem resposta CORS — verifique se CORS_ORIGIN está correto)"

echo ""
echo "============================================"
echo " Setup CONCLUÍDO: $(date)"
echo "============================================"
echo ""
echo "IP privado desta instância: $(hostname -I | awk '{print $1}')"
echo ""
echo "Para alterar CORS depois:"
echo "  sudo nano /opt/techstock/.env"
echo "  sudo systemctl restart techstock"
echo ""
echo "Para ver logs:"
echo "  sudo journalctl -u techstock -f"
echo ""
