# 📦 TechStock — Monitoring Stack (Prometheus + Grafana)

> Guia completo de implantação, configuração e troubleshooting da stack de observabilidade no EC2 Monitoring. Gerado a partir de sessão real de debugging.

**Tags:** `Prometheus 2.x` `Grafana 13` `Node Exporter` `Nginx Proxy` `AWS Learner Lab`

---

## 🏗️ Arquitetura do EC2 Monitoring

O EC2 Monitoring centraliza todas as ferramentas de observabilidade. Fica em subnet privada e é acessado via ALB com path-based routing.

```
Internet (HTTP:80)
    │
    ▼
ALB (techstock-alb-*.us-west-2.elb.amazonaws.com)
    │
    ├── /api/*        → EC2 Backend (Node.js :3000)
    ├── /grafana/*    → EC2 Monitoring (:80)  ─┐
    ├── /prometheus/* → EC2 Monitoring (:80)  ─┤
    └── /*            → EC2 Frontend (Nginx)   │
                                               │
EC2 Monitoring (10.0.10.59)                   │
    │                                         │
    ├── Nginx :80  ◄───────────────────────────┘
    │       ├── /grafana/    → proxy → Grafana :3000
    │       └── /prometheus/ → proxy → Prometheus :9090
    │
    ├── Grafana :3000
    │       └── datasource → http://ALB_DNS/prometheus
    │                        (usa ALB por SSRF protection do Grafana 13)
    │
    └── Prometheus :9090
            ├── /prometheus/metrics  (self-monitoring)
            ├── job: node-exporter-monitoring → localhost:9100
            ├── job: node-exporter-backend   → 10.0.10.38:9100
            └── job: techstock-app           → 10.0.10.38:3000
```

> ⚠️ **Grafana 13 — SSRF Protection:** A partir do Grafana 9+, o proxy de datasources bloqueia conexões para `localhost` e IPs privados. No Grafana 13 essa proteção é mais agressiva. A solução é usar o URL público do ALB como datasource URL, mesmo que Grafana e Prometheus estejam na mesma máquina.

---

## 🐛 Problemas Encontrados e Corrigidos

### BUG 1 — EC2 Monitoring sem Nginx

**Causa:** O EC2 Monitoring não tinha Nginx instalado. Sem proxy, as requisições do ALB chegavam direto nas portas internas — mas o ALB só roteia para a porta configurada no Target Group.

**Fix:** Instalação e configuração do Nginx com proxy reverso para Grafana (:3000) e Prometheus (:9090). Target Group atualizado para porta 80.

---

### BUG 2 — ALB com prioridade de regras errada

**Causa:** A regra `/*` (frontend) tinha prioridade 3, enquanto `/grafana*` e `/prometheus*` tinham prioridades 10 e 20. O ALB avalia da menor para a maior, então `/*` capturava tudo primeiro.

**Fix:** Regras de `/grafana*` e `/prometheus*` movidas para prioridades 1 e 2 (menores que 3).

---

### BUG 3 — Target Group apontando para porta 3000

**Causa:** O Target Group do EC2 Monitoring estava com roteamento na porta 3000 (Grafana direto). Sem Nginx na frente, o ALB mandava para Grafana sem passar pelo proxy — impossibilitando o roteamento de `/prometheus`.

**Fix:** Target Group atualizado para porta 80 (Nginx).

---

### BUG 4 — Prometheus self-monitoring 404

**Causa:** Prometheus iniciado com `--web.route-prefix=/prometheus`, mas o job de auto-monitoramento usava `metrics_path` padrão (`/metrics`). O endpoint correto é `/prometheus/metrics`.

**Fix:** Adicionado `metrics_path: /prometheus/metrics` no job `prometheus` do `prometheus.yml`.

---

### BUG 5 — Grafana 13 bloqueando datasource localhost (SSRF)

