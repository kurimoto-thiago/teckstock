# 📦 TechStock — Monitoring Stack (Prometheus + Grafana)

> Guia baseado no `setup-monitoring.sh` corrigido.  
> O script cobre toda a instalação automaticamente. Apenas as pendências de Console AWS são manuais.

**Stack:** `Prometheus 2.51.2` `Grafana 13` `Node Exporter 1.7.0` `Nginx` `CloudWatch Agent` `AWS Learner Lab`

---

## 🏗️ Arquitetura

```
Internet (HTTP:80)
    │
    ▼
ALB (SEU_ALB_DNS)
    ├── /grafana/*    → tg-monitoring (EC2 Monitoring :80)  ← prioridade 1
    ├── /prometheus/* → tg-monitoring (EC2 Monitoring :80)  ← prioridade 2
    ├── /api/*        → tg-backend    (EC2 Backend :3000)
    └── /*            → tg-frontend   (EC2 Frontend)        ← prioridade 3

EC2 Monitoring (subnet privada)
    ├── Nginx :80
    │       ├── /grafana/    → proxy → http://127.0.0.1:3000
    │       └── /prometheus/ → proxy → http://127.0.0.1:9090
    ├── Grafana :3000
    │       └── datasource URL → http://ALB_DNS/prometheus
    │                            ↑ usa ALB (SSRF protection Grafana 13)
    ├── Prometheus :9090  (--web.route-prefix=/prometheus)
    │       ├── job: prometheus              → localhost:9090/prometheus/metrics
    │       ├── job: node-exporter-monitoring → localhost:9100/metrics
    │       ├── job: node-exporter-backend   → BACKEND_IP:9100/metrics
    │       └── job: techstock-app           → BACKEND_IP:3000/metrics
    └── CloudWatch Agent → namespace TechStock/Monitoring
```

---

## ⚡ Execução

### Pré-requisitos

- EC2 Monitoring em subnet privada com `LabInstanceProfile`
- NAT Gateway ativo
- Security Group: inbound 80, 3000, 9090, 9100 da VPC; outbound 443
- Node Exporter instalado no EC2 Backend (ver seção abaixo)
- Target Group `tg-monitoring` criado na porta **80**

### Editar variáveis antes de executar

```bash
BACKEND_PRIVATE_IP="10.0.10.XX"   # IP privado do EC2 Backend
ALB_DNS="techstock-alb-XXXX.us-east-1.elb.amazonaws.com"  # sem http://
GRAFANA_PASSWORD="TechStock@2024"
```

> ⚠️ `ALB_DNS` é obrigatório. O script falha se não for preenchido.

### Executar via SSM Session Manager

```bash
sudo bash setup-monitoring.sh
```

---

## 1️⃣ Node Exporter no EC2 Backend (manual)

O script instala Node Exporter apenas no EC2 Monitoring. Execute no EC2 Backend via SSM:

```bash
NODE_VERSION="1.7.0"
wget -q "https://github.com/prometheus/node_exporter/releases/download/v${NODE_VERSION}/node_exporter-${NODE_VERSION}.linux-amd64.tar.gz" -O /tmp/ne.tar.gz
tar xzf /tmp/ne.tar.gz -C /tmp/
sudo cp /tmp/node_exporter-${NODE_VERSION}.linux-amd64/node_exporter /usr/local/bin/
sudo chmod +x /usr/local/bin/node_exporter

sudo tee /etc/systemd/system/node_exporter.service << 'EOF'
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
EOF

sudo systemctl daemon-reload
sudo systemctl enable node_exporter --now
curl -s http://localhost:9100/metrics | grep '^node_load1' | head -1
```

---

## 2️⃣ Prometheus — O que o script configura

### prometheus.yml gerado

```yaml
global:
  scrape_interval:     15s
  evaluation_interval: 15s
  external_labels:
    environment: learnerlab
    app:         techstock

scrape_configs:

  # metrics_path obrigatório — Prometheus inicia com --web.route-prefix=/prometheus
  # Sem isso o endpoint real (/prometheus/metrics) retorna 404
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

  - job_name: 'techstock-app'
    static_configs:
      - targets: ['BACKEND_IP:3000']
    metrics_path: /metrics

  - job_name: 'node-exporter-backend'
    static_configs:
      - targets: ['BACKEND_IP:9100']
```

