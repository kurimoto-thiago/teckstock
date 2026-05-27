#!/bin/bash
# =============================================================================
# setup-monitoring.sh — Configuração do EC2 Monitoring
# TechStock | Prometheus + Grafana + Nginx + Node Exporter + CloudWatch
# Execução interativa via SSM Session Manager
#
# CORREÇÕES APLICADAS (vs versão anterior):
#   - Nginx instalado e configurado como proxy reverso (ALB → Grafana/Prometheus)
#   - prometheus.yml: metrics_path corrigido no job self-monitoring
#   - grafana.ini: cookie_secure, cookie_samesite, allow_embedding adicionados
#   - Datasource: UID PBFA97CFB590B2093 + URL via ALB (SSRF protection Grafana 13)
#   - grafana-cli reset aponta para banco correto (/var/lib/grafana)
#   - API path corrigido para /grafana/api/* (serve_from_sub_path=true)
#   - Verificação final usa URL correta do Prometheus (/prometheus/api/v1/targets)
#   - nginx adicionado na verificação de serviços
# =============================================================================

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 1 — VARIÁVEIS FIXAS (não alterar)
# ══════════════════════════════════════════════════════════════════════════════

GRAFANA_PASSWORD="TechStock@2024"
PROMETHEUS_VERSION="2.51.2"
NODE_EXPORTER_VERSION="1.7.0"
DATASOURCE_UID="PBFA97CFB590B2093"

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 2 — ENTRADA INTERATIVA DE DADOS
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "============================================"
echo " TechStock — Setup Monitoring"
echo " $(date)"
echo "============================================"
echo ""

# ALB DNS — obrigatório
while true; do
  echo "DNS do ALB (sem http://):"
  echo "  Exemplo: techstock-lb-105375070.us-east-1.elb.amazonaws.com"
  echo "  Console AWS → EC2 → Load Balancers → DNS name"
  read -p "  → " ALB_DNS
  ALB_DNS="${ALB_DNS// /}"   # remove espaços acidentais
  [[ -n "$ALB_DNS" ]] && break
  echo "  ✗ Obrigatório. Tente novamente."
  echo ""
done
echo "  ✓ ALB DNS: $ALB_DNS"
echo ""

# IP do Backend — opcional
echo "IP privado do EC2 Backend (Enter para pular e configurar depois):"
echo "  Exemplo: 10.0.10.45"
echo "  Console AWS → EC2 → Instances → techstock-backend → Private IPv4"
read -p "  → " BACKEND_PRIVATE_IP
BACKEND_PRIVATE_IP="${BACKEND_PRIVATE_IP// /}"
if [[ -n "$BACKEND_PRIVATE_IP" ]]; then
  echo "  ✓ Backend IP: $BACKEND_PRIVATE_IP"
else
  echo "  ⚠ Pulado — configure depois em /etc/prometheus/prometheus.yml"
fi
echo ""

# Senha do Grafana
echo "Senha do Grafana admin (Enter para usar padrão: TechStock@2024):"
read -p "  → " INPUT_PASS
[[ -n "$INPUT_PASS" ]] && GRAFANA_PASSWORD="$INPUT_PASS"
echo "  ✓ Senha: $GRAFANA_PASSWORD"
echo ""

# Confirmação final
echo "--------------------------------------------"
echo " Resumo da configuração:"
echo "   ALB DNS    = $ALB_DNS"
echo "   Backend IP = ${BACKEND_PRIVATE_IP:-'(configurar depois)'}"
echo "   Grafana    = admin / $GRAFANA_PASSWORD"
echo "   Prometheus = v$PROMETHEUS_VERSION"
echo "   NodeExp    = v$NODE_EXPORTER_VERSION"
echo "--------------------------------------------"
echo ""
read -p "Confirma e inicia a instalação? (s/N): " CONFIRM
[[ "$CONFIRM" =~ ^[Ss]$ ]] || { echo "Cancelado."; exit 0; }

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 3 — Sistema
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "--- [1/6] Atualizando sistema e dependências ---"
dnf update -y
dnf install -y wget curl tar python3 nginx

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 4 — Node Exporter
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "--- [2/6] Instalando Node Exporter v${NODE_EXPORTER_VERSION} ---"
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
RestartSec=5
[Install]
WantedBy=multi-user.target
NE

