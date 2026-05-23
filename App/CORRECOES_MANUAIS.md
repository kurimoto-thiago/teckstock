# TechStock — Correções Manuais Necessárias

## 1. Variáveis obrigatórias nos scripts de setup

Antes de executar qualquer script, substitua os placeholders abaixo.

### `setup-backend.sh`
```
DB_HOST="COLE_O_ENDPOINT_DO_RDS_AQUI"
```
→ Substitua pelo endpoint do RDS:
  Console AWS → RDS → Databases → techstock-db → Endpoint

```
CORS_ORIGIN="http://COLE_O_DNS_DO_ALB_AQUI"
```
→ Substitua pelo DNS do ALB:
  Console AWS → EC2 → Load Balancers → techstock-alb → DNS name

```
DB_PASSWORD="SenhaForte@2024!"
```
→ Troque por uma senha forte antes de usar em produção.

---

### `setup-frontend-ec2.sh`
```
ALB_DNS="COLE_O_DNS_DO_ALB_AQUI"
```
→ Mesmo DNS do ALB acima (sem `http://`).

---

### `setup-monitoring.sh`
```
BACKEND_PRIVATE_IP="COLE_O_IP_PRIVADO_DO_EC2_BACKEND_AQUI"
```
→ Console AWS → EC2 → Instances → techstock-backend → Private IPv4

```
ALB_DNS="COLE_O_DNS_DO_ALB_AQUI"
```
→ Mesmo DNS do ALB acima.

---

### `ecs-task-definitions.sh`
Variáveis obrigatórias como env vars antes de executar:
```bash
export RDS_ENDPOINT="techstock-db.xxxx.us-east-1.rds.amazonaws.com"
export ALB_DNS="techstock-alb-xxxx.us-east-1.elb.amazonaws.com"
export VPC_ID="vpc-xxxxxxxx"
export PRIV_A="subnet-xxxxxxxx"
export PRIV_B="subnet-yyyyyyyy"
export SG_BACKEND="sg-xxxxxxxx"
export SG_FRONTEND="sg-yyyyyyyy"
export TG_BACKEND="arn:aws:elasticloadbalancing:us-east-1:ACCOUNT:targetgroup/..."
export TG_FRONTEND="arn:aws:elasticloadbalancing:us-east-1:ACCOUNT:targetgroup/..."
export DB_PASSWORD="SuaSenhaForte"
```

---

## 2. `secret.yaml` — CORS_ORIGIN

O valor atual é placeholder base64 de `"http://SEU_ALB_DNS"`.

Gere o valor correto:
```bash
echo -n "http://SEU-ALB.us-east-1.elb.amazonaws.com" | base64
```
Substitua em `secret.yaml`:
```yaml
CORS_ORIGIN: <resultado_do_comando_acima>
```

---

## 3. `prometheus.yml` — IP do backend

Substitua `BACKEND_PRIVATE_IP` pelo IP privado real do EC2 Backend:
```yaml
- targets: ['10.0.10.XX:3000']   # backend app
- targets: ['10.0.10.XX:9100']   # node_exporter
```

---

## 4. `config.js` — URL do frontend

Preencha o DNS do ALB:
```js
window.TECHSTOCK_CONFIG = {
  apiUrl: 'http://SEU-ALB.us-east-1.elb.amazonaws.com'
};
```

---

## 5. Prometheus — como acessar no browser

**IMPORTANTE:** Com `--web.route-prefix=/prometheus`, o Prometheus não responde em `/`.

Acesse sempre:
```
http://IP-DA-EC2-MONITORING:9090/prometheus
```

Via ALB (se configurado listener /prometheus):
```
http://ALB_DNS/prometheus
```

**Nunca** acesse `http://IP:9090` diretamente — retorna 404.

---

## 6. Grafana — reimportar dashboards após reinstalação

Se reinstalar o Grafana do zero, o datasource `prometheus-techstock` pode não existir ainda quando os dashboards tentarem carregar. Execute:

```bash
# Na EC2 Monitoring, após o Grafana subir:
curl -s -u admin:TechStock@2024 \
  http://localhost:3000/grafana/api/datasources \
  | python3 -c "import sys,json; [print(d['uid'],d['name']) for d in json.load(sys.stdin)]"
```

O UID deve aparecer como `prometheus-techstock`. Se não aparecer, force o reload do provisioning:
```bash
sudo systemctl restart grafana-server
sleep 10
# Verifique novamente
```

---

## 7. Importar dashboards personalizados no Grafana

Os 5 arquivos `dashboard_techstock-*.json` não são importados automaticamente pelo script.

Importe manualmente via API (na EC2 Monitoring após setup):
```bash
for f in dashboard_techstock-api.json dashboard_techstock-rds.json \
          dashboard_techstock-devops.json dashboard_techstock-infra-ec2.json \
          dashboard_techstock-observability.json; do
  echo "Importando $f..."
  curl -s -u admin:TechStock@2024 \
    -H "Content-Type: application/json" \
    -d @"$f" \
    http://localhost:3000/grafana/api/dashboards/db
  echo ""
done
```

Ou via UI: Grafana → Dashboards → Import → Upload JSON file.

---

## 8. Senha padrão do Grafana

A senha `TechStock@2024` está em texto claro em `setup-monitoring.sh`.

Troque após o primeiro login:
- Grafana UI → Profile → Change Password
- Ou via API:
```bash
curl -X PUT -u admin:TechStock@2024 \
  -H "Content-Type: application/json" \
  -d '{"oldPassword":"TechStock@2024","newPassword":"NovaSenh@Forte","confirmNew":"NovaSenh@Forte"}' \
  http://localhost:3000/grafana/api/user/password
```
Atualize também em `setup-monitoring.sh` (variável `GRAFANA_PASSWORD`) para futuras execuções.

---

## Resumo das correções automáticas já aplicadas

| Arquivo | Correção |
|---|---|
| `server.js` | Removida chave `uptime` duplicada; adicionado `POST /api/categorias` |
| `grafana-datasources.yml` | UID fixo `prometheus-techstock` adicionado |
| `setup-monitoring.sh` | Removido `--web.external-url=/prometheus` (causava redirect quebrado); UID `prometheus-techstock` no datasource |
| `prometheus.yml` | Removido `metrics_path: /prometheus/metrics` desnecessário |
| `dashboard_techstock-*.json` (5 arquivos) | UID `PBFA97CFB590B2093` → `prometheus-techstock` |
| `api.test.js` | Removida coluna `prefixo` inexistente; corrigidos testes de categorias |
