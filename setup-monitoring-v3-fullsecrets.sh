#!/bin/bash
# =============================================================================
# setup-monitoring.sh — v3 FULL SECRETS MANAGER
# Todas as variáveis armazenadas no Secrets Manager.
# Confronta valores existentes e oferece atualização antes de prosseguir.
# =============================================================================

echo ""
echo "============================================"
echo " TechStock — Setup Monitoring v3"
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
echo "  Padrão: techstock/monitoring  (Enter para usar o padrão)"
read -p "  → " SECRET_NAME
SECRET_NAME="${SECRET_NAME// /}"
[[ -z "$SECRET_NAME" ]] && SECRET_NAME="techstock/monitoring"
echo "  ✓ SECRET_NAME: $SECRET_NAME"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# Lê secret existente
# ══════════════════════════════════════════════════════════════════════════════
echo "Buscando secret '$SECRET_NAME'..."
SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_NAME" --region "$AWS_REGION" \
  --query SecretString --output text 2>/dev/null)
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
  BACKEND_PRIVATE_IP=$(get_field BACKEND_PRIVATE_IP)
  GRAFANA_PASSWORD=$(get_field GRAFANA_PASSWORD)
  PROMETHEUS_VERSION=$(get_field PROMETHEUS_VERSION)
  NODE_EXPORTER_VERSION=$(get_field NODE_EXPORTER_VERSION)
  DATASOURCE_UID=$(get_field DATASOURCE_UID)
  GITHUB_RAW=$(get_field GITHUB_RAW)
  GITHUB_SUBDIR=$(get_field GITHUB_SUBDIR)
else
  echo "  ⚠ Secret não encontrado — será criado com novos valores."
  EXISTING=false
  GRAFANA_PASSWORD="TechStock@2024"
  PROMETHEUS_VERSION="2.51.2"
  NODE_EXPORTER_VERSION="1.7.0"
  DATASOURCE_UID="PBFA97CFB590B2093"
fi
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# Apresenta valores e pergunta se deseja atualizar
# ══════════════════════════════════════════════════════════════════════════════
echo "============================================"
echo " Valores atuais do secret"
echo "============================================"
echo "  ALB_DNS              = ${ALB_DNS:-'(não definido)'}"
echo "  BACKEND_PRIVATE_IP   = ${BACKEND_PRIVATE_IP:-'(não definido)'}"
echo "  GRAFANA_PASSWORD     = ${GRAFANA_PASSWORD:+'(definida)'}${GRAFANA_PASSWORD:-'(não definida)'}"
echo "  PROMETHEUS_VERSION   = ${PROMETHEUS_VERSION}"
echo "  NODE_EXPORTER_VERSION= ${NODE_EXPORTER_VERSION}"
echo "  DATASOURCE_UID       = ${DATASOURCE_UID}"
echo "  GITHUB_RAW           = ${GITHUB_RAW:-'(não definido)'}"
echo "  GITHUB_SUBDIR        = ${GITHUB_SUBDIR:-'(raiz)'}"
echo "============================================"
echo ""

