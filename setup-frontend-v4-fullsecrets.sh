#!/bin/bash
# =============================================================================
# setup-frontend.sh — v4 FULL SECRETS MANAGER
# Todas as variáveis armazenadas no Secrets Manager.
# Confronta valores existentes e oferece atualização antes de prosseguir.
# =============================================================================

echo ""
echo "============================================"
echo " TechStock — Setup Frontend v4"
echo " $(date)"
echo "============================================"
echo ""
echo "Para começar, informe a região e o nome do secret."
echo ""

echo "Região AWS (ex: us-east-1, us-west-2, sa-east-1):"
read -p "  → " AWS_REGION
AWS_REGION="${AWS_REGION// /}"
while [[ -z "$AWS_REGION" ]]; do
  echo "  ✗ Obrigatório."
  read -p "  → " AWS_REGION
  AWS_REGION="${AWS_REGION// /}"
done
echo "  ✓ AWS_REGION: $AWS_REGION"
echo ""

echo "Nome do secret no Secrets Manager:"
echo "  Padrão: techstock/frontend  (Enter para usar o padrão)"
read -p "  → " SECRET_NAME
SECRET_NAME="${SECRET_NAME// /}"
[[ -z "$SECRET_NAME" ]] && SECRET_NAME="techstock/frontend"
echo "  ✓ SECRET_NAME: $SECRET_NAME"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# Lê secret existente
# ══════════════════════════════════════════════════════════════════════════════
echo "Buscando secret '$SECRET_NAME'..."
SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_NAME" \
  --region "$AWS_REGION" \
  --query SecretString \
  --output text 2>/dev/null)
SECRET_EXISTS=$?

get_field() {
  echo "$SECRET_JSON" | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  print(d.get('$1',''))
except:
  print('')
" 2>/dev/null
}

if [[ $SECRET_EXISTS -eq 0 && -n "$SECRET_JSON" ]]; then
  echo "  ✓ Secret encontrado — carregando valores existentes..."
  EXISTING=true
  ALB_DNS=$(get_field ALB_DNS)
  WEBROOT=$(get_field WEBROOT)
  NODE_EXPORTER_VERSION=$(get_field NODE_EXPORTER_VERSION)
  GITHUB_RAW=$(get_field GITHUB_RAW)
  GITHUB_SUBDIR=$(get_field GITHUB_SUBDIR)
else
  echo "  ⚠ Secret não encontrado — será criado com novos valores."
  EXISTING=false
  WEBROOT="/usr/share/nginx/html/techstock"
  NODE_EXPORTER_VERSION="1.7.0"
fi
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# Apresenta valores e pergunta se deseja atualizar
# ══════════════════════════════════════════════════════════════════════════════
echo "============================================"
echo " Valores atuais do secret"
echo "============================================"
echo "  ALB_DNS              = ${ALB_DNS:-'(não definido)'}"
echo "  WEBROOT              = ${WEBROOT}"
echo "  NODE_EXPORTER_VERSION= ${NODE_EXPORTER_VERSION}"
echo "  GITHUB_RAW           = ${GITHUB_RAW:-'(não definido)'}"
echo "  GITHUB_SUBDIR        = ${GITHUB_SUBDIR:-'(raiz)'}"
echo "============================================"
echo ""

# ── Função de entrada com label garantido ──────────────────────────────────
# Usa printf em vez de echo+read separados para evitar condição de corrida
# entre stdout e stderr. Destaca o nome do campo em negrito.
prompt_field() {
  local label="$1" current="$2"
  local BOLD=$'\033[1m' RESET=$'\033[0m'
  printf "  ${BOLD}%s${RESET}\n       (Enter para manter: %s)\n    → " "$label" "${current:-'(vazio)'}"
  read result
  printf "%s\n" "${result:-$current}"
}

if [[ "$EXISTING" == "true" ]]; then
  echo "Deseja atualizar algum valor? (s/N)"
  read -p "  → " UPDATE_CHOICE
else
  UPDATE_CHOICE="s"
  echo "Preenchimento dos valores obrigatórios:"
fi
echo ""

if [[ "$UPDATE_CHOICE" =~ ^[Ss]$ ]]; then
  echo "── Frontend ────────────────────────────────"
  ALB_DNS=$(prompt_field "DNS do ALB (sem http://)" "$ALB_DNS")
  ALB_DNS="${ALB_DNS#http://}"; ALB_DNS="${ALB_DNS#https://}"; ALB_DNS="${ALB_DNS%/}"
  WEBROOT=$(prompt_field "Diretório raiz do Nginx (WEBROOT)" "$WEBROOT")
  echo ""
  echo "── Infraestrutura ──────────────────────────"
  NODE_EXPORTER_VERSION=$(prompt_field "Versão Node Exporter" "$NODE_EXPORTER_VERSION")
  echo ""
  echo "── GitHub ──────────────────────────────────"
  GITHUB_RAW=$(prompt_field "URL base do repo (raw GitHub)" "$GITHUB_RAW")
  GITHUB_SUBDIR=$(prompt_field "Subdiretório do frontend (vazio = raiz)" "$GITHUB_SUBDIR")
  echo ""
