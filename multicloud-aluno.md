# 🌐 TechStock Multi-Cloud — AWS + Azure
## Guia do Aluno

> **Atividade prática** · Nível Avançado

---

## 🎯 Cenário de Negócio

🌐 TechStock Multi-Cloud — AWS + Azure

## 🎯Cenário de Negócio

A empresa Honey Badger - uma empresa Alpha Tech Group, utiliza um sistema de gestão de estoque - TechStock, para a gestão de estoque do seu almoxarifado. Hoje, empresa opera 100% na AWS em um misto de IaaS + PaaS. O departamento de BI - Bussiness Intelligence - gerido pelo sobrinho do dono da empresa, contratou serviços na Azure - sem avisar o time de tecnlologia - para relatórios gerenciais e o time de infraestrutura - por 'sugestão' do dono, decidiu mover o monitoramento (Grafana + Prometheus) para a Azure, centralizando observabilidade + backup + relatórios no segundo cloud. A empresa Techstock fechou as portas (todo o time ganhou no bolão da Mega da Virada) e deixou somente o repositório do projeto disponível, não oferecendo mais suporte a implantações e migrações.

## Desafio
Migrar o frontend para o S3 e configurar sua comunicação com o backend;
Criar uma VPN Site-To-Site entre as clouds, sem expor dados a internet publlica;
Migrar o monitoramento para a Azure;
Conectar o Power BI ao RDS para monitoramento do estoque;

## Cronograma
Entrega parcial  - 17/06/2026;
Entrega AWS - 19/06/2026;
Entrega Final (AWS + Azure) - 22/06/2026;
Apresentação Final - 23/06/2026.

---

## 🏗️ Arquitetura inicial

```
┌─────────────────────────────────┐ 
│           AWS                   │ 
│  us-east-1                      │ 
│                                 │ 
│  EC2 ─── Frontend (HTML/JS/CSS) │ 
│                                 │ 
│  EC2 ─── Prometheus | Grafana   │
│                                 │
│  ALB ─── EC2 Backend (Node.js)  │
│               │                 │
│  VPC: 10.0.0.0/16               │ 
└─────────────────────────────────┘
---
## ✅ Checklist de Validação

```
AWS
[ ] http://ALB_DNS/api/health → {"ok":true,"database":"connected"}
[ ] http://techstock-frontend-SUACONTA.s3-website-us-east-1.amazonaws.com/ → interface TechStock
[ ] RDS acessível pelo Backend (verificar em /api/health)

VPN
[ ] AWS VPN Connection → Tunnel 1 Status: UP
[ ] Azure Connection → Status: Connected
[ ] Da VM Azure: curl http://10.0.10.X:3000/api/health → retorna JSON

Monitoramento (Azure)
[ ] http://IP_VM_AZURE:3000 → Grafana carrega
[ ] Prometheus Targets → techstock-backend: UP
[ ] Dashboard de métricas mostrando dados do backend AWS

Backup e BI (Azure)
[ ] Container rds-backups criado no Blob Storage
[ ] Arquivo .sql de exemplo uploadado
[ ] Power BI conectado ao RDS e exibindo dados de estoque
```

---

## 💬 Perguntas de Reflexão

1. **Latência:** O Grafana na Azure coleta métricas do backend na AWS atravessando a VPN. Como isso afeta o `scrape_interval`? O que acontece se a coleta demorar mais que 15 segundos?

2. **Consistência:** Se a VPN cair por 5 minutos, o que acontece com os dados no Prometheus durante esse período? Os gaps são preenchidos depois?

3. **Custo:** Compare o custo mensal de manter o VPN Gateway na AWS ($36/mês) + VPN Gateway na Azure ($140/mês) versus ter tudo na mesma cloud. Quando o multi-cloud compensa financeiramente?

4. **Segurança:** O tráfego entre as clouds está criptografado via IPSec. Mas quem pode ver os metadados (volume, origem, destino)? A VPN protege contra quais ameaças e não protege contra quais?

5. **Alternativa ao Power BI:** Quais dados do TechStock fazem sentido estar no Grafana (operacional) versus no Power BI (gerencial)? Por que usar ferramentas diferentes?

6. **Disaster Recovery:** Se toda a AWS ficasse indisponível, quais partes do sistema ainda funcionariam na Azure? O que precisaria mudar na arquitetura para ter DR real?

---

*TechStock · Atividade Multi-Cloud AWS + Azure · SENAI*
