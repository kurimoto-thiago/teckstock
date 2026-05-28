#!/bin/bash
# =============================================================================
# setup-backend.sh — v4 FULL SECRETS MANAGER
# Todas as variáveis (fixas e dinâmicas) armazenadas no Secrets Manager.
# O script confronta os valores existentes no secret e oferece atualização
# antes de prosseguir com a instalação.
# =============================================================================

# ══════════════════════════════════════════════════════════════════════════════
# ETAPA 0 — Região e nome do secret (mínimo para acessar o Secrets Manager)
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "============================================"
echo " TechStock — Setup Backend v4"
echo " $(date)"
echo "============================================"
echo ""
echo "Para começar, informe a região e o nome do secret."
echo "Todos os demais dados serão lidos/gravados no Secrets Manager."
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
echo "  Padrão: techstock/backend  (Enter para usar o padrão)"
read -p "  → " SECRET_NAME
SECRET_NAME="${SECRET_NAME// /}"
[[ -z "$SECRET_NAME" ]] && SECRET_NAME="techstock/backend"
echo "  ✓ SECRET_NAME: $SECRET_NAME"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# ETAPA 1 — Lê secret existente (se houver)
# ══════════════════════════════════════════════════════════════════════════════
echo "Buscando secret '$SECRET_NAME' na região '$AWS_REGION'..."

SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_NAME" \
  --region "$AWS_REGION" \
  --query SecretString \
  --output text 2>/dev/null)

SECRET_EXISTS=$?

# Função para extrair campo do JSON
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

  # Carrega todos os valores do secret
  DB_HOST=$(get_field DB_HOST)
  DB_PORT=$(get_field DB_PORT)
  DB_NAME=$(get_field DB_NAME)
  DB_USER=$(get_field DB_USER)
  DB_PASSWORD=$(get_field DB_PASSWORD)
  DB_POOL_MIN=$(get_field DB_POOL_MIN)
  DB_POOL_MAX=$(get_field DB_POOL_MAX)
  DB_SSL=$(get_field DB_SSL)
  PORT=$(get_field PORT)
  NODE_ENV=$(get_field NODE_ENV)
  CORS_ORIGIN=$(get_field CORS_ORIGIN)
  APP_DIR=$(get_field APP_DIR)
  NODE_EXPORTER_VERSION=$(get_field NODE_EXPORTER_VERSION)
  GITHUB_RAW=$(get_field GITHUB_RAW)
  GITHUB_SUBDIR=$(get_field GITHUB_SUBDIR)
else
  echo "  ⚠ Secret não encontrado — será criado com novos valores."
  EXISTING=false

  # Defaults para novo secret
  DB_PORT="5432"
  DB_NAME="techstock"
  DB_USER="techstock_user"
  DB_POOL_MIN="1"
  DB_POOL_MAX="5"
  DB_SSL="true"
  PORT="3000"
  NODE_ENV="production"
  APP_DIR="/opt/techstock"
  NODE_EXPORTER_VERSION="1.7.0"
fi

echo ""

# ══════════════════════════════════════════════════════════════════════════════
# ETAPA 2 — Apresenta valores e pergunta se deseja atualizar
# ══════════════════════════════════════════════════════════════════════════════
echo "============================================"
echo " Valores atuais do secret"
echo "============================================"
echo "  DB_HOST              = ${DB_HOST:-'(não definido)'}"
echo "  DB_PORT              = ${DB_PORT}"
echo "  DB_NAME              = ${DB_NAME}"
echo "  DB_USER              = ${DB_USER}"
echo "  DB_PASSWORD          = ${DB_PASSWORD:+'(definida)'}${DB_PASSWORD:-'(não definida)'}"
echo "  DB_SSL               = ${DB_SSL}"
echo "  DB_POOL_MIN          = ${DB_POOL_MIN}"
echo "  DB_POOL_MAX          = ${DB_POOL_MAX}"
echo "  PORT                 = ${PORT}"
echo "  NODE_ENV             = ${NODE_ENV}"
echo "  CORS_ORIGIN          = ${CORS_ORIGIN:-'(não definido)'}"
echo "  APP_DIR              = ${APP_DIR}"
echo "  NODE_EXPORTER_VERSION= ${NODE_EXPORTER_VERSION}"
echo "  GITHUB_RAW           = ${GITHUB_RAW:-'(não definido)'}"
echo "  GITHUB_SUBDIR        = ${GITHUB_SUBDIR:-'(raiz)'}"
echo "============================================"
echo ""

