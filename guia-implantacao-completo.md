# 📦 TechStock — Guia de Implantação Completo

> Ordem de execução: VPC → RDS → Backend → Frontend → Monitoring → ALB

**Stack:** `Node.js 3000` `PostgreSQL RDS` `Nginx` `Prometheus` `Grafana` `AWS Learner Lab us-east-1`

---

## 🏗️ Arquitetura

```
Internet (HTTP:80)
    │
    ▼
ALB (SEU_ALB_DNS)
    ├── /api/*        prioridade 1 → tg-backend   (EC2 Backend :3000)
    ├── /grafana/*    prioridade 2 → tg-monitoring (EC2 Monitoring :80 → Nginx)
    ├── /prometheus/* prioridade 3 → tg-monitoring (EC2 Monitoring :80 → Nginx)
    └── /*            prioridade 4 → tg-frontend   (EC2 Frontend :80)

VPC (10.0.0.0/16)
    Subnet Pública   → NAT Gateway, ALB
    Subnet Privada   → EC2 Backend, EC2 Frontend, EC2 Monitoring, RDS PostgreSQL

EC2 Backend (subnet privada)
    ├── Node.js :3000 (TechStock API)
    ├── Node Exporter :9100
    └── CloudWatch Agent → /techstock/app

EC2 Frontend (subnet privada)
    ├── Nginx :80 (arquivos estáticos)
    ├── Node Exporter :9100
    └── CloudWatch Agent → /techstock/nginx-*

EC2 Monitoring (subnet privada)
    ├── Nginx :80
    │       ├── /grafana/    → Grafana :3000
    │       └── /prometheus/ → Prometheus :9090
    ├── Grafana :3000
    ├── Prometheus :9090
    ├── Node Exporter :9100
    └── CloudWatch Agent → TechStock/Monitoring

RDS PostgreSQL (subnet privada, SSL, porta 5432)
```

---

## 📋 Pré-requisitos AWS (Learner Lab)

| Recurso | Configuração |
|---|---|
| Região | us-east-1 |
| IAM Role | LabRole / LabInstanceProfile |
| Credenciais | vockey + AWS_SESSION_TOKEN (~4h) |
| Multi-AZ | ❌ Não suportado |
| HTTPS | ❌ Não disponível (sem ACM) |
| Storage | gp2 |
| Monitoring | MonitoringInterval=0 |

---

## ✅ Checklist Global

```
FASE 1 — Infraestrutura (Console AWS)
[ ] VPC com subnets pública e privada em 2 AZs
[ ] NAT Gateway na subnet pública
[ ] Internet Gateway associado
[ ] Security Groups criados (ver tabela abaixo)
[ ] RDS PostgreSQL provisionado
[ ] ALB criado com Target Groups

FASE 2 — Backend
[ ] EC2 Backend provisionado (subnet privada, LabInstanceProfile)
[ ] Node Exporter instalado no Backend
[ ] sudo bash setup-backend.sh
[ ] API respondendo em :3000/api/health
[ ] Registrado no Target Group tg-backend (porta 3000)

FASE 3 — Frontend
[ ] EC2 Frontend provisionado (subnet privada, LabInstanceProfile)
[ ] sudo bash setup-frontend.sh
[ ] Nginx respondendo em :80
[ ] Registrado no Target Group tg-frontend (porta 80)

FASE 4 — Monitoring
[ ] EC2 Monitoring provisionado (subnet privada, LabInstanceProfile)
[ ] sudo bash setup-monitoring.sh
[ ] Grafana e Prometheus acessíveis via ALB
[ ] Registrado no Target Group tg-monitoring (porta 80)

FASE 5 — ALB (Console AWS)
[ ] Listener HTTP:80 com as 4 regras na ordem correta
[ ] Todos os Target Groups healthy
[ ] http://ALB_DNS/ → frontend carregando
[ ] http://ALB_DNS/api/health → JSON da API
[ ] http://ALB_DNS/grafana → Grafana
[ ] http://ALB_DNS/prometheus → Prometheus
```

---

## 1️⃣ Security Groups

| SG | Inbound | Source |
|---|---|---|
| sg-alb | 80 | 0.0.0.0/0 |
| sg-backend | 3000 | sg-alb, sg-monitoring |
| sg-backend | 9100 | sg-monitoring |
| sg-frontend | 80 | sg-alb |
| sg-frontend | 9100 | sg-monitoring |
| sg-monitoring | 80 | sg-alb |
| sg-monitoring | 9090, 9100 | sg-monitoring |
| sg-rds | 5432 | sg-backend |