**Causa:** Grafana 13 bloqueia conexões de proxy para `localhost`, `127.0.0.1` e IPs RFC-1918 por padrão. Nenhuma configuração do `grafana.ini` desabilita completamente no v13.

**Fix:** Datasource configurado com URL pública do ALB: `http://ALB_DNS/prometheus`.

---

### BUG 6 — UID do datasource divergente dos dashboards

**Causa:** Os dashboards TechStock referenciavam UID `PBFA97CFB590B2093`, mas o datasource criado recebeu UID automático `prometheus-techstock`. Todos os painéis retornavam "datasource not found".

**Fix:** Datasource deletado e recriado via API com UID forçado: `PBFA97CFB590B2093`.

---

### BUG 7 — grafana.ini com seções duplicadas

**Causa:** Múltiplas tentativas de debug resultaram em seções `[security]`, `[dataproxy]` e `[feature_toggles]` duplicadas. Isso causou loop de login no Grafana.

**Fix:** Arquivo reconstruído do zero com `tee`, mantendo apenas uma instância de cada seção.

---

## 1️⃣ Prometheus — Instalação

Prometheus não tem pacote oficial no yum/dnf para Amazon Linux 2023. A instalação é feita baixando o binário diretamente do GitHub.

> ℹ️ Prometheus é um servidor de métricas que faz **scraping** (coleta ativa) em endpoints HTTP. Cada serviço monitorado expõe um endpoint `/metrics` no formato Prometheus.

### 1.1 — Download e instalação do binário

```bash
# Cria usuário sem shell (segurança: processo não precisa de login)
sudo useradd --no-create-home --shell /bin/false prometheus

# Diretórios de dados e configuração
sudo mkdir -p /etc/prometheus /var/lib/prometheus

# Download — ajuste a versão conforme necessário
PROM_VERSION="2.47.0"
wget https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.linux-amd64.tar.gz

tar -xzf prometheus-${PROM_VERSION}.linux-amd64.tar.gz
cd prometheus-${PROM_VERSION}.linux-amd64

# Copia os binários
sudo cp prometheus promtool /usr/local/bin/
sudo chown prometheus:prometheus /usr/local/bin/prometheus /usr/local/bin/promtool

# Copia consoles e libraries (UI embutida do Prometheus)
sudo cp -r consoles console_libraries /etc/prometheus/
sudo chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus
```

### 1.2 — Node Exporter (métricas de sistema)

O Node Exporter coleta métricas do SO (CPU, RAM, disco, rede). Deve ser instalado em **cada EC2** que você quer monitorar.

```bash
# No EC2 Monitoring e EC2 Backend
NODE_VERSION="1.6.1"
wget https://github.com/prometheus/node_exporter/releases/download/v${NODE_VERSION}/node_exporter-${NODE_VERSION}.linux-amd64.tar.gz

tar -xzf node_exporter-${NODE_VERSION}.linux-amd64.tar.gz
sudo cp node_exporter-${NODE_VERSION}.linux-amd64/node_exporter /usr/local/bin/
sudo useradd --no-create-home --shell /bin/false node_exporter
sudo chown node_exporter:node_exporter /usr/local/bin/node_exporter

# Cria serviço systemd
sudo tee /etc/systemd/system/node_exporter.service << 'EOF'
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable node_exporter --now
```

---

## 2️⃣ Prometheus — Configuração

> 🔴 **Atenção crítica:** Quando Prometheus é iniciado com `--web.route-prefix=/prometheus`, o endpoint de métricas próprias muda de `/metrics` para `/prometheus/metrics`. O job de self-monitoring **DEVE** declarar `metrics_path: /prometheus/metrics`, caso contrário ficará DOWN com 404.

