#!/bin/bash
# =============================================================================
# setup-monitoring.sh — Configuração do EC2 Monitoring
# TechStock | Prometheus + Grafana + node_exporter
# Execução interativa via SSM Session Manager
#
# CORREÇÕES APLICADAS:
#   - grafana.ini com serve_from_sub_path=true (acesso via ALB /grafana)
#   - Permissões /var/lib/grafana corrigidas
#   - Datasource Prometheus provisionado automaticamente
#   - Dashboards importados via script Python (sem depender de UI)
#   - Prometheus com --web.external-url=/prometheus (acesso via ALB)
#   - Validação de conectividade com o backend antes de finalizar
# =============================================================================

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 1 — VARIÁVEIS (edite antes de executar)
# ══════════════════════════════════════════════════════════════════════════════

BACKEND_PRIVATE_IP="COLE_O_IP_PRIVADO_DO_EC2_BACKEND_AQUI"
# Exemplo: 10.0.10.45
# Console AWS → EC2 → Instances → techstock-backend → Private IPv4

ALB_DNS="COLE_O_DNS_DO_ALB_AQUI"
# Exemplo: techstock-lb-105375070.us-east-1.elb.amazonaws.com
# Sem http:// — só o DNS

GRAFANA_PASSWORD="TechStock@2024"

PROMETHEUS_VERSION="2.51.2"
NODE_EXPORTER_VERSION="1.7.0"

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 2 — Validação
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "============================================"
echo " TechStock — Setup Monitoring"
echo " $(date)"
echo "============================================"

[[ "$BACKEND_PRIVATE_IP" == "COLE_O_IP_PRIVADO_DO_EC2_BACKEND_AQUI" ]] && \
  echo "AVISO: BACKEND_PRIVATE_IP não configurado — configure depois em prometheus.yml" && \
  BACKEND_PRIVATE_IP=""

[[ "$ALB_DNS" == "COLE_O_DNS_DO_ALB_AQUI" ]] && \
  echo "AVISO: ALB_DNS não configurado — Grafana ficará acessível somente via IP direto" && \
  ALB_DNS="localhost"

echo ""
echo "  Backend IP = ${BACKEND_PRIVATE_IP:-'(configurar depois)'}"
echo "  ALB DNS    = $ALB_DNS"
echo ""
read -p "Confirma? (s/N): " CONFIRM
[[ "$CONFIRM" =~ ^[Ss]$ ]] || { echo "Cancelado."; exit 0; }

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 3 — Sistema
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "--- [1/5] Atualizando sistema ---"
dnf update -y
dnf install -y wget curl tar python3

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 4 — Node Exporter
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "--- [2/5] Instalando Node Exporter v${NODE_EXPORTER_VERSION} ---"
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
echo "--- [3/5] Instalando Prometheus v${PROMETHEUS_VERSION} ---"

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

cat > /etc/prometheus/prometheus.yml << PROM
global:
  scrape_interval:     15s
  evaluation_interval: 15s
  external_labels:
    environment: learnerlab
    app:         techstock

scrape_configs:
  - job_name: 'prometheus'
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

# Serviço Prometheus — com subpath /prometheus para acesso via ALB
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
# SEÇÃO 6 — Grafana
# CORREÇÕES: serve_from_sub_path, permissões, datasource provisionado
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "--- [4/5] Instalando Grafana ---"

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

# CORREÇÃO: grafana.ini com subpath correto para acesso via ALB
cat > /etc/grafana/grafana.ini << GINI
[server]
http_addr = 0.0.0.0
http_port = 3000
domain    = ${ALB_DNS}
root_url  = %(protocol)s://%(domain)s/grafana/
serve_from_sub_path = true

[security]
admin_user     = admin
admin_password = ${GRAFANA_PASSWORD}
secret_key     = techstock-$(date +%s)

[auth.anonymous]
enabled = false

[analytics]
reporting_enabled = false
check_for_updates = false

[log]
mode  = console
level = warn
GINI

# CORREÇÃO: datasource provisionado automaticamente
mkdir -p /etc/grafana/provisioning/datasources
cat > /etc/grafana/provisioning/datasources/prometheus.yml << 'DS'
apiVersion: 1
deleteDatasources:
  - name: Prometheus
    orgId: 1
datasources:
  - name:      Prometheus
    type:      prometheus
    uid:       prometheus-techstock
    access:    proxy
    orgId:     1
    url:       http://localhost:9090
    isDefault: true
    editable:  true
    jsonData:
      timeInterval: "15s"
DS

# CORREÇÃO: permissões do diretório de dados do Grafana
chown -R grafana:grafana /etc/grafana/
chown -R grafana:grafana /var/lib/grafana/
chmod -R 755 /var/lib/grafana/

systemctl daemon-reload
systemctl enable grafana-server
systemctl start grafana-server
sleep 8
echo "grafana-server: $(systemctl is-active grafana-server)"