Todos os SGs: outbound 0.0.0.0/0 liberado.

> 🔴 **Crítico:** SG do Backend deve liberar porta 3000 e 9100 para o SG do Monitoring. Sem isso, os targets do Prometheus ficam DOWN.

---

## 2️⃣ RDS PostgreSQL

**Console AWS → RDS → Create database:**

| Campo | Valor |
|---|---|
| Engine | PostgreSQL 15 |
| Template | Free tier |
| DB identifier | techstock-db |
| Master username | techstock_user |
| Master password | (anote — será pedido no script do backend) |
| Instance class | db.t3.micro |
| Storage | gp2, 20 GB |
| Multi-AZ | Desabilitado |
| VPC | VPC TechStock |
| Subnet group | Subnets privadas |
| Public access | No |
| SG | sg-rds |
| Database name | techstock |

Aguarde status **Available** antes de continuar. Copie o **Endpoint**.

---

## 3️⃣ ALB + Target Groups

### Target Groups

| Nome | Tipo | Porta | Health check |
|---|---|---|---|
| tg-backend | Instance | 3000 | /api/health |
| tg-frontend | Instance | 80 | /health |
| tg-monitoring | Instance | 80 | /grafana/api/health |

### ALB

- Scheme: internet-facing
- Listeners: HTTP:80
- Subnets: **públicas** (mínimo 2 AZs)
- SG: sg-alb

### Listener Rules HTTP:80

> 🔴 Ordem obrigatória — ALB avalia da menor para a maior prioridade.

| Prioridade | Condição | Target Group |
|---|---|---|
| **1** | Path `/api*` | tg-backend |
| **2** | Path `/grafana*` | tg-monitoring |
| **3** | Path `/prometheus*` | tg-monitoring |
| **4** | Path `/*` | tg-frontend |
| Last | Default | tg-backend |

---

## 4️⃣ EC2 Backend

### Provisionamento

| Campo | Valor |
|---|---|
| AMI | Amazon Linux 2023 |
| Instance type | t3.micro |
| Subnet | Privada |
| IAM profile | LabInstanceProfile |
| SG | sg-backend |
| User data | (opcional — pode deixar em branco) |

### Execução do script

```bash
# Via SSM Session Manager
sudo bash setup-backend.sh
```

**Dados solicitados pelo script:**

| Prompt | Valor | Onde encontrar |
|---|---|---|
| Endpoint RDS | techstock-db.xxxx.rds.amazonaws.com | RDS → Databases → Endpoint |
| DB_PASSWORD | (senha criada no RDS) | Anotado no passo anterior |
| DNS do ALB | techstock-alb-xxx.us-east-1.elb.amazonaws.com | EC2 → Load Balancers → DNS name |
| S3 Bucket | (opcional) | S3 → bucket/prefixo |

### O que o script faz

1. Instala Node.js, npm, postgresql15
2. Cria usuário `techstock` e diretório `/opt/techstock`
3. Copia arquivos do S3 ou aguarda upload manual
4. `npm install --omit=dev`
5. Cria `/opt/techstock/.env` com permissão 640
6. Executa `schema.sql` no RDS
7. Cria serviço systemd com `EnvironmentFile`
8. Instala Node Exporter :9100 e CloudWatch Agent

### Correções aplicadas

- `.env` com `chown` antes do `chown -R` geral (garante permissões corretas)
- `EnvironmentFile` no systemd (variáveis disponíveis mesmo se dotenv falhar)
- `sudo -u techstock` valida leitura do `.env` antes de continuar

### Validação

```bash
curl -s http://localhost:3000/api/health | python3 -m json.tool
sudo journalctl -u techstock -f
```

---

## 5️⃣ EC2 Frontend

### Provisionamento

| Campo | Valor |
|---|---|
| AMI | Amazon Linux 2023 |
| Instance type | t3.micro |
| Subnet | Privada |
| IAM profile | LabInstanceProfile |
| SG | sg-frontend |

### Execução do script

```bash
sudo bash setup-frontend.sh
```

**Dados solicitados pelo script:**

| Prompt | Valor |
|---|---|
| DNS do ALB | techstock-alb-xxx.us-east-1.elb.amazonaws.com |
| S3 Bucket | (opcional) bucket/prefixo com index.html, style.css, app.js, config.js |

### O que o script faz