systemctl daemon-reload
systemctl enable node_exporter
systemctl start node_exporter
sleep 2
echo "node_exporter: $(systemctl is-active node_exporter)"
curl -s http://localhost:9100/metrics | grep '^node_load1' | head -1

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 5 — Prometheus
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "--- [3/6] Instalando Prometheus v${PROMETHEUS_VERSION} ---"

useradd --no-create-home --shell /bin/false prometheus 2>/dev/null || true
mkdir -p /etc/prometheus /var/lib/prometheus
chown prometheus:prometheus /etc/prometheus /var/lib/prometheus

wget -q \
  "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz" \
  -O /tmp/prometheus.tar.gz
tar xzf /tmp/prometheus.tar.gz -C /tmp/
cp /tmp/prometheus-${PROMETHEUS_VERSION}.linux-amd64/prometheus  /usr/local/bin/
cp /tmp/prometheus-${PROMETHEUS_VERSION}.linux-amd64/promtool    /usr/local/bin/
chmod +x /usr/local/bin/prometheus /usr/local/bin/promtool
echo "Prometheus: $(/usr/local/bin/prometheus --version 2>&1 | head -1)"

# Gera prometheus.yml com IP real (se fornecido)
if [[ -n "$BACKEND_PRIVATE_IP" ]]; then
  BACKEND_JOBS="
  - job_name: 'techstock-app'
    static_configs:
      - targets: ['${BACKEND_PRIVATE_IP}:3000']
    metrics_path: /metrics
    scrape_interval: 15s
    relabel_configs:
      - source_labels: [__address__]
        target_label: instance
        replacement: backend-app

  - job_name: 'node-exporter-backend'
    static_configs:
      - targets: ['${BACKEND_PRIVATE_IP}:9100']
    relabel_configs:
      - source_labels: [__address__]
        target_label: instance
        replacement: backend"
else
  BACKEND_JOBS="
  # CONFIGURE DEPOIS — edite este arquivo com o IP do backend:
  #   sudo nano /etc/prometheus/prometheus.yml
  #   sudo promtool check config /etc/prometheus/prometheus.yml
  #   sudo systemctl restart prometheus
  #
  # - job_name: 'techstock-app'
  #   static_configs:
  #     - targets: ['10.0.10.X:3000']
  #   metrics_path: /metrics
  #
  # - job_name: 'node-exporter-backend'
  #   static_configs:
  #     - targets: ['10.0.10.X:9100']"
fi

# CORREÇÃO: metrics_path obrigatório no job prometheus quando --web.route-prefix=/prometheus
# Sem isso o self-monitoring fica DOWN com 404
cat > /etc/prometheus/prometheus.yml << PROM
global:
  scrape_interval:     15s
  evaluation_interval: 15s
  external_labels:
    environment: learnerlab
    app:         techstock

scrape_configs:
  - job_name: 'prometheus'
    metrics_path: /prometheus/metrics
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'node-exporter-monitoring'
    static_configs:
      - targets: ['localhost:9100']
    relabel_configs:
      - source_labels: [__address__]
        target_label: instance
        replacement: monitoring
${BACKEND_JOBS}
PROM

chown prometheus:prometheus /etc/prometheus/prometheus.yml
/usr/local/bin/promtool check config /etc/prometheus/prometheus.yml \
  && echo "prometheus.yml: OK" || echo "ERRO no prometheus.yml!"

# Serviço Prometheus com subpath /prometheus para acesso via ALB
cat > /etc/systemd/system/prometheus.service << 'SVC'
[Unit]
Description=Prometheus
After=network.target
[Service]
Type=simple
User=prometheus
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --storage.tsdb.retention.time=15d \
  --web.listen-address=0.0.0.0:9090 \
  --web.external-url=/prometheus \
  --web.route-prefix=/prometheus
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable prometheus
systemctl start prometheus
sleep 3
echo "prometheus: $(systemctl is-active prometheus)"

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 6 — Nginx (proxy reverso ALB → Grafana/Prometheus)
#
# OBRIGATÓRIO: O ALB usa um único Target Group por porta.
# O Nginx escuta na porta 80 e roteia /grafana/ e /prometheus/ internamente.
# Sem Nginx, o ALB não consegue rotear para dois serviços pelo mesmo TG.
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "--- [4/6] Configurando Nginx ---"