```yaml
# /etc/prometheus/prometheus.yml

global:
  scrape_interval: 15s       # coleta a cada 15 segundos
  evaluation_interval: 15s   # avalia regras de alerta a cada 15s

scrape_configs:

  # ─── Self-monitoring do Prometheus ───────────────────────────────────
  # CRÍTICO: metrics_path deve incluir o route-prefix /prometheus
  # Sem isso, o job fica DOWN com 404 Not Found
  - job_name: 'prometheus'
    metrics_path: /prometheus/metrics
    static_configs:
      - targets: ['localhost:9090']

  # ─── Node Exporter — EC2 Monitoring (própria máquina) ────────────────
  - job_name: 'node-exporter-monitoring'
    static_configs:
      - targets: ['localhost:9100']
        labels:
          instance: 'monitoring'

  # ─── Node Exporter — EC2 Backend (IP privado) ────────────────────────
  - job_name: 'node-exporter-backend'
    static_configs:
      - targets: ['10.0.10.38:9100']   # IP privado do EC2 Backend
        labels:
          instance: 'backend'

  # ─── Aplicação TechStock (Node.js expõe /metrics via prom-client) ─────
  - job_name: 'techstock-app'
    static_configs:
      - targets: ['10.0.10.38:3000']
        labels:
          instance: 'backend-app'
```

**Validação do arquivo:**

```bash
promtool check config /etc/prometheus/prometheus.yml
```

---

## 3️⃣ Prometheus — Serviço systemd

> ⚠️ **Flags obrigatórias:** `--web.external-url=/prometheus` define o prefixo externo (para links nos alertas). `--web.route-prefix=/prometheus` faz o Prometheus responder em `/prometheus/...` em vez de `/`. Ambos são necessários para funcionar atrás do Nginx com subpath.

```bash
sudo tee /etc/systemd/system/prometheus.service << 'EOF'
[Unit]
Description=Prometheus Monitoring
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --web.external-url=/prometheus \
  --web.route-prefix=/prometheus
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable prometheus --now
```

---

## 4️⃣ Prometheus — Validação

```bash
# Verifica se está rodando
systemctl status prometheus

# Testa o endpoint de métricas (deve retornar JSON com status: success)
curl http://localhost:9090/prometheus/api/v1/query?query=up

# Ver targets pela UI (via ALB)
# http://SEU_ALB/prometheus/targets
```

**Status esperado dos targets:**

| Target | Endpoint | Status |
|---|---|---|
| prometheus | localhost:9090/prometheus/metrics | UP |
| node-exporter-monitoring | localhost:9100/metrics | UP |
| node-exporter-backend | 10.0.10.38:9100/metrics | UP |
| techstock-app | 10.0.10.38:3000/metrics | UP |

---

## 5️⃣ Nginx — Instalação e Proxy

O Nginx atua como proxy reverso: recebe requisições do ALB na porta 80 e repassa para Grafana (:3000) ou Prometheus (:9090) conforme o path.

> ℹ️ **Por que Nginx na frente?** O ALB roteia para uma única porta por Target Group. Com Nginx na porta 80, conseguimos servir dois serviços pelo mesmo Target Group, diferenciados pelo path.

```bash
sudo yum install -y nginx
```

---

## 6️⃣ Nginx — Configuração

> 🔴 **Problema comum:** O arquivo padrão `/etc/nginx/nginx.conf` no Amazon Linux 2023 inclui um bloco `server` default que conflita com o seu. Substitua o arquivo completamente em vez de apenas adicionar em `conf.d`.

```bash
# Sobrescreve o nginx.conf padrão (evita conflito com server block default)
sudo tee /etc/nginx/nginx.conf << 'EOF'
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
EOF

# Cria configuração do proxy
sudo tee /etc/nginx/conf.d/techstock-monitoring.conf << 'EOF'
server {
    listen 80;

    # Grafana — serve o sub-path /grafana/
    location /grafana/ {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    # Prometheus — serve o sub-path /prometheus/
    location /prometheus/ {
        proxy_pass http://127.0.0.1:9090;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
EOF

# Testa sintaxe e inicia
sudo nginx -t
sudo systemctl enable nginx --now
```

---

## 7️⃣ ALB — Regras de Roteamento

