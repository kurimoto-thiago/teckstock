TechStock — Arquivos da Aplicação
Gerado em: 22/05/2026

ESTRUTURA:
  frontend/
    index.html   — HTML principal da interface (versão 30/04/2026, 36KB)
    app.js       — Lógica do frontend com bugs corrigidos (04/05/2026, 26KB)
    style.css    — Estilos da interface (08/05/2026, 8.6KB)

  backend/
    server.js    — API Node.js com os 8 bugs corrigidos (08/05/2026, 13KB)
    schema.sql   — Schema do banco PostgreSQL (04/05/2026)
    package.json — Dependências Node.js
    .env.example — Variáveis de ambiente necessárias

DEPLOY:
  Backend  → /opt/techstock/
  Frontend → S3 bucket ou /usr/share/nginx/html/

VARIÁVEIS (.env):
  DB_HOST     = endpoint do RDS
  DB_PORT     = 5432
  DB_NAME     = techstock
  DB_USER     = techstock_user
  DB_PASSWORD = SenhaForte@2024!
  DB_SSL      = true
  PORT        = 3000
  NODE_ENV    = production
  CORS_ORIGIN = http://ALB_DNS
  AWS_REGION  = us-east-1