# Confirma que a API responde
echo "Grafana API:"
curl -s -u admin:${GRAFANA_PASSWORD} http://localhost:3000/grafana/api/health \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('  database:', d.get('database','?'))" \
  2>/dev/null || echo "  (aguardando inicialização...)"

# ══════════════════════════════════════════════════════════════════════════════
# SEÇÃO 7 — Importa Dashboards automaticamente
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "--- [5/5] Importando dashboards do Grafana ---"
sleep 5  # aguarda Grafana inicializar completamente

python3 << 'PYEOF'
import urllib.request, urllib.error, json, sys, time, base64

GRAFANA  = "http://localhost:3000/grafana"
USER     = "admin"
PASS     = "TechStock@2024"

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
for i in range(12):
    h = gf("GET", "/api/health")
    if h.get("database") == "ok":
        print(f"  Grafana pronto!")
        break
    time.sleep(5)
else:
    print("  AVISO: Grafana pode não estar pronto — tentando mesmo assim")

# Pega datasource
ds_list = gf("GET", "/api/datasources")
prom = next((d for d in (ds_list if isinstance(ds_list, list) else []) if d.get("type") == "prometheus"), None)
if not prom:
    print("Datasource não encontrado via provisioning — criando via API...")
    prom = gf("POST", "/api/datasources", {
        "name": "Prometheus", "type": "prometheus",
        "uid": "prometheus-techstock",
        "url": "http://localhost:9090",
        "access": "proxy", "isDefault": True
    })
    ds_list = gf("GET", "/api/datasources")
    prom = next((d for d in (ds_list if isinstance(ds_list, list) else []) if d.get("type") == "prometheus"), None)

if not prom:
    print("ERRO: não foi possível criar o datasource Prometheus")
    sys.exit(1)

ds_uid  = prom["uid"]
ds_name = prom["name"]
print(f"Datasource: {ds_name} (uid={ds_uid})")

# Importa dashboards da comunidade Grafana
dashboards = [
    (1860,  "node-exporter-full",  "Node Exporter Full"),
    (11159, "nodejs-application",  "Node.js Application"),
    (3662,  "prometheus-stats",    "Prometheus Stats"),
]

for gnet_id, slug, title in dashboards:
    print(f"\nImportando: {title} (ID {gnet_id})...")
    try:
        url = f"https://grafana.com/api/dashboards/{gnet_id}/revisions/latest/download"
        with urllib.request.urlopen(url, timeout=30) as r:
            dash = json.loads(r.read())
        dash["id"]  = None
        dash["uid"] = slug

        # Substitui todos os placeholders de datasource
        dash_str = json.dumps(dash)
        for ph in ['"${DS_PROMETHEUS}"', '"${DS_PROMETHEUS_1}"',
                   '"${DS_PROMETHEUS_2}"', '"${DS_PROMETHEUS_3}"',
                   '${DS_PROMETHEUS}']:
            dash_str = dash_str.replace(ph, f'"{ds_uid}"')

        result = gf("POST", "/api/dashboards/db", {
            "dashboard": json.loads(dash_str),
            "overwrite": True,
            "folderId": 0
        })
        if result.get("status") == "success":
            print(f"  ✓ Importado → /grafana/d/{slug}")
        else:
            print(f"  ✗ Erro: {result.get('message', result)}")
    except Exception as e:
        print(f"  ✗ Falha ao baixar/importar: {e}")

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
for svc in node_exporter prometheus grafana-server amazon-cloudwatch-agent; do
  STATUS=$(systemctl is-active $svc 2>/dev/null)
  ICON=$([[ "$STATUS" == "active" ]] && echo "✓" || echo "✗")
  echo "  $ICON $svc: $STATUS"
done

echo ""
echo "Portas abertas:"
ss -tlnp | grep -E ':(9090|9100|3000)\s' | awk '{print "  " $1 " " $4}'

MY_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null)

echo ""
echo "Targets Prometheus:"
sleep 3
curl -s http://localhost:9090/api/v1/targets 2>/dev/null \
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
  curl -s --connect-timeout 3 http://${BACKEND_PRIVATE_IP}:3000/metrics | head -3 \
    && echo "  ✓ Backend /metrics acessível" \
    || echo "  ✗ Backend /metrics inacessível — verifique SG"
  curl -s --connect-timeout 3 http://${BACKEND_PRIVATE_IP}:9100/metrics | head -3 \
    && echo "  ✓ Backend node_exporter acessível" \
    || echo "  ✗ Backend node_exporter inacessível — verifique SG"
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
if [[ -z "$BACKEND_PRIVATE_IP" ]]; then
  echo "PENDENTE: Configure o IP do backend em /etc/prometheus/prometheus.yml"
  echo "  sudo nano /etc/prometheus/prometheus.yml"
  echo "  sudo promtool check config /etc/prometheus/prometheus.yml"
  echo "  sudo systemctl restart prometheus"
fi