> 🔴 **Ordem importa:** O ALB avalia regras em ordem crescente de prioridade (menor número = maior prioridade). Se `/*` tiver prioridade menor que `/grafana*`, o frontend captura tudo.

| Prioridade | Path | Target Group | Porta TG |
|---|---|---|---|
| **1** | /grafana* | techstock-tg-monitoring | 80 |
| **2** | /prometheus* | techstock-tg-monitoring | 80 |
| **3** | /* | techstock-tg-frontend | 80 |
| Last | (default) | techstock-tg-backend | — |

O Target Group `techstock-tg-monitoring` deve apontar para o EC2 Monitoring na **porta 80** (Nginx), não 3000.

---

## 8️⃣ Grafana — Instalação

```bash
# Adiciona repositório oficial Grafana
sudo tee /etc/yum.repos.d/grafana.repo << 'EOF'
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
EOF

sudo yum install -y grafana
sudo systemctl enable grafana-server --now
```

---

## 9️⃣ Grafana — grafana.ini

> 🔴 **Três configurações obrigatórias para sub-path:** `domain`, `root_url` (com trailing slash `/grafana/`) e `serve_from_sub_path = true`. Se qualquer uma estiver errada, o Grafana entra em loop de redirect ou carrega sem CSS.

> ⚠️ **Seções duplicadas quebram o Grafana:** O arquivo INI não suporta a mesma seção múltiplas vezes. Sempre substitua o arquivo inteiro com `tee` em vez de adicionar linhas com `echo >>`.

```bash
sudo tee /etc/grafana/grafana.ini << 'EOF'
[server]
http_addr = 0.0.0.0
http_port = 3000
# domain: DNS do ALB SEM protocolo e SEM path
domain    = SEU-ALB.us-west-2.elb.amazonaws.com
# root_url: URL completa COM /grafana/ no final (trailing slash obrigatória)
root_url  = %(protocol)s://%(domain)s/grafana/
# serve_from_sub_path: DEVE ser true quando servido em sub-path
serve_from_sub_path = true

[security]
admin_user     = admin
admin_password = SUA_SENHA_AQUI
secret_key     = chave-aleatoria-aqui
allow_embedding = true
cookie_secure   = false
cookie_samesite = lax
# whitelist para datasources em localhost (Grafana 9+)
data_source_proxy_whitelist = localhost:9090 127.0.0.1:9090

[auth.anonymous]
enabled = false

[analytics]
reporting_enabled = false
check_for_updates = false

[log]
mode  = console
level = warn
EOF

sudo systemctl restart grafana-server
```

---

## 🔟 Grafana — Datasource Prometheus

> 🔴 **Grafana 13 — SSRF Protection:** Grafana 13 bloqueia datasources com URL `localhost` ou `127.0.0.1` mesmo com `data_source_proxy_whitelist` configurado. Use o URL público do ALB.

### Criação via API (recomendado — força o UID)

Dashboards que referenciam UID fixo falharão se o datasource tiver UID diferente. Use a API para forçar o UID correto.

```bash
# Deleta datasource existente (se houver)
curl -X DELETE 'http://localhost:3000/api/datasources/uid/SEU-UID-ATUAL' \
  -u 'admin:SUA_SENHA'

# Cria com UID forçado PBFA97CFB590B2093
# CRÍTICO: URL usa o ALB público, não localhost (SSRF protection Grafana 13)
curl -X POST 'http://localhost:3000/api/datasources' \
  -u 'admin:SUA_SENHA' \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "Prometheus",
    "type": "prometheus",
    "uid": "PBFA97CFB590B2093",
    "url": "http://SEU-ALB.us-west-2.elb.amazonaws.com/prometheus",
    "access": "proxy",
    "isDefault": true
  }'
```

### Verificação

```bash
# Lista datasources e confirma UID
curl -s 'http://localhost:3000/api/datasources' \
  -u 'admin:SUA_SENHA' | python3 -m json.tool | grep -E 'uid|name|url'
```

---

## 1️⃣1️⃣ Grafana — Importar Dashboards

Os 5 dashboards TechStock foram gerados com UID `PBFA97CFB590B2093` hardcoded. Importe na ordem abaixo:

| Arquivo | Foco | Importar primeiro? |
|---|---|---|
| dashboard_techstock-observability.json | Status UP/DOWN de todos os targets | ✅ Sim — diagnóstico |
| dashboard_techstock-infra-ec2.json | CPU, RAM, disco, rede dos EC2s | — |
| dashboard_techstock-api.json | Req/s, latência, heap Node.js | — |
| dashboard_techstock-rds.json | Pool de conexões, throughput PostgreSQL | — |
| dashboard_techstock-devops.json | Containers, FDs, restarts | — |

**Como importar:** Grafana → Dashboards → New → Import → Upload JSON file.

> ℹ️ Se algum dashboard mostrar "Datasource not found", confirme o UID com: `curl localhost:3000/api/datasources -u admin:senha | grep uid`. O UID deve ser exatamente `PBFA97CFB590B2093`.

---

## 📋 Variáveis Críticas de Referência

| Variável | Valor | Observação |
|---|---|---|
| ALB DNS | techstock-alb-2074710369.us-west-2.elb.amazonaws.com | Sem barra no final |
| Grafana domain | ALB DNS acima | Sem protocolo, sem path |
| Grafana root_url | %(protocol)s://%(domain)s/grafana/ | Trailing slash obrigatória |
| Prometheus port | 9090 | — |
| Grafana port | 3000 | — |
| Datasource UID | PBFA97CFB590B2093 | Hardcoded nos JSONs |
| Datasource URL | http://ALB_DNS/prometheus | Usa ALB (SSRF protection) |
| EC2 Monitoring IP | 10.0.10.59 | Subnet privada |
| EC2 Backend IP | 10.0.10.38 | Node Exporter :9100 |
| Target Group porta | 80 | Nginx, não 3000 |

---

## 🔧 Troubleshooting Rápido

| Sintoma | Causa | Fix |
|---|---|---|
| ALB abre o frontend ao acessar /grafana | Regra `/*` tem prioridade menor | Mover /grafana* e /prometheus* para prioridade 1 e 2 |
| Grafana 403 com datasource localhost | SSRF protection Grafana 9+/13 | Usar URL pública do ALB no datasource |
| Prometheus self-monitoring DOWN (404) | metrics_path padrão ignorando route-prefix | Adicionar `metrics_path: /prometheus/metrics` no job |
| Dashboard "datasource not found" | UID do datasource diferente do hardcoded | Recriar datasource via API forçando UID `PBFA97CFB590B2093` |
| Grafana loop de login | Seções duplicadas no grafana.ini | Reconstruir o arquivo com `sudo tee` |
| Nginx 502 Bad Gateway | Grafana ou Prometheus não estão rodando | `systemctl status grafana-server prometheus` |
| ALB retorna conteúdo errado | Target Group na porta 3000 em vez de 80 | Editar Target Group → porta 80 |

### Comandos de diagnóstico

```bash
# Verifica portas em uso
ss -tlnp | grep -E '80|3000|9090|9100'

# Testa Prometheus localmente
curl http://localhost:9090/prometheus/api/v1/query?query=up

# Testa Grafana localmente
curl -s http://localhost:3000/api/health

# Testa via ALB (simula requisição do cliente)
curl http://SEU_ALB/grafana/
curl http://SEU_ALB/prometheus/api/v1/query?query=up

# Logs do Grafana (filtra erros)
journalctl -u grafana-server --since "10 minutes ago" | grep -E 'error|warn' | tail -20

# Logs do Prometheus
journalctl -u prometheus -f

# Verifica datasources via API
curl -s http://localhost:3000/api/datasources -u 'admin:SENHA' | python3 -m json.tool
```
