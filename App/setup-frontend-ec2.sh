#!/bin/bash
# =============================================================================
# setup-frontend-ec2.sh — Configuração do EC2 Frontend (Nginx)
# TechStock | Execução interativa linha a linha via SSM Session Manager ou SSH
#
# COMO USAR:
#   1. Conecte na instância via Session Manager ou SSH
#   2. Execute: sudo bash setup-frontend-ec2.sh
#   OU copie e cole cada seção no terminal manualmente
#
# PRÉ-REQUISITO: preencha as variáveis da SEÇÃO 1 antes de rodar
# =============================================================================

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 1 — VARIÁVEIS (edite aqui antes de executar)
# ══════════════════════════════════════════════════════════════════════════════

ALB_DNS="COLE_O_DNS_DO_ALB_AQUI"
# Exemplo: techstock-alb-123456789.us-east-1.elb.amazonaws.com
# Sem http:// — o script adiciona automaticamente

S3_BUCKET=""
# Se os arquivos frontend estão em um bucket S3, informe o nome
# Exemplo: techstock-frontend-123456789
# Se vazio, o script solicita upload manual

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 2 — Valida variáveis
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "============================================"
echo " TechStock — Setup Frontend EC2 (Nginx)"
echo " $(date)"
echo "============================================"
echo ""

if [[ "$ALB_DNS" == "COLE_O_DNS_DO_ALB_AQUI" ]]; then
  echo "ERRO: edite ALB_DNS na SEÇÃO 1 antes de continuar."
  exit 1
fi

# Remove http:// se o usuário colou com prefixo
ALB_DNS="${ALB_DNS#http://}"
ALB_DNS="${ALB_DNS#https://}"
ALB_DNS="${ALB_DNS%/}"

echo "Configurações:"
echo "  ALB_DNS   = $ALB_DNS"
echo "  API URL   = http://$ALB_DNS"
echo "  S3_BUCKET = ${S3_BUCKET:-'(não definido — upload manual)'}"
echo ""
read -p "Confirma? (s/N): " CONFIRM
[[ "$CONFIRM" =~ ^[Ss]$ ]] || { echo "Cancelado."; exit 0; }

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 3 — Instalação do Nginx
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "--- [1/6] Atualizando sistema e instalando Nginx ---"
dnf update -y
dnf install -y nginx wget curl
echo "Nginx versão: $(nginx -v 2>&1)"