fi

GITHUB_RAW="${GITHUB_RAW%/}"; GITHUB_SUBDIR="${GITHUB_SUBDIR%/}"
[[ -n "$GITHUB_SUBDIR" ]] && GITHUB_BASE="${GITHUB_RAW}/${GITHUB_SUBDIR}" || GITHUB_BASE="$GITHUB_RAW"

# Validação
ERRORS=0
[[ -z "$ALB_DNS" ]] && echo "  ✗ ALB_DNS é obrigatório" && ERRORS=$((ERRORS+1))
[[ -z "$GITHUB_RAW" ]] && echo "  ⚠ GITHUB_RAW não definido — upload manual necessário"
[[ $ERRORS -gt 0 ]] && { echo "  ✗ Corrija e execute novamente."; exit 1; }

echo "============================================"
echo " Resumo final"
echo "============================================"
echo "  SECRET_NAME          = $SECRET_NAME"
echo "  AWS_REGION           = $AWS_REGION"
echo "  ALB_DNS              = $ALB_DNS"
echo "  API_URL              = http://$ALB_DNS"
echo "  WEBROOT              = $WEBROOT"
echo "  NODE_EXPORTER_VERSION= $NODE_EXPORTER_VERSION"
echo "  GITHUB_BASE          = ${GITHUB_BASE:-'(upload manual)'}"
echo "============================================"
echo ""
read -p "Confirma e salva no Secrets Manager? (s/N): " CONFIRM
[[ "$CONFIRM" =~ ^[Ss]$ ]] || { echo "Cancelado."; exit 0; }