### Serviço systemd

```ini
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --storage.tsdb.retention.time=15d \
  --web.listen-address=0.0.0.0:9090 \
  --web.external-url=/prometheus \
  --web.route-prefix=/prometheus
```

---

## 3️⃣ Nginx — O que o script configura

O script instala Nginx e configura proxy reverso. **O Target Group do ALB deve apontar para a porta 80.**

```nginx
server {
    listen 80;

    location /grafana/ {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    location /prometheus/ {
        proxy_pass http://127.0.0.1:9090;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

> ⚠️ O `nginx.conf` padrão do AL2023 tem um `server` block default que conflita. O script substitui o arquivo inteiro.

---

## 4️⃣ ALB — Configuração manual obrigatória

### Target Group `tg-monitoring`

| Campo | Valor |
|---|---|
| Porta | **80** (Nginx) — nunca 3000 |
| Health check path | /grafana/api/health |
| Instância | EC2 Monitoring |

### Listener Rules HTTP:80

> 🔴 ALB avalia da menor para a maior prioridade. `/*` deve ter prioridade **maior** que `/grafana*` e `/prometheus*`.

| Prioridade | Path | Target Group |
|---|---|---|
| **1** | /grafana* | tg-monitoring |
| **2** | /prometheus* | tg-monitoring |
| **3** | /* | tg-frontend |
| Last | (default) | tg-backend |

---

## 5️⃣ Grafana — O que o script configura

### grafana.ini

```ini
[server]
http_addr = 0.0.0.0
http_port = 3000
domain    = SEU_ALB_DNS
root_url  = %(protocol)s://%(domain)s/grafana/
serve_from_sub_path = true

[security]
admin_user     = admin
admin_password = TechStock@2024
secret_key     = techstock-TIMESTAMP
allow_embedding = true
cookie_secure   = false
cookie_samesite = lax
```

> ⚠️ Seções duplicadas no `grafana.ini` causam loop de login. O script sempre substitui o arquivo inteiro com `cat >`.

### Reset de senha (quando necessário)

O script faz o reset automaticamente após a instalação. Se precisar refazer manualmente:

```bash
# OBRIGATÓRIO: --configOverrides aponta para o banco real do serviço
sudo grafana-cli \
  --homepath /usr/share/grafana \
  --config /etc/grafana/grafana.ini \
  --configOverrides 'cfg:default.paths.data=/var/lib/grafana' \
  admin reset-admin-password TechStock@2024

sudo systemctl restart grafana-server
```

> ⚠️ Sem `--configOverrides`, o `grafana-cli` cria um banco novo em `/usr/share/grafana/data/` e o reset não afeta o banco real do serviço.

---

## 6️⃣ Datasource Prometheus — O que o script configura

### Por que URL do ALB e não localhost

Grafana 13 bloqueia datasources com URL `localhost` ou `127.0.0.1` (SSRF protection). O script usa o ALB automaticamente.

### UID fixo `PBFA97CFB590B2093`

Os dashboards JSON TechStock têm esse UID hardcoded. O script cria o datasource com esse UID.

### Recriar manualmente (se necessário)

```bash
# Remove datasource existente
curl -X DELETE 'http://localhost:3000/grafana/api/datasources/uid/SEU_UID_ATUAL' \
  -u 'admin:TechStock@2024'

# Cria com UID e URL corretos
curl -X POST 'http://localhost:3000/grafana/api/datasources' \
  -u 'admin:TechStock@2024' \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "Prometheus",
    "type": "prometheus",
    "uid": "PBFA97CFB590B2093",
    "url": "http://SEU_ALB_DNS/prometheus",
    "access": "proxy",
    "isDefault": true
  }'

# Verifica
curl -s 'http://localhost:3000/grafana/api/datasources' \
  -u 'admin:TechStock@2024' | python3 -m json.tool | grep -E '"uid"|"url"'
```

> ⚠️ O path da API é `/grafana/api/...` quando `serve_from_sub_path = true`.

---

## 7️⃣ Dashboards

### Importados automaticamente pelo script (comunidade Grafana)

| ID | Nome | Cobre |
|---|---|---|
| 1860 | Node Exporter Full | CPU, RAM, disco, rede |
| 11159 | Node.js Application | Heap, GC, event loop, req/s |
| 3662 | Prometheus Stats | Self-monitoring do Prometheus |

---

### Dashboards customizados TechStock

Todos compatíveis com a infraestrutura atual. O `server.js` expõe todas as métricas via `prom-client` com prefixo `techstock_`.

| Arquivo | Foco | Fonte |
|---|---|---|
| dashboard_techstock-observability.json | Status UP/DOWN todos os targets | Prometheus nativo ✅ |
| dashboard_techstock-infra-ec2.json | CPU, RAM, disco, rede por EC2 | Node Exporter ✅ |
| dashboard_techstock-api.json | Req/s, heap, GC, event loop, erros 5xx | prom-client (`techstock_*`) ✅ |
| dashboard_techstock-rds.json | Carga no banco via rotas da API | prom-client (`techstock_*`) ✅ |
| dashboard_techstock-devops.json | API online, processo, handles, rede | Node Exporter + prom-client ✅ |

> Confirma métricas disponíveis no backend:
> ```bash
> curl -s http://BACKEND_IP:3000/metrics | grep techstock_ | head -15
> ```

---

### Importação via API (recomendado — evita bloqueio do ALB)

O ALB pode bloquear uploads grandes pela UI do Grafana. Use a API diretamente no EC2 Monitoring.

**Passo 1 — Copie os JSONs para o EC2 Monitoring**

```bash
# Opção A — via S3
aws s3 sync s3://SEU_BUCKET/dashboards/ /tmp/dashboards/

# Opção B — scp da sua máquina local
scp -i vockey.pem dashboard_techstock-*.json ec2-user@IP_MONITORING:/tmp/dashboards/
```

**Passo 2 — Importa todos via curl (no EC2 Monitoring via SSM)**

```bash
cd /tmp/dashboards

for f in \
  dashboard_techstock-observability.json \
  dashboard_techstock-infra-ec2.json \
  dashboard_techstock-api.json \
  dashboard_techstock-rds.json \
  dashboard_techstock-devops.json; do

  echo "Importando $f..."
  curl -s -X POST http://localhost:3000/grafana/api/dashboards/db \
    -u 'admin:TechStock@2024' \
    -H 'Content-Type: application/json' \
    -d @$f \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
if d.get('status') == 'success':
    print('  OK -> /grafana/d/' + d.get('uid','?'))
else:
    print('  Erro:', d.get('message', d))
"
done
```

**Passo 3 — Verifica dashboards importados**

```bash
curl -s 'http://localhost:3000/grafana/api/search?type=dash-db' \
  -u 'admin:TechStock@2024' \
  | python3 -c "
import sys, json
for d in json.load(sys.stdin):
    print(f'  {d["title"]} -> /grafana/d/{d["uid"]}')
"
```

> O path da API usa `/grafana/api/...` porque `serve_from_sub_path = true` está ativo.

---

### CloudWatch como datasource adicional

Para métricas nativas do RDS (conexões reais, storage, CPU) e EC2 via CloudWatch.

**Grafana → Connections → Add new connection → CloudWatch**

| Campo | Valor |
|---|---|
| Authentication Provider | `AWS SDK Default` (usa LabInstanceProfile automaticamente) |
| Default Region | `us-east-1` (ou sua região) |

Clica **Save & Test**.

**Métricas úteis:**

```
Namespace: AWS/RDS
  DatabaseConnections, FreeStorageSpace, CPUUtilization
  Dimensão: DBInstanceIdentifier = techstock-db

Namespace: AWS/EC2
  CPUUtilization, NetworkIn, NetworkOut
  Dimensão: InstanceId = ID dos EC2s

Namespace: TechStock/Monitoring
  cpu_usage_active, mem_used_percent, disk_used_percent
  (enviado pelo CloudWatch Agent — já configurado pelo script)
```

---

## 📋 Checklist de Implantação

```
Pré-script
[ ] EC2 Monitoring provisionado (subnet privada, LabInstanceProfile)
[ ] NAT Gateway ativo
[ ] Security Group: inbound 80, 3000, 9090, 9100 da VPC
[ ] Node Exporter instalado no EC2 Backend
[ ] Target Group tg-monitoring criado (porta 80)

Script
[ ] BACKEND_PRIVATE_IP e ALB_DNS preenchidos
[ ] sudo bash setup-monitoring.sh
[ ] Todos os serviços active na verificação final
[ ] Datasource criado com UID PBFA97CFB590B2093
[ ] Dashboards importados com sucesso

Console AWS (pós-script)
[ ] Target Group tg-monitoring: porta 80 confirmada
[ ] ALB Listener Rule prioridade 1: /grafana* → tg-monitoring
[ ] ALB Listener Rule prioridade 2: /prometheus* → tg-monitoring
[ ] Regra /* (frontend) com prioridade maior que 2

Validação
[ ] http://ALB_DNS/grafana → abre Grafana
[ ] http://ALB_DNS/prometheus → abre Prometheus
[ ] Todos os targets UP em /prometheus/targets
[ ] Dashboards carregando dados
```

---

## 📋 Variáveis de Referência

| Variável | Valor | Observação |
|---|---|---|
| ALB DNS | SEU_ALB_DNS | Sem barra no final |
| Grafana `domain` | ALB DNS | Sem protocolo, sem path |
| Grafana `root_url` | %(protocol)s://%(domain)s/grafana/ | Trailing slash obrigatória |
| `serve_from_sub_path` | true | Obrigatório |
| Prometheus port | 9090 | Acesso interno |
| Grafana port | 3000 | Acesso interno |
| Nginx port | 80 | Recebe ALB |
| Datasource UID | PBFA97CFB590B2093 | Hardcoded nos JSONs TechStock |
| Datasource URL | http://ALB_DNS/prometheus | ALB — SSRF Grafana 13 |
| Target Group porta | 80 | Nginx, não 3000 |
| API path com sub-path | /grafana/api/... | Não /api/... |

---

## 🔧 Troubleshooting

| Sintoma | Causa | Fix |
|---|---|---|
| 503 ao acessar /grafana ou /prometheus | Nginx inactive | `sudo systemctl start nginx` |
| ALB abre frontend em /grafana | Prioridade de regra errada | /grafana* e /prometheus* → prioridade 1 e 2 |
| Grafana 403 no datasource | SSRF protection Grafana 13 | Usar URL do ALB no datasource |
| Prometheus self-monitoring DOWN (404) | `metrics_path` ausente | Verificar `metrics_path: /prometheus/metrics` no job |
| Dashboard "datasource not found" | UID errado | Recriar datasource com UID `PBFA97CFB590B2093` |
| Grafana loop de login | Seções duplicadas no grafana.ini | Substituir arquivo inteiro com `cat >` |
| grafana-cli reset não funciona | Banco errado | Usar `--configOverrides 'cfg:default.paths.data=/var/lib/grafana'` |
| 401 na API Grafana | Senha não aplicada no banco correto | Reset com `--configOverrides` + restart |
| Target Group unhealthy | TG na porta 3000 sem Nginx | Atualizar TG para porta 80 |
| Targets JSON parse error | URL sem /prometheus prefix | Usar `/prometheus/api/v1/targets` |

### Diagnóstico rápido

```bash
# Status de todos os serviços
for svc in node_exporter prometheus nginx grafana-server amazon-cloudwatch-agent; do
  echo "$svc: $(systemctl is-active $svc)"
done

# Portas em uso
ss -tlnp | grep -E ':(80|3000|9090|9100)\s'

# Testa localmente
curl -s http://localhost:9090/prometheus/api/v1/query?query=up
curl -s http://localhost:3000/grafana/api/health
curl -s http://localhost/grafana/api/health

# Testa via ALB
curl -s http://SEU_ALB/prometheus/api/v1/query?query=up
curl -s http://SEU_ALB/grafana/api/health

# Datasources configurados
curl -s http://localhost:3000/grafana/api/datasources \
  -u 'admin:TechStock@2024' | python3 -m json.tool | grep -E '"uid"|"url"|"name"'

# Logs Grafana
journalctl -u grafana-server --since "10 minutes ago" | grep -E 'error|warn' | tail -20

# Valida prometheus.yml
sudo promtool check config /etc/prometheus/prometheus.yml
```