# Substitui nginx.conf padrão para evitar conflito com server block default do AL2023
cat > /etc/nginx/nginx.conf << 'NGXMAIN'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;
include /usr/share/nginx/modules/*.conf;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/conf.d/*.conf;
}
NGXMAIN

# Configura proxy para Grafana e Prometheus
cat > /etc/nginx/conf.d/techstock-monitoring.conf << 'NGXCONF'
server {
    listen 80;

    # Grafana — proxy para porta interna 3000
    location /grafana/ {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    # Prometheus — proxy para porta interna 9090
    location /prometheus/ {
        proxy_pass http://127.0.0.1:9090;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
NGXCONF

nginx -t && echo "nginx.conf: OK" || echo "ERRO no nginx.conf!"
systemctl enable nginx
systemctl start nginx
sleep 2
echo "nginx: $(systemctl is-active nginx)"
curl -s http://localhost/grafana/api/health | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print('  Grafana via Nginx:', d.get('database','?'))" \
  2>/dev/null || echo "  (Grafana ainda inicializando)"

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 7 — Grafana
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "--- [5/6] Instalando e configurando Grafana ---"

cat > /etc/yum.repos.d/grafana.repo << 'REPO'
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
REPO

dnf install -y grafana
echo "Grafana: $(grafana-server --version 2>/dev/null | head -1)"

# grafana.ini — configuração completa para sub-path via ALB
# ATENÇÃO: nunca duplique seções neste arquivo — causa loop de login
cat > /etc/grafana/grafana.ini << GINI
[server]
http_addr = 0.0.0.0
http_port = 3000
# domain: DNS do ALB sem protocolo e sem path
domain    = ${ALB_DNS}
# root_url: URL completa com /grafana/ no final (trailing slash obrigatória)
root_url  = %(protocol)s://%(domain)s/grafana/
# serve_from_sub_path: obrigatório para acesso via sub-path
serve_from_sub_path = true

[security]
admin_user     = admin
admin_password = ${GRAFANA_PASSWORD}
secret_key     = techstock-$(date +%s)
# allow_embedding: permite iframes nos painéis
allow_embedding = true
# cookie settings: necessários para evitar loop de login sem HTTPS
cookie_secure   = false
cookie_samesite = lax

[auth.anonymous]
enabled = false

[analytics]
reporting_enabled = false
check_for_updates = false

[log]
mode  = console
level = warn
GINI

# Permissões do banco de dados do Grafana
chown -R grafana:grafana /etc/grafana/
chown -R grafana:grafana /var/lib/grafana/
chmod 640 /var/lib/grafana/grafana.db 2>/dev/null || true

systemctl daemon-reload
systemctl enable grafana-server
systemctl start grafana-server
sleep 10
echo "grafana-server: $(systemctl is-active grafana-server)"

# Reseta senha no banco correto (/var/lib/grafana/grafana.db)
# IMPORTANTE: --configOverrides aponta para o banco real do serviço
echo "Resetando senha do admin no banco correto..."
grafana-cli \
  --homepath /usr/share/grafana \
  --config /etc/grafana/grafana.ini \
  --configOverrides 'cfg:default.paths.data=/var/lib/grafana' \
  admin reset-admin-password "${GRAFANA_PASSWORD}" 2>/dev/null

systemctl restart grafana-server
sleep 8

# Confirma que a API responde (path correto com serve_from_sub_path=true)
echo "Grafana API:"
curl -s -u "admin:${GRAFANA_PASSWORD}" http://localhost:3000/grafana/api/health \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('  database:', d.get('database','?'))" \
  2>/dev/null || echo "  (aguardando inicialização...)"

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 8 — Datasource Prometheus + Dashboards
#
# CORREÇÃO CRÍTICA — Grafana 13 SSRF Protection:
# Grafana 13 bloqueia datasources com URL localhost/127.0.0.1.
# A URL do datasource DEVE usar o ALB público.
#
# UID fixo PBFA97CFB590B2093 é hardcoded nos dashboards JSON do TechStock.
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "--- [6/6] Criando datasource e importando dashboards ---"
sleep 5

python3 << PYEOF
import urllib.request, urllib.error, json, sys, time, base64

GRAFANA  = "http://localhost:3000/grafana"
USER     = "admin"
PASS     = "${GRAFANA_PASSWORD}"
ALB_DNS  = "${ALB_DNS}"
DS_UID   = "${DATASOURCE_UID}"

def gf(method, path, data=None):
    url = GRAFANA + path
    req = urllib.request.Request(url, method=method)
    creds = base64.b64encode(f"{USER}:{PASS}".encode()).decode()
    req.add_header("Authorization", f"Basic {creds}")
    req.add_header("Content-Type", "application/json")
    body = json.dumps(data).encode() if data else None
    try:
        with urllib.request.urlopen(req, body, timeout=20) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        return json.loads(e.read())
    except Exception as e:
        return {"error": str(e)}

# Aguarda Grafana estar pronto
print("Aguardando Grafana...")
for i in range(15):
    h = gf("GET", "/api/health")
    if h.get("database") == "ok":
        print("  Grafana pronto!")
        break
    time.sleep(5)
else:
    print("  ERRO: Grafana não respondeu — verifique grafana-server")
    sys.exit(1)

# Remove datasource existente (qualquer UID) e cria com UID e URL corretos
print(f"Configurando datasource (uid={DS_UID})...")
ds_list = gf("GET", "/api/datasources")
if isinstance(ds_list, list):
    for ds in ds_list:
        if ds.get("type") == "prometheus":
            old_uid = ds.get("uid")
            r = gf("DELETE", f"/api/datasources/uid/{old_uid}")
            print(f"  Removido datasource antigo: {old_uid}")

# URL via ALB — obrigatório no Grafana 13 (SSRF protection bloqueia localhost)
ds_url = f"http://{ALB_DNS}/prometheus"
result = gf("POST", "/api/datasources", {
    "name":      "Prometheus",
    "type":      "prometheus",
    "uid":       DS_UID,
    "url":       ds_url,
    "access":    "proxy",
    "isDefault": True,
    "jsonData":  {"timeInterval": "15s"}
})
if result.get("message") == "Datasource added":
    print(f"  ✓ Datasource criado: uid={DS_UID} url={ds_url}")
else:
    print(f"  ✗ Erro ao criar datasource: {result}")
    sys.exit(1)

# Importa dashboards da comunidade Grafana (substitui placeholder pelo UID correto)
dashboards = [
    (1860,  "node-exporter-full", "Node Exporter Full"),
    (11159, "nodejs-application", "Node.js Application"),
    (3662,  "prometheus-stats",   "Prometheus Stats"),
]

for gnet_id, slug, title in dashboards:
    print(f"\nImportando: {title} (ID {gnet_id})...")
    try:
        url = f"https://grafana.com/api/dashboards/{gnet_id}/revisions/latest/download"
        req = urllib.request.Request(url)
        req.add_header("Accept-Encoding", "gzip, deflate")
        req.add_header("User-Agent", "Mozilla/5.0")
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            # Descomprime gzip se necessário
            encoding = r.headers.get("Content-Encoding", "")
            if encoding == "gzip" or (raw[:2] == b'\x1f\x8b'):
                import gzip as gz
                raw = gz.decompress(raw)
            dash = json.loads(raw.decode("utf-8"))
        dash["id"]  = None
        dash["uid"] = slug
        dash_str = json.dumps(dash)
        # Substitui todos os placeholders de datasource pelo UID correto
        for ph in ['"${DS_PROMETHEUS}"', '"${DS_PROMETHEUS_1}"',
                   '"${DS_PROMETHEUS_2}"', '"${DS_PROMETHEUS_3}"',
                   '"${DS_THEMIS}"', '"${DS_PROMETHEUS_4}"',
                   '${DS_PROMETHEUS}']:
            dash_str = dash_str.replace(ph, f'"{DS_UID}"')
        result = gf("POST", "/api/dashboards/db", {
            "dashboard": json.loads(dash_str),
            "overwrite": True,
            "folderId":  0
        })
        if result.get("status") == "success":
            print(f"  ✓ Importado → /grafana/d/{slug}")
        else:
            print(f"  ✗ Erro: {result.get('message', result)}")
    except Exception as e:
        print(f"  ✗ Falha: {e}")

print("\nDashboards disponíveis:")
for d in (gf("GET", "/api/search?type=dash-db") or []):
    if isinstance(d, dict):
        print(f"  ✓ {d.get('title','?')} → /grafana/d/{d.get('uid','')}")
PYEOF

# ══════════════════════════════════════════════════════════════════════════════
# CloudWatch Agent
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "--- Instalando CloudWatch Agent ---"
dnf install -y amazon-cloudwatch-agent

cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CW'
{
  "metrics": {
    "namespace": "TechStock/Monitoring",
    "metrics_collected": {
      "cpu":  { "measurement": ["cpu_usage_active"],  "metrics_collection_interval": 60 },
      "mem":  { "measurement": ["mem_used_percent"],   "metrics_collection_interval": 60 },
      "disk": { "measurement": ["disk_used_percent"],  "resources": ["/"], "metrics_collection_interval": 60 }
    }
  }
}
CW

systemctl enable amazon-cloudwatch-agent
systemctl start amazon-cloudwatch-agent

# ══════════════════════════════════════════════════════════════════════════════
# VERIFICAÇÃO FINAL
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "============================================"
echo " Verificação Final"
echo "============================================"

echo ""
echo "Serviços:"
for svc in node_exporter prometheus nginx grafana-server amazon-cloudwatch-agent; do
  STATUS=$(systemctl is-active $svc 2>/dev/null)
  ICON=$([[ "$STATUS" == "active" ]] && echo "✓" || echo "✗")
  echo "  $ICON $svc: $STATUS"
done

echo ""
echo "Portas abertas:"
ss -tlnp | grep -E ':(80|9090|9100|3000)\s' | awk '{print "  " $1 " " $4}'

MY_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null)

echo ""
echo "Targets Prometheus:"
sleep 3
# CORREÇÃO: URL correta com /prometheus/api/v1/targets (route-prefix=/prometheus)
curl -s http://localhost:9090/prometheus/api/v1/targets 2>/dev/null \
  | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  for t in d['data']['activeTargets']:
    err = t.get('lastError','')
    icon = '✓' if t['health']=='up' else '✗'
    print(f\"  {icon} {t['labels']['job']:30} | {t['health']} | {err or 'ok'}\")
except Exception as e:
  print('  (erro ao ler targets:', e, ')')
"

if [[ -n "$BACKEND_PRIVATE_IP" ]]; then
  echo ""
  echo "Conectividade com o Backend:"
  curl -s --connect-timeout 3 "http://${BACKEND_PRIVATE_IP}:3000/metrics" | head -3 \
    && echo "  ✓ Backend /metrics acessível" \
    || echo "  ✗ Backend /metrics inacessível — verifique SG (porta 3000)"
  curl -s --connect-timeout 3 "http://${BACKEND_PRIVATE_IP}:9100/metrics" | head -3 \
    && echo "  ✓ Backend node_exporter acessível" \
    || echo "  ✗ Backend node_exporter inacessível — verifique SG (porta 9100)"
fi

echo ""
echo "============================================"
echo " Setup CONCLUÍDO: $(date)"
echo "============================================"
echo ""
echo "Acessos:"
echo "  Grafana:    http://${ALB_DNS}/grafana  (admin / ${GRAFANA_PASSWORD})"
echo "  Prometheus: http://${ALB_DNS}/prometheus"
echo "  IP privado: ${MY_IP}"
echo ""
echo "PENDÊNCIAS MANUAIS (Console AWS):"
echo "  1. Target Group tg-monitoring → porta 80 (não 3000)"
echo "  2. ALB Listener Rules:"
echo "       Prioridade 1 → /grafana*    → tg-monitoring"
echo "       Prioridade 2 → /prometheus* → tg-monitoring"
echo "       Prioridade 3 → /*           → tg-frontend"
if [[ -z "$BACKEND_PRIVATE_IP" ]]; then
  echo ""
  echo "  3. Configure o IP do backend em /etc/prometheus/prometheus.yml:"
  echo "       sudo nano /etc/prometheus/prometheus.yml"
  echo "       sudo promtool check config /etc/prometheus/prometheus.yml"
  echo "       sudo systemctl restart prometheus"
fi