1. Instala Nginx
2. Substitui `nginx.conf` padrão (remove server block default do AL2023)
3. Cria `/usr/share/nginx/html/techstock/`
4. Copia arquivos do S3 ou aguarda upload manual
5. Gera `config.js` com `apiUrl` do ALB
6. Configura `conf.d/techstock.conf` com cache-control e health check
7. `systemctl restart nginx` (não `start`)
8. Instala Node Exporter :9100 e CloudWatch Agent

### Correções aplicadas

- `nginx.conf` substituído inteiro (conflito com AL2023)
- `chown/chmod` imediatamente após criação dos diretórios
- `restart` em vez de `start`
- `config.js` gerado com `no-store, no-cache` (URL do ALB pode mudar)

### Validação

```bash
curl -s http://localhost/health
curl -s http://localhost/config.js
nginx -t
```

### Atualizar config.js (quando ALB mudar)

```bash
# Opção 1 — editar manualmente
sudo nano /usr/share/nginx/html/techstock/config.js

# Opção 2 — executar o script novamente
sudo bash setup-frontend.sh
```

---

## 6️⃣ EC2 Monitoring

### Provisionamento

| Campo | Valor |
|---|---|
| AMI | Amazon Linux 2023 |
| Instance type | t3.micro |
| Subnet | Privada |
| IAM profile | LabInstanceProfile |
| SG | sg-monitoring |

### Execução do script

```bash
sudo bash setup-monitoring.sh
```

**Dados solicitados pelo script:**

| Prompt | Valor |
|---|---|
| DNS do ALB | techstock-alb-xxx.us-east-1.elb.amazonaws.com |
| IP privado do Backend | 10.0.10.X (EC2 Backend → Private IPv4) |
| Senha Grafana | (Enter para usar TechStock@2024) |

### O que o script faz

1. Instala Node Exporter :9100
2. Instala Prometheus :9090 com `--web.route-prefix=/prometheus`
3. Gera `prometheus.yml` com `metrics_path: /prometheus/metrics` no job self-monitoring
4. Instala e configura Nginx como proxy (porta 80 → Grafana :3000 e Prometheus :9090)
5. Instala Grafana com `grafana.ini` configurado para sub-path `/grafana/`
6. Reset de senha via `grafana-cli --configOverrides cfg:default.paths.data=/var/lib/grafana`
7. Cria datasource via API com UID `PBFA97CFB590B2093` e URL do ALB (SSRF Grafana 13)
8. Importa dashboards da comunidade (Node Exporter Full, Node.js App, Prometheus Stats)
9. Instala CloudWatch Agent

### Correções críticas aplicadas

| Problema | Fix |
|---|---|
| Nginx ausente | Incluído na seção 3 do script |
| Self-monitoring DOWN | `metrics_path: /prometheus/metrics` no prometheus.yml |
| Grafana 13 SSRF | Datasource usa URL do ALB, não localhost |
| UID errado | Recria datasource com UID `PBFA97CFB590B2093` |
| Loop de login | `cookie_secure=false`, `cookie_samesite=lax` no grafana.ini |
| grafana-cli banco errado | `--configOverrides cfg:default.paths.data=/var/lib/grafana` |
| Target Group porta 3000 | Deve ser porta 80 (Nginx) |
| Prioridade ALB | `/grafana*` e `/prometheus*` antes de `/*` |
| Dashboard sem dados | UID do datasource hardcoded nos JSONs TechStock |

### Validação

```bash
curl -s http://localhost/grafana/api/health -u 'admin:TechStock@2024'
curl -s http://localhost:9090/prometheus/api/v1/query?query=up
sudo promtool check config /etc/prometheus/prometheus.yml
```

### Dashboards customizados TechStock (importação manual)

**Grafana → Dashboards → New → Import → Upload JSON**

| Arquivo | Foco |
|---|---|
| dashboard_techstock-observability.json | Status UP/DOWN de todos os targets |
| dashboard_techstock-infra-ec2.json | CPU, RAM, disco, rede |
| dashboard_techstock-api.json | Req/s, latência, heap Node.js |
| dashboard_techstock-rds.json | Pool de conexões PostgreSQL |
| dashboard_techstock-devops.json | Containers, FDs, restarts |

---

## 7️⃣ Aplicação Frontend (index.html + app.js)

### Deploy dos arquivos

```bash
# Via SSM no EC2 Frontend
sudo cp index.html /usr/share/nginx/html/techstock/index.html
sudo cp app.js     /usr/share/nginx/html/techstock/app.js
sudo chown nginx:nginx /usr/share/nginx/html/techstock/*.html
sudo chown nginx:nginx /usr/share/nginx/html/techstock/*.js
```