# Remove o server block default do nginx.conf do Amazon Linux 2023
# AL2023 embute um server {} em /etc/nginx/nginx.conf que conflita com
# nosso conf.d/techstock.conf (dois listen 80 default_server = erro)
# Substituímos o nginx.conf por uma versão mínima sem server block embutido
sudo tee /etc/nginx/nginx.conf > /dev/null << 'NGINXMAIN'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log notice;
pid /run/nginx.pid;
include /usr/share/nginx/modules/*.conf;

events {
    worker_connections 1024;
}

http {
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';
    access_log /var/log/nginx/access.log main;
    sendfile on;
    tcp_nopush on;
    keepalive_timeout 65;
    types_hash_max_size 4096;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    include /etc/nginx/conf.d/*.conf;
}
NGINXMAIN
echo "nginx.conf simplificado (sem server block embutido): OK"


# ── IMPORTANTE: ao fazer upload para S3, use Cache-Control no config.js ────────
# aws s3 cp config.js s3://$S3_BUCKET/config.js \
#   --cache-control "no-store, no-cache" \
#   --content-type "application/javascript"
# Sem isso, o browser cacheia por 24h e ignora atualizações do DNS do ALB
# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 4 — Diretório do frontend
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "--- [2/6] Criando diretório do frontend ---"
mkdir -p /usr/share/nginx/html/techstock
ls -la /usr/share/nginx/html/

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 5 — Copia arquivos do frontend
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "--- [3/6] Copiando arquivos do frontend ---"

if [[ -n "$S3_BUCKET" ]]; then
  echo "Copiando do S3: s3://$S3_BUCKET/"
  aws s3 sync s3://$S3_BUCKET/ /usr/share/nginx/html/techstock/
  # config.js sem cache (URL do ALB pode mudar)
  aws s3 cp s3://$S3_BUCKET/config.js /usr/share/nginx/html/techstock/config.js \
    --cache-control "no-store, no-cache" 2>/dev/null || true
  chown -R nginx:nginx /usr/share/nginx/html/techstock/
  chmod -R 755 /usr/share/nginx/html/techstock/
  echo "Arquivos copiados:"
  ls -la /usr/share/nginx/html/techstock/
else
  echo "S3_BUCKET não definido."
  echo ""
  echo "Opções para copiar os arquivos:"
  echo "  a) scp da sua máquina local:"
  echo "       scp -i vockey.pem frontend/* ec2-user@IP_PUBLICO:/tmp/"
  echo "       sudo cp /tmp/{index.html,style.css,app.js,config.js} /usr/share/nginx/html/techstock/"
  echo ""
  echo "  b) Wget de URL pública (se disponível):"
  echo "       wget -P /usr/share/nginx/html/techstock/ http://URL/index.html"
  echo "       wget -P /usr/share/nginx/html/techstock/ http://URL/style.css"
  echo "       wget -P /usr/share/nginx/html/techstock/ http://URL/app.js"
  echo "       wget -P /usr/share/nginx/html/techstock/ http://URL/config.js"
  echo ""
  echo "  c) Cole o conteúdo manualmente:"
  echo "       cat > /usr/share/nginx/html/techstock/index.html"
  echo "       (cole o conteúdo e pressione Ctrl+D)"
  echo ""
  echo "Após copiar os arquivos, pressione Enter para continuar..."
  read -p ""
fi

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 6 — Gera config.js com URL do ALB
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "--- [4/6] Configurando config.js com URL do ALB ---"

cat > /usr/share/nginx/html/techstock/config.js << CFG
// config.js — gerado automaticamente pelo setup-frontend-ec2.sh
window.TECHSTOCK_CONFIG = {
  apiUrl: 'http://${ALB_DNS}'
};
CFG

echo "config.js gerado:"
cat /usr/share/nginx/html/techstock/config.js

# Verifica se os arquivos essenciais existem
echo ""
echo "Verificando arquivos:"
for f in index.html style.css app.js config.js; do
  if [[ -f /usr/share/nginx/html/techstock/$f ]]; then
    echo "  ✓ $f"
  else
    echo "  ✗ $f  ← FALTANDO"
  fi
done

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 7 — Configuração do Nginx
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "--- [5/6] Configurando Nginx ---"
cat > /etc/nginx/conf.d/techstock.conf << 'NGINX'
server {
    listen 80 default_server;
    server_name _;

    root  /usr/share/nginx/html/techstock;
    index index.html;

    # config.js: SEM cache — contém a URL do ALB que pode mudar
    # Se o ALB DNS mudar e o browser tiver cacheado, o frontend ficará quebrado
    location = /config.js {
        add_header Cache-Control "no-store, no-cache, must-revalidate";
        add_header Pragma "no-cache";
        expires -1;
    }

    # Arquivos estáticos com SPA fallback
    location / {
        try_files $uri $uri/ /index.html;
        add_header Cache-Control "no-cache";
        add_header X-Frame-Options "SAMEORIGIN";
    }

    # Cache para CSS e JS (exceto config.js, tratado acima)
    location ~* \.(css|js)$ {
        expires 1h;
        add_header Cache-Control "public, max-age=3600";
    }

    # Health check do ALB — responde antes de verificar os arquivos
    location = /health {
        default_type application/json;
        return 200 '{"ok":true,"service":"frontend-nginx"}';
        add_header Content-Type application/json;
    }

    # Logs
    access_log /var/log/nginx/techstock-access.log;
    error_log  /var/log/nginx/techstock-error.log;
}
NGINX

# Permissões: nginx (usuário nginx) precisa ler os arquivos
chown -R nginx:nginx /usr/share/nginx/html/techstock/
chmod -R 755 /usr/share/nginx/html/techstock/
echo "Permissões: OK"

# Valida config do Nginx
nginx -t && echo "Configuração Nginx: OK" || { echo "ERRO na configuração Nginx!"; exit 1; }

systemctl enable nginx
systemctl restart nginx   # restart (não start) garante que o novo conf seja carregado

sleep 2
echo "Nginx status: $(systemctl is-active nginx)"

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 8 — Node Exporter
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "--- [6/6] Instalando Node Exporter ---"
NODE_EXPORTER_VERSION="1.7.0"
wget -q \
  "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz" \
  -O /tmp/node_exporter.tar.gz

tar xzf /tmp/node_exporter.tar.gz -C /tmp/
cp /tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter /usr/local/bin/
chmod +x /usr/local/bin/node_exporter

cat > /etc/systemd/system/node_exporter.service << 'NE'
[Unit]
Description=Node Exporter — métricas do sistema
After=network.target

[Service]
Type=simple
User=nobody
ExecStart=/usr/local/bin/node_exporter
Restart=on-failure

[Install]
WantedBy=multi-user.target
NE

systemctl daemon-reload
systemctl enable node_exporter
systemctl start node_exporter

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 9 — CloudWatch Agent
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "--- Instalando CloudWatch Agent ---"
dnf install -y amazon-cloudwatch-agent

cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CW'
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/nginx/techstock-access.log",
            "log_group_name": "/techstock/nginx-access",
            "log_stream_name": "{instance_id}"
          },
          {
            "file_path": "/var/log/nginx/techstock-error.log",
            "log_group_name": "/techstock/nginx-error",
            "log_stream_name": "{instance_id}"
          }
        ]
      }
    }
  },
  "metrics": {
    "namespace": "TechStock/Frontend",
    "metrics_collected": {
      "cpu":  { "measurement": ["cpu_usage_active"],  "metrics_collection_interval": 60 },
      "mem":  { "measurement": ["mem_used_percent"],   "metrics_collection_interval": 60 }
    }
  }
}
CW

systemctl enable amazon-cloudwatch-agent
systemctl start amazon-cloudwatch-agent

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 10 — Verificação final
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "============================================"
echo " Verificação Final"
echo "============================================"

echo ""
echo "Serviços:"
for svc in nginx node_exporter amazon-cloudwatch-agent; do
  STATUS=$(systemctl is-active $svc 2>/dev/null)
  ICON=$( [[ "$STATUS" == "active" ]] && echo "✓" || echo "✗" )
  echo "  $ICON $svc: $STATUS"
done

echo ""
echo "Teste Nginx (local):"
curl -s http://localhost/health
echo ""
for f in "" "index.html" "style.css" "app.js" "config.js"; do
  URL="http://localhost/${f}"
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "$URL")
  ICON=$([[ "$CODE" == "200" ]] && echo "✓" || echo "✗")
  printf "  %s HTTP %s — %s\n" "$ICON" "$CODE" "${f:-/}"
done

echo ""
echo "Verificação de permissões:"
ls -la /usr/share/nginx/html/techstock/

echo ""
echo "Logs de erro Nginx (últimas 5 linhas):"
tail -5 /var/log/nginx/techstock-error.log 2>/dev/null || echo "  (sem erros)"

echo ""
echo "Teste node_exporter:"
curl -s http://localhost:9100/metrics | grep "^node_load1" | head -1

echo ""
echo "============================================"
echo " Setup Frontend CONCLUÍDO: $(date)"
echo "============================================"
echo ""
echo "Próximos passos:"
echo "  1. Registre esta instância no Target Group do ALB (porta 80)"
echo "  2. Para atualizar a URL da API, edite o config.js:"
echo "       sudo nano /usr/share/nginx/html/techstock/config.js"
echo "  3. Para recarregar arquivos do S3 no futuro:"
echo "       sudo aws s3 sync s3://$S3_BUCKET/ /usr/share/nginx/html/techstock/"
echo ""