# Função auxiliar: prompt com valor atual como padrão
prompt_field() {
  local label="$1"
  local current="$2"
  local secret="$3"   # true = oculta no echo
  local result

  if [[ "$secret" == "true" ]]; then
    echo "  $label (Enter para manter):"
    read -s -p "    → " result; echo ""
  else
    echo "  $label (Enter para manter: ${current:-'(vazio)'}):"
    read -p "    → " result
  fi
  echo "${result:-$current}"
}

if [[ "$EXISTING" == "true" ]]; then
  echo "Deseja atualizar algum valor? (s/N)"
  read -p "  → " UPDATE_CHOICE
  UPDATE_CHOICE="${UPDATE_CHOICE// /}"
else
  UPDATE_CHOICE="s"
  echo "Preenchimento dos valores obrigatórios:"
fi

echo ""

if [[ "$UPDATE_CHOICE" =~ ^[Ss]$ ]]; then
  echo "── Banco de Dados ──────────────────────────"
  DB_HOST=$(prompt_field "Endpoint do RDS (sem porta)" "$DB_HOST")
  DB_PASSWORD=$(prompt_field "Senha do banco (DB_PASSWORD)" "$DB_PASSWORD" "true")
  DB_PORT=$(prompt_field "Porta (DB_PORT)" "$DB_PORT")
  DB_NAME=$(prompt_field "Nome do banco (DB_NAME)" "$DB_NAME")
  DB_USER=$(prompt_field "Usuário do banco (DB_USER)" "$DB_USER")
  DB_SSL=$(prompt_field "SSL (DB_SSL: true/false)" "$DB_SSL")
  DB_POOL_MIN=$(prompt_field "Pool mínimo (DB_POOL_MIN)" "$DB_POOL_MIN")
  DB_POOL_MAX=$(prompt_field "Pool máximo (DB_POOL_MAX)" "$DB_POOL_MAX")
  echo ""
  echo "── Aplicação ───────────────────────────────"
  PORT=$(prompt_field "Porta da API (PORT)" "$PORT")
  NODE_ENV=$(prompt_field "Ambiente (NODE_ENV)" "$NODE_ENV")
  CORS_ORIGIN=$(prompt_field "CORS_ORIGIN (http://ALB_DNS)" "$CORS_ORIGIN")
  APP_DIR=$(prompt_field "Diretório da aplicação (APP_DIR)" "$APP_DIR")
  echo ""
  echo "── Infraestrutura ──────────────────────────"
  NODE_EXPORTER_VERSION=$(prompt_field "Versão Node Exporter" "$NODE_EXPORTER_VERSION")
  echo ""
  echo "── GitHub ──────────────────────────────────"
  GITHUB_RAW=$(prompt_field "URL base do repo (raw GitHub)" "$GITHUB_RAW")
  GITHUB_SUBDIR=$(prompt_field "Subdiretório do backend (vazio = raiz)" "$GITHUB_SUBDIR")
  echo ""
fi

# Monta GITHUB_BASE
GITHUB_RAW="${GITHUB_RAW%/}"
GITHUB_SUBDIR="${GITHUB_SUBDIR%/}"
[[ -n "$GITHUB_SUBDIR" ]] && GITHUB_BASE="${GITHUB_RAW}/${GITHUB_SUBDIR}" || GITHUB_BASE="$GITHUB_RAW"

# ══════════════════════════════════════════════════════════════════════════════
# ETAPA 3 — Valida campos obrigatórios
# ══════════════════════════════════════════════════════════════════════════════
ERRORS=0
[[ -z "$DB_HOST" ]]      && echo "  ✗ DB_HOST é obrigatório"      && ERRORS=$((ERRORS+1))
[[ -z "$DB_PASSWORD" ]]  && echo "  ✗ DB_PASSWORD é obrigatório"  && ERRORS=$((ERRORS+1))
[[ -z "$CORS_ORIGIN" ]]  && echo "  ✗ CORS_ORIGIN é obrigatório"  && ERRORS=$((ERRORS+1))
[[ -z "$GITHUB_RAW" ]]   && echo "  ⚠ GITHUB_RAW não definido — upload manual necessário"