### Funcionalidades

| Seção | Descrição |
|---|---|
| Dashboard | Cards de totais, banner de alertas, tabela de itens críticos |
| Produtos | CRUD completo, busca por nome/código, filtro por categoria |
| Movimentações | Histórico de todas as movimentações, filtro por tipo/produto, nova movimentação |
| Alertas | Produtos abaixo do mínimo com botão de reposição |
| ⚙ Config | URLs de API, Grafana, Prometheus; teste de conectividade |

### Correções aplicadas

| Bug | Fix |
|---|---|
| Modais (config, histórico) fechavam ao clicar fora | `MODAL_NO_OUTSIDE_CLOSE` protege `ov-cfg` e `ov-hist` |
| Edição de quantidade não salvava | Campo `p-qty` readonly em edição + hint para usar movimentação |
| Aba Movimentações vazia | `_fetchMovs` usa `/api/movimentos/:id` em paralelo (rota `/api/movimentos` não existe) |
| Nome do produto ausente nas movimentações | Resolvido via `_prodCache` quando API não retorna `produto_nome` |

---

## 📋 Variáveis de Referência

| Variável | Exemplo | Observação |
|---|---|---|
| ALB_DNS | techstock-alb-XXX.us-east-1.elb.amazonaws.com | Sem http://, sem barra |
| DB_HOST | techstock-db.xxxx.us-east-1.rds.amazonaws.com | Endpoint do RDS |
| DB_NAME | techstock | Fixo |
| DB_USER | techstock_user | Fixo |
| CORS_ORIGIN | http://ALB_DNS | Com http://, sem barra |
| Grafana domain | ALB_DNS | Sem protocolo |
| Grafana root_url | %(protocol)s://%(domain)s/grafana/ | Trailing slash obrigatória |
| Datasource UID | PBFA97CFB590B2093 | Hardcoded nos JSONs |
| Datasource URL | http://ALB_DNS/prometheus | Via ALB (SSRF Grafana 13) |
| tg-backend porta | 3000 | Node.js direto |
| tg-frontend porta | 80 | Nginx |
| tg-monitoring porta | 80 | Nginx proxy |

---

## 🔧 Troubleshooting Rápido

| Sintoma | Causa provável | Fix |
|---|---|---|
| Frontend retorna HTML no `/api/*` | Prioridade ALB errada | `/api*` → prioridade 1 |
| 503 no /grafana ou /prometheus | Nginx inativo no Monitoring | `sudo systemctl start nginx` |
| 504 Gateway Timeout | EC2 desligado ou Target Group unhealthy | Verificar instâncias e TG |
| API retorna HTML em vez de JSON | ALB roteando para frontend | Verificar regra /api* |
| Grafana 403 no datasource | SSRF protection Grafana 13 | Usar URL do ALB no datasource |
| Prometheus self-monitoring DOWN | `metrics_path` ausente | Adicionar no prometheus.yml |
| Dashboard "datasource not found" | UID divergente | Recriar datasource com UID fixo |
| Frontend sem dados (JSON parse error) | config.js com URL errada | Regenerar config.js com ALB correto |
| Movimentações não carregam | Rota `/api/movimentos` não existe | app.js usa `/api/movimentos/:id` |
| Edição de produto não salva qtd | Backend ignora quantidade no PUT | Usar movimentação para alterar estoque |
| Node Exporter DOWN no Prometheus | SG do Backend não libera 9100 | Adicionar regra inbound 9100 para sg-monitoring |
| Techstock app DOWN no Prometheus | SG do Backend não libera 3000 | Adicionar regra inbound 3000 para sg-monitoring |

### Diagnóstico por componente

```bash
# Backend
sudo journalctl -u techstock -f
curl -s http://localhost:3000/api/health

# Frontend
sudo nginx -t
sudo journalctl -u nginx -f
curl -s http://localhost/health

# Monitoring
for svc in prometheus grafana-server nginx node_exporter; do
  echo "$svc: $(systemctl is-active $svc)"
done
curl -s http://localhost:9090/prometheus/api/v1/query?query=up
curl -s http://localhost:3000/grafana/api/health -u 'admin:TechStock@2024'

# Verificar datasource Grafana
curl -s http://localhost:3000/grafana/api/datasources \
  -u 'admin:TechStock@2024' | python3 -m json.tool | grep -E '"uid"|"url"'
```