# ── Salva secret ──────────────────────────────────────────────────────────────
echo ""
echo "Salvando secret..."
SECRET_JSON=$(python3 -c "
import json
print(json.dumps({
  'ALB_DNS':               '${ALB_DNS}',
  'AWS_REGION':            '${AWS_REGION}',
  'WEBROOT':               '${WEBROOT}',
  'NODE_EXPORTER_VERSION': '${NODE_EXPORTER_VERSION}',
  'GITHUB_RAW':            '${GITHUB_RAW}',
  'GITHUB_SUBDIR':         '${GITHUB_SUBDIR}',
  'TECHSTOCK_SECRET_NAME': '${SECRET_NAME}'
}))
")

if [[ "$EXISTING" == "true" ]]; then
  aws secretsmanager put-secret-value \
    --secret-id "$SECRET_NAME" --secret-string "$SECRET_JSON" --region "$AWS_REGION" \
    && echo "  ✓ Secret atualizado" || { echo "  ✗ Erro ao atualizar"; exit 1; }
else
  aws secretsmanager create-secret \
    --name "$SECRET_NAME" \
    --description "TechStock Frontend — variáveis de configuração" \
    --secret-string "$SECRET_JSON" --region "$AWS_REGION" \
    && echo "  ✓ Secret criado" || { echo "  ✗ Erro ao criar"; exit 1; }
fi

# ══════════════════════════════════════════════════════════════════════════════
# Instalação
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [1/5] Atualizando sistema e instalando Nginx ---"
dnf update -y
dnf install -y nginx wget
echo "Nginx: $(nginx -v 2>&1)"

cat > /etc/nginx/nginx.conf << 'NGXMAIN'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log notice;
pid /run/nginx.pid;
include /usr/share/nginx/modules/*.conf;
events { worker_connections 1024; }
http {
    log_format main '$remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent';
    access_log /var/log/nginx/access.log main;
    sendfile on; tcp_nopush on; keepalive_timeout 65;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    include /etc/nginx/conf.d/*.conf;
}
NGXMAIN

echo ""
echo "--- [2/5] Diretório e arquivos ---"
mkdir -p $WEBROOT
chown -R nginx:nginx $WEBROOT; chmod -R 755 $WEBROOT

if [[ -n "$GITHUB_BASE" ]]; then
  for f in index.html style.css app.js config.js; do
    echo "  baixando $f..."
    wget -q -O $WEBROOT/$f "$GITHUB_BASE/$f" && echo "  ✓ $f" || echo "  ✗ $f"
  done
  chown -R nginx:nginx $WEBROOT/; chmod -R 755 $WEBROOT/
else
  echo "Copie os arquivos para $WEBROOT/ e pressione Enter..."
  read -p ""
  chown -R nginx:nginx $WEBROOT/; chmod -R 755 $WEBROOT/
fi

echo ""
echo "--- [3/5] Configurando config.js ---"
cat > $WEBROOT/config.js << CFG
// config.js — gerado em $(date) | secret: ${SECRET_NAME}
window.TECHSTOCK_CONFIG = { apiUrl: 'http://${ALB_DNS}' };
CFG
chown nginx:nginx $WEBROOT/config.js; chmod 644 $WEBROOT/config.js
cat $WEBROOT/config.js
echo ""
echo "Arquivos:"
for f in index.html style.css app.js config.js; do
  [[ -f $WEBROOT/$f ]] && echo "  ✓ $f ($(stat -c%s $WEBROOT/$f) bytes)" || echo "  ✗ $f FALTANDO"
done

echo ""
echo "--- [4/5] Nginx ---"
cat > /etc/nginx/conf.d/techstock.conf << 'NGINX'
server {
    listen 80 default_server;
    server_name _;
    root  /usr/share/nginx/html/techstock;
    index index.html;
    location = /config.js {
        add_header Cache-Control "no-store, no-cache, must-revalidate";
        add_header Pragma "no-cache"; expires -1;
    }
    location / {
        try_files $uri $uri/ /index.html;
        add_header Cache-Control "no-cache";
        add_header X-Frame-Options "SAMEORIGIN";
    }
    location ~* \.(css|js)$ { expires 1h; add_header Cache-Control "public, max-age=3600"; }
    location = /health {
        default_type application/json;
        return 200 '{"ok":true,"service":"frontend-nginx"}';
        add_header Content-Type application/json;
    }
    access_log /var/log/nginx/techstock-access.log;
    error_log  /var/log/nginx/techstock-error.log;
}
NGINX
nginx -t && echo "Nginx OK" || { echo "ERRO Nginx!"; exit 1; }
systemctl enable nginx; systemctl restart nginx
sleep 2; echo "nginx: $(systemctl is-active nginx)"

echo ""
echo "--- [5/5] Node Exporter + CloudWatch ---"
wget -q "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz" -O /tmp/ne.tar.gz
tar xzf /tmp/ne.tar.gz -C /tmp/
cp /tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter /usr/local/bin/ 2>/dev/null || true
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
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CW'
{
  "logs": { "logs_collected": { "files": { "collect_list": [
    { "file_path": "/var/log/nginx/techstock-access.log", "log_group_name": "/techstock/nginx-access", "log_stream_name": "{instance_id}" },
    { "file_path": "/var/log/nginx/techstock-error.log",  "log_group_name": "/techstock/nginx-error",  "log_stream_name": "{instance_id}" }
  ]}}},
  "metrics": { "namespace": "TechStock/Frontend", "metrics_collected": {
    "cpu": { "measurement": ["cpu_usage_active"], "metrics_collection_interval": 60 },
    "mem": { "measurement": ["mem_used_percent"],  "metrics_collection_interval": 60 }
  }}
}
CW
systemctl daemon-reload
systemctl enable node_exporter amazon-cloudwatch-agent
systemctl start  node_exporter amazon-cloudwatch-agent

echo ""
echo "============================================"
echo " Verificação Final"
echo "============================================"
echo ""
echo "Secret Manager:"
aws secretsmanager describe-secret \
  --secret-id "$SECRET_NAME" --region "$AWS_REGION" \
  --query '{Name:Name,LastChanged:LastChangedDate}' --output table 2>/dev/null

echo ""
echo "Serviços:"
for svc in nginx node_exporter amazon-cloudwatch-agent; do
  STATUS=$(systemctl is-active $svc 2>/dev/null)
  echo "  $([[ "$STATUS" == "active" ]] && echo ✓ || echo ✗) $svc: $STATUS"
done
curl -s http://localhost/health; echo ""
for path in "" "index.html" "style.css" "app.js" "config.js"; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost/${path}")
  echo "  $([[ "$CODE" == "200" ]] && echo ✓ || echo ✗) HTTP $CODE — /${path}"
done
echo ""
echo "Setup CONCLUÍDO: $(date)"
MY_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null)
echo "IP privado: $MY_IP"
echo "Secret: $SECRET_NAME (região: $AWS_REGION)"
echo ""
echo "Para atualizar variáveis: execute novamente este script"
echo "PENDÊNCIAS:"
echo "  1. Registrar EC2 no Target Group ALB (porta 80)"
echo "  2. ALB Rules: /api* (1), /grafana* (2), /prometheus* (3), /* (4)"