if [[ $ERRORS -gt 0 ]]; then
  echo ""
  echo "  ✗ Corrija os campos obrigatórios e execute novamente."
  exit 1
fi

# ══════════════════════════════════════════════════════════════════════════════
# ETAPA 4 — Confirmação final
# ══════════════════════════════════════════════════════════════════════════════
echo "============================================"
echo " Resumo final"
echo "============================================"
echo "  SECRET_NAME          = $SECRET_NAME"
echo "  AWS_REGION           = $AWS_REGION"
echo "  DB_HOST              = $DB_HOST"
echo "  DB_NAME              = $DB_NAME"
echo "  DB_USER              = $DB_USER"
echo "  DB_PASSWORD          = (definida)"
echo "  DB_SSL               = $DB_SSL"
echo "  PORT                 = $PORT"
echo "  NODE_ENV             = $NODE_ENV"
echo "  CORS_ORIGIN          = $CORS_ORIGIN"
echo "  APP_DIR              = $APP_DIR"
echo "  NODE_EXPORTER_VERSION= $NODE_EXPORTER_VERSION"
echo "  GITHUB_BASE          = ${GITHUB_BASE:-'(upload manual)'}"
echo "============================================"
echo ""
read -p "Confirma e salva no Secrets Manager? (s/N): " CONFIRM
[[ "$CONFIRM" =~ ^[Ss]$ ]] || { echo "Cancelado."; exit 0; }

# ══════════════════════════════════════════════════════════════════════════════
# ETAPA 5 — Salva/atualiza secret
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "Salvando secret no Secrets Manager..."