prompt_field() {
  local label="$1" current="$2" secret="$3"
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
else
  UPDATE_CHOICE="s"
  echo "Preenchimento dos valores obrigatórios:"
fi
echo ""

if [[ "$UPDATE_CHOICE" =~ ^[Ss]$ ]]; then
  echo "── Infraestrutura ──────────────────────────"
  ALB_DNS=$(prompt_field "DNS do ALB (sem http://)" "$ALB_DNS")
  ALB_DNS="${ALB_DNS#http://}"; ALB_DNS="${ALB_DNS#https://}"; ALB_DNS="${ALB_DNS%/}"
  BACKEND_PRIVATE_IP=$(prompt_field "IP privado do EC2 Backend (vazio = configurar depois)" "$BACKEND_PRIVATE_IP")
  echo ""
  echo "── Grafana ─────────────────────────────────"
  GRAFANA_PASSWORD=$(prompt_field "Senha do Grafana admin" "$GRAFANA_PASSWORD" "true")
  DATASOURCE_UID=$(prompt_field "UID do datasource Prometheus" "$DATASOURCE_UID")
  echo ""
  echo "── Versões ─────────────────────────────────"
  PROMETHEUS_VERSION=$(prompt_field "Versão do Prometheus" "$PROMETHEUS_VERSION")
  NODE_EXPORTER_VERSION=$(prompt_field "Versão do Node Exporter" "$NODE_EXPORTER_VERSION")
  echo ""
  echo "── GitHub (dashboards TechStock) ───────────"
  GITHUB_RAW=$(prompt_field "URL base do repo (raw GitHub)" "$GITHUB_RAW")
  GITHUB_SUBDIR=$(prompt_field "Subdiretório dos dashboards (vazio = raiz)" "$GITHUB_SUBDIR")
  echo ""
fi

GITHUB_RAW="${GITHUB_RAW%/}"; GITHUB_SUBDIR="${GITHUB_SUBDIR%/}"
[[ -n "$GITHUB_SUBDIR" ]] && GITHUB_BASE="${GITHUB_RAW}/${GITHUB_SUBDIR}" || GITHUB_BASE="$GITHUB_RAW"

# Validação
ERRORS=0
[[ -z "$ALB_DNS" ]]          && echo "  ✗ ALB_DNS é obrigatório"          && ERRORS=$((ERRORS+1))
[[ -z "$GRAFANA_PASSWORD" ]] && echo "  ✗ GRAFANA_PASSWORD é obrigatório" && ERRORS=$((ERRORS+1))
[[ -z "$BACKEND_PRIVATE_IP" ]] && echo "  ⚠ BACKEND_PRIVATE_IP não definido — configure prometheus.yml depois"
[[ $ERRORS -gt 0 ]] && { echo "  ✗ Corrija e execute novamente."; exit 1; }

echo "============================================"
echo " Resumo final"
echo "============================================"
echo "  SECRET_NAME          = $SECRET_NAME"
echo "  AWS_REGION           = $AWS_REGION"
echo "  ALB_DNS              = $ALB_DNS"
echo "  BACKEND_PRIVATE_IP   = ${BACKEND_PRIVATE_IP:-'(configurar depois)'}"
echo "  GRAFANA_PASSWORD     = (definida)"
echo "  PROMETHEUS_VERSION   = $PROMETHEUS_VERSION"
echo "  NODE_EXPORTER_VERSION= $NODE_EXPORTER_VERSION"
echo "  DATASOURCE_UID       = $DATASOURCE_UID"
echo "  GITHUB_BASE          = ${GITHUB_BASE:-'(importação manual)'}"
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
  'BACKEND_PRIVATE_IP':    '${BACKEND_PRIVATE_IP}',
  'GRAFANA_PASSWORD':      '${GRAFANA_PASSWORD}',
  'PROMETHEUS_VERSION':    '${PROMETHEUS_VERSION}',
  'NODE_EXPORTER_VERSION': '${NODE_EXPORTER_VERSION}',
  'DATASOURCE_UID':        '${DATASOURCE_UID}',
  'AWS_REGION':            '${AWS_REGION}',
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
    --description "TechStock Monitoring — variáveis de configuração" \
    --secret-string "$SECRET_JSON" --region "$AWS_REGION" \
    && echo "  ✓ Secret criado" || { echo "  ✗ Erro ao criar"; exit 1; }
fi

# ══════════════════════════════════════════════════════════════════════════════
# Monta bloco backend para prometheus.yml
# ══════════════════════════════════════════════════════════════════════════════
if [[ -n "$BACKEND_PRIVATE_IP" ]]; then
  BACKEND_JOBS="
  - job_name: 'techstock-app'
    static_configs:
      - targets: ['${BACKEND_PRIVATE_IP}:3000']
    metrics_path: /metrics
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
  # Configure depois: sudo nano /etc/prometheus/prometheus.yml
  # - job_name: 'techstock-app'
  #   static_configs:
  #     - targets: ['10.0.10.X:3000']
  # - job_name: 'node-exporter-backend'
  #   static_configs:
  #     - targets: ['10.0.10.X:9100']"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Instalação
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [1/6] Sistema + Nginx ---"
dnf update -y
dnf install -y wget curl tar python3 nginx

echo ""
echo "--- [2/6] Node Exporter v${NODE_EXPORTER_VERSION} ---"
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
RestartSec=5
[Install]
WantedBy=multi-user.target
NE
systemctl daemon-reload
systemctl enable node_exporter --now
echo "node_exporter: $(systemctl is-active node_exporter)"

echo ""
echo "--- [3/6] Prometheus v${PROMETHEUS_VERSION} ---"
useradd --no-create-home --shell /bin/false prometheus 2>/dev/null || true
mkdir -p /etc/prometheus /var/lib/prometheus
chown prometheus:prometheus /etc/prometheus /var/lib/prometheus
wget -q "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz" -O /tmp/prom.tar.gz
tar xzf /tmp/prom.tar.gz -C /tmp/
cp /tmp/prometheus-${PROMETHEUS_VERSION}.linux-amd64/prometheus  /usr/local/bin/
cp /tmp/prometheus-${PROMETHEUS_VERSION}.linux-amd64/promtool    /usr/local/bin/
chmod +x /usr/local/bin/prometheus /usr/local/bin/promtool

cat > /etc/prometheus/prometheus.yml << PROM
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    environment: production
    app: techstock

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
promtool check config /etc/prometheus/prometheus.yml && echo "prometheus.yml: OK"

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
systemctl enable prometheus --now
sleep 3
echo "prometheus: $(systemctl is-active prometheus)"

echo ""
echo "--- [4/6] Nginx ---"
cat > /etc/nginx/nginx.conf << 'NGXMAIN'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;
include /usr/share/nginx/modules/*.conf;
events { worker_connections 1024; }
http { include /etc/nginx/conf.d/*.conf; }
NGXMAIN
cat > /etc/nginx/conf.d/techstock-monitoring.conf << 'NGXCONF'
server {
    listen 80;
    location /grafana/ {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
    location /prometheus/ {
        proxy_pass http://127.0.0.1:9090;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
NGXCONF
nginx -t && echo "Nginx OK" || { echo "ERRO Nginx!"; exit 1; }
systemctl enable nginx --now
echo "nginx: $(systemctl is-active nginx)"

echo ""
echo "--- [5/6] Grafana ---"
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
allow_embedding = true
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

chown -R grafana:grafana /etc/grafana/ /var/lib/grafana/
chmod 640 /var/lib/grafana/grafana.db 2>/dev/null || true
systemctl daemon-reload
systemctl enable grafana-server --now
sleep 10
echo "grafana-server: $(systemctl is-active grafana-server)"

grafana-cli \
  --homepath /usr/share/grafana \
  --config /etc/grafana/grafana.ini \
  --configOverrides 'cfg:default.paths.data=/var/lib/grafana' \
  admin reset-admin-password "${GRAFANA_PASSWORD}" 2>/dev/null
systemctl restart grafana-server
sleep 8

echo ""
echo "--- [6/6] Datasource + Dashboards ---"
python3 << PYEOF
import urllib.request, urllib.error, json, sys, time, base64, gzip as gz

GRAFANA = "http://localhost:3000/grafana"
USER    = "admin"
PASS    = "${GRAFANA_PASSWORD}"
DS_UID  = "${DATASOURCE_UID}"
ALB     = "${ALB_DNS}"
GITHUB  = "${GITHUB_BASE}"

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

print("Aguardando Grafana...")
for i in range(15):
    h = gf("GET", "/api/health")
    if h.get("database") == "ok":
        print("  Grafana pronto!"); break
    time.sleep(5)
else:
    print("  ERRO: Grafana não respondeu"); sys.exit(1)

# Datasource
print(f"Configurando datasource uid={DS_UID}...")
ds_list = gf("GET", "/api/datasources")
if isinstance(ds_list, list):
    for ds in ds_list:
        if ds.get("type") == "prometheus":
            gf("DELETE", f"/api/datasources/uid/{ds.get('uid')}")
            print(f"  Removido: {ds.get('uid')}")

result = gf("POST", "/api/datasources", {
    "name": "Prometheus", "type": "prometheus", "uid": DS_UID,
    "url": f"http://{ALB}/prometheus", "access": "proxy", "isDefault": True,
    "jsonData": {"timeInterval": "15s"}
})
print(f"  {'✓' if result.get('message') == 'Datasource added' else '✗'} {result.get('message', result)}")

# Dashboards comunidade
for gnet_id, slug, title in [(1860,"node-exporter-full","Node Exporter Full"),(11159,"nodejs-application","Node.js Application"),(3662,"prometheus-stats","Prometheus Stats")]:
    print(f"Importando: {title} (ID {gnet_id})...")
    try:
        req = urllib.request.Request(f"https://grafana.com/api/dashboards/{gnet_id}/revisions/latest/download")
        req.add_header("Accept-Encoding","gzip, deflate"); req.add_header("User-Agent","Mozilla/5.0")
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            if raw[:2] == b'\x1f\x8b': raw = gz.decompress(raw)
            dash = json.loads(raw.decode("utf-8"))
        dash["id"] = None; dash["uid"] = slug
        dash_str = json.dumps(dash)
        for ph in ['"${DS_PROMETHEUS}"','"${DS_PROMETHEUS_1}"','${DS_PROMETHEUS}','"${DS_THEMIS}"']:
            dash_str = dash_str.replace(ph, f'"{DS_UID}"')
        result = gf("POST", "/api/dashboards/db", {"dashboard": json.loads(dash_str), "overwrite": True, "folderId": 0})
        print(f"  {'OK' if result.get('status') == 'success' else 'Erro'} -> /grafana/d/{slug}")
    except Exception as e:
        print(f"  Falha: {e}")

# Dashboards TechStock do GitHub
if GITHUB:
    import os, glob
    DASH_DIR = "/tmp/techstock-dashboards"
    os.makedirs(DASH_DIR, exist_ok=True)
    print(f"\nBaixando dashboards TechStock de: {GITHUB}")
    for dash_name in ["dashboard_techstock-observability.json","dashboard_techstock-infra-ec2.json","dashboard_techstock-api.json","dashboard_techstock-rds.json","dashboard_techstock-devops.json"]:
        url = f"{GITHUB}/{dash_name}"
        try:
            with urllib.request.urlopen(url, timeout=20) as r:
                raw = r.read()
                if raw[:2] == b'\x1f\x8b': raw = gz.decompress(raw)
                open(f"{DASH_DIR}/{dash_name}", 'wb').write(raw)
                print(f"  ✓ {dash_name}")
        except Exception as e:
            print(f"  ✗ {dash_name}: {e}")

    for fpath in sorted(glob.glob(f"{DASH_DIR}/dashboard_techstock-*.json")):
        fname = os.path.basename(fpath)
        try:
            payload = json.load(open(fpath))
            result = gf("POST", "/api/dashboards/db", payload)
            if result.get("status") == "success":
                print(f"  ✓ Importado: {fname} -> /grafana/d/{result.get('uid','?')}")
            else:
                print(f"  ✗ {fname}: {result.get('message', result)}")
        except Exception as e:
            print(f"  ✗ {fname}: {e}")
else:
    print("\n⚠ GITHUB_BASE não definido — dashboards TechStock não importados.")
    print("  Use o script novamente para definir GITHUB_RAW, ou importe manualmente:")
    print("  curl -X POST http://localhost:3000/grafana/api/dashboards/db \\")
    print(f"    -u admin:{PASS} -H Content-Type:application/json -d @dashboard_techstock-XXX.json")
PYEOF

dnf install -y amazon-cloudwatch-agent
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CW'
{
  "metrics": { "namespace": "TechStock/Monitoring", "metrics_collected": {
    "cpu":  { "measurement": ["cpu_usage_active"],  "metrics_collection_interval": 60 },
    "mem":  { "measurement": ["mem_used_percent"],   "metrics_collection_interval": 60 },
    "disk": { "measurement": ["disk_used_percent"],  "resources": ["/"], "metrics_collection_interval": 60 }
  }}
}
CW
systemctl enable amazon-cloudwatch-agent --now

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
for svc in node_exporter prometheus nginx grafana-server amazon-cloudwatch-agent; do
  STATUS=$(systemctl is-active $svc 2>/dev/null)
  echo "  $([[ "$STATUS" == "active" ]] && echo ✓ || echo ✗) $svc: $STATUS"
done
ss -tlnp | grep -E ':(80|3000|9090|9100)\s' | awk '{print "  " $1 " " $4}'
sleep 3
curl -s http://localhost:9090/prometheus/api/v1/targets | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  for t in d['data']['activeTargets']:
    print(f\"  {'✓' if t['health']=='up' else '✗'} {t['labels']['job']:35} | {t['health']}\")
except Exception as e: print('  erro:', e)"
echo ""
echo "Dashboards importados:"
curl -s 'http://localhost:3000/grafana/api/search?type=dash-db' \
  -u "admin:${GRAFANA_PASSWORD}" 2>/dev/null \
  | python3 -c "
import sys,json
try:
  for d in json.load(sys.stdin):
    print(f\"  ✓ {d['title']}\")
except: pass"
echo ""
echo "============================================"
echo " Setup CONCLUÍDO: $(date)"
echo "============================================"
echo ""
MY_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null)
echo "IP privado: $MY_IP"
echo "Secret: $SECRET_NAME (região: $AWS_REGION)"
echo ""
echo "Acessos:"
echo "  Grafana:    http://${ALB_DNS}/grafana  (admin / ${GRAFANA_PASSWORD})"
echo "  Prometheus: http://${ALB_DNS}/prometheus"
echo ""
echo "Para atualizar variáveis: execute novamente este script"
echo ""
echo "PENDÊNCIAS:"
echo "  1. Target Group tg-monitoring → porta 80"
echo "  2. ALB Rules: /grafana* (pri 1), /prometheus* (pri 2), /* (pri 3+)"
[[ -z "$BACKEND_PRIVATE_IP" ]] && echo "  3. Configure BACKEND_PRIVATE_IP: execute o script novamente"