SECRET_JSON=$(python3 -c "
import json
print(json.dumps({
  'DB_HOST':               '${DB_HOST}',
  'DB_PORT':               '${DB_PORT}',
  'DB_NAME':               '${DB_NAME}',
  'DB_USER':               '${DB_USER}',
  'DB_PASSWORD':           '${DB_PASSWORD}',
  'DB_POOL_MIN':           '${DB_POOL_MIN}',
  'DB_POOL_MAX':           '${DB_POOL_MAX}',
  'DB_SSL':                '${DB_SSL}',
  'PORT':                  '${PORT}',
  'NODE_ENV':              '${NODE_ENV}',
  'CORS_ORIGIN':           '${CORS_ORIGIN}',
  'AWS_REGION':            '${AWS_REGION}',
  'APP_DIR':               '${APP_DIR}',
  'NODE_EXPORTER_VERSION': '${NODE_EXPORTER_VERSION}',
  'GITHUB_RAW':            '${GITHUB_RAW}',
  'GITHUB_SUBDIR':         '${GITHUB_SUBDIR}',
  'TECHSTOCK_SECRET_NAME': '${SECRET_NAME}'
}))
")

if [[ "$EXISTING" == "true" ]]; then
  aws secretsmanager put-secret-value \
    --secret-id "$SECRET_NAME" \
    --secret-string "$SECRET_JSON" \
    --region "$AWS_REGION" \
    && echo "  ✓ Secret atualizado: $SECRET_NAME" \
    || { echo "  ✗ Erro ao atualizar secret"; exit 1; }
else
  aws secretsmanager create-secret \
    --name "$SECRET_NAME" \
    --description "TechStock Backend — todas as variáveis de configuração" \
    --secret-string "$SECRET_JSON" \
    --region "$AWS_REGION" \
    && echo "  ✓ Secret criado: $SECRET_NAME" \
    || { echo "  ✗ Erro ao criar secret"; exit 1; }
fi

# ══════════════════════════════════════════════════════════════════════════════
# ETAPA 6 — Instalação
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [1/8] Atualizando sistema ---"
dnf update -y
dnf install -y nodejs npm postgresql15 git wget
echo "Node.js: $(node --version) | npm: $(npm --version)"

echo ""
echo "--- [2/8] Criando usuário e diretório ---"
useradd -r -m -d $APP_DIR -s /bin/bash techstock 2>/dev/null \
  && echo "Usuário techstock: criado" || echo "Usuário techstock: já existe (ok)"
mkdir -p $APP_DIR/public

echo ""
echo "--- [3/8] Baixando arquivos do GitHub ---"
if [[ -n "$GITHUB_BASE" ]]; then
  mkdir -p $APP_DIR
  for f in server.js package.json schema.sql; do
    echo "  baixando $f..."
    wget -q -O $APP_DIR/$f "$GITHUB_BASE/$f" && echo "  ✓ $f" || echo "  ✗ $f"
  done
  wget -q -O $APP_DIR/package-lock.json "$GITHUB_BASE/package-lock.json" 2>/dev/null || true
  ls -la $APP_DIR/
else
  echo "Copie os arquivos para $APP_DIR/ e pressione Enter..."
  read -p ""
fi

for f in server.js package.json; do
  [[ ! -f $APP_DIR/$f ]] && { echo "ERRO: $APP_DIR/$f não encontrado."; exit 1; }
done

echo ""
echo "--- [4/8] Instalando dependências Node.js ---"
cd $APP_DIR && npm install --omit=dev
echo "Pacotes instalados: $(ls node_modules | wc -l)"

echo ""
echo "--- [5/8] Criando .env mínimo (apenas referência ao secret) ---"
cat > $APP_DIR/.env << ENV
# .env — TechStock Backend
# Apenas referência ao Secrets Manager. Variáveis sensíveis NÃO ficam aqui.
TECHSTOCK_SECRET_NAME=${SECRET_NAME}
AWS_REGION=${AWS_REGION}
ENV

chown techstock:techstock $APP_DIR/.env
chmod 640 $APP_DIR/.env
chown -R techstock:techstock $APP_DIR
chmod 755 $APP_DIR
echo "  ✓ .env criado (sem dados sensíveis)"

echo ""
echo "--- [6/8] Inicializando schema do banco ---"
if [[ -f $APP_DIR/schema.sql ]]; then
  PGPASSWORD="$DB_PASSWORD" psql \
    -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" \
    --set=sslmode=require -f $APP_DIR/schema.sql \
    && echo "Schema: OK" || echo "AVISO: erro no schema"
else
  echo "schema.sql não encontrado — execute manualmente se necessário."
fi

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
echo "techstock: $(systemctl is-active techstock)"

echo ""
echo "--- [8/8] Node Exporter + CloudWatch Agent ---"
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
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << CW
{
  "logs": { "logs_collected": { "systemd": { "collect_list": [
    { "log_group_name": "/techstock/app", "log_stream_name": "{instance_id}", "log_system_journal_id": "techstock" }
  ]}}},
  "metrics": { "namespace": "TechStock/EC2", "metrics_collected": {
    "cpu":  { "measurement": ["cpu_usage_active"],  "metrics_collection_interval": 60 },
    "mem":  { "measurement": ["mem_used_percent"],   "metrics_collection_interval": 60 },
    "disk": { "measurement": ["disk_used_percent"],  "resources": ["/"], "metrics_collection_interval": 60 }
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
for svc in techstock node_exporter amazon-cloudwatch-agent; do
  STATUS=$(systemctl is-active $svc 2>/dev/null)
  echo "  $([[ "$STATUS" == "active" ]] && echo ✓ || echo ✗) $svc: $STATUS"
done

echo ""
echo "Teste da API:"
sleep 2
curl -s http://localhost:3000/api/health | python3 -m json.tool 2>/dev/null \
  || curl -s http://localhost:3000/api/health

echo ""
echo "Node Exporter:"
curl -s http://localhost:9100/metrics | grep "^node_load1" | head -1

echo ""
echo "============================================"
echo " Setup CONCLUÍDO: $(date)"
echo "============================================"
echo ""
MY_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null)
echo "IP privado: $MY_IP"
echo "Secret: $SECRET_NAME (região: $AWS_REGION)"
echo ""
echo "Para atualizar variáveis sem redeploy:"
echo "  1. Execute novamente este script (mostrará valores atuais para edição)"
echo "  2. Ou: Console AWS → Secrets Manager → $SECRET_NAME → Edit"
echo "  3. sudo systemctl restart techstock"
echo ""
echo "PENDÊNCIAS:"
echo "  1. Adicionar EC2 ao Target Group ALB (porta $PORT)"
echo "  2. SG do Backend: liberar $PORT e 9100 para SG do EC2 Monitoring"
