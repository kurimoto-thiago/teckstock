'use strict';

/**
 * server.js — TechStock Backend API
 *
 * Ordem de inicialização das variáveis:
 *   1. dotenv carrega .env (contém TECHSTOCK_SECRET_NAME e AWS_REGION)
 *   2. loadSecrets() lê o secret do AWS Secrets Manager e popula process.env
 *   3. Pool PostgreSQL e demais configs usam process.env já populado
 */

const dotenvResult = require('dotenv').config();
require('express-async-errors');

const express    = require('express');
const { Pool }   = require('pg');
const cors       = require('cors');
const helmet     = require('helmet');
const promClient = require('prom-client');
const path       = require('path');
const os         = require('os');

// ── AWS Secrets Manager ───────────────────────────────────────────────────────
// Carrega variáveis sensíveis do Secrets Manager antes de qualquer uso de process.env
async function loadSecrets() {
  const secretName = process.env.TECHSTOCK_SECRET_NAME;
  const region     = process.env.AWS_REGION || 'us-east-1';

  if (!secretName) {
    console.log('[Secrets] TECHSTOCK_SECRET_NAME não definido — usando variáveis do ambiente');
    return;
  }

  try {
    const { SecretsManagerClient, GetSecretValueCommand } =
      require('@aws-sdk/client-secrets-manager');

    const client = new SecretsManagerClient({ region });
    const cmd    = new GetSecretValueCommand({ SecretId: secretName });
    const resp   = await client.send(cmd);
    const secret = JSON.parse(resp.SecretString);

    Object.entries(secret).forEach(([k, v]) => { process.env[k] = v; });
    console.log(`[Secrets] Carregado: ${secretName} (${Object.keys(secret).length} variáveis)`);
  } catch (err) {
    console.warn(`[Secrets] Falha ao ler secret: ${err.message}`);
    console.warn('[Secrets] Usando variáveis do ambiente como fallback');
  }
}

// ── Bootstrap assíncrono ──────────────────────────────────────────────────────
async function bootstrap() {

  // 1. Carrega secrets antes de qualquer uso de process.env
  await loadSecrets();

  const app  = express();
  const port = process.env.PORT || 3000;

  // ── Prometheus ──────────────────────────────────────────────────────────────
  promClient.collectDefaultMetrics({ prefix: 'techstock_' });
  const httpRequests = new promClient.Counter({
    name:       'techstock_http_requests_total',
    help:       'Total de requisições HTTP',
    labelNames: ['method', 'path', 'status'],
  });

  // ── CORS ────────────────────────────────────────────────────────────────────
  const allowedOrigins = (process.env.CORS_ORIGIN || '*')
    .split(',').map(o => o.trim()).filter(Boolean);

  app.use(cors({
    origin: (origin, cb) => {
      if (!origin || allowedOrigins.includes('*') || allowedOrigins.includes(origin)) {
        return cb(null, true);
      }
      cb(new Error(`CORS: origem bloqueada — ${origin}`));
    },
    methods:        ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],
    allowedHeaders: ['Content-Type', 'x-api-key'],
  }));

  // ── Segurança ───────────────────────────────────────────────────────────────
  app.use(helmet({ contentSecurityPolicy: false }));

  // ── API Key (opcional) ──────────────────────────────────────────────────────
  app.use((req, res, next) => {
    const key = process.env.API_KEY;
    if (!key) return next();
    if (req.path === '/api/health' || req.path === '/metrics') return next();
    if (req.headers['x-api-key'] !== key) {
      return res.status(401).json({ error: 'Unauthorized — x-api-key inválida' });
    }
    next();
  });

  // ── Contador de requisições ─────────────────────────────────────────────────
  app.use((req, _res, next) => {
    _res.on('finish', () => {
      httpRequests.inc({ method: req.method, path: req.path, status: _res.statusCode });
    });
    next();
  });

  // ── Pool PostgreSQL ─────────────────────────────────────────────────────────
  const pool = new Pool({
    host:     process.env.DB_HOST     || 'localhost',
    port:     Number(process.env.DB_PORT) || 5432,
    database: process.env.DB_NAME     || 'techstock',
    user:     process.env.DB_USER     || 'techstock_user',
    password: process.env.DB_PASSWORD || '',
    min:      Number(process.env.DB_POOL_MIN) || 1,
    max:      Number(process.env.DB_POOL_MAX) || 5,
    idleTimeoutMillis:      30000,
    connectionTimeoutMillis: 5000,
    ssl: process.env.DB_SSL === 'false' ? false : { rejectUnauthorized: false },
  });

  pool.on('error', (err) => console.error('[Pool error]', err.message));

  async function q(sql, params = []) {
    const client = await pool.connect();
    try { return await client.query(sql, params); }
    finally { client.release(); }
  }

  // ── Middlewares ─────────────────────────────────────────────────────────────
  app.use(express.json());
  app.use(express.static(path.join(__dirname, 'public')));

  // ── Métricas Prometheus ─────────────────────────────────────────────────────
  app.get('/metrics', async (_req, res) => {
    res.set('Content-Type', promClient.register.contentType);
    res.end(await promClient.register.metrics());
  });

  // ── Health ──────────────────────────────────────────────────────────────────
  app.get('/api/health', async (req, res) => {
    try {
      const { rows } = await q('SELECT NOW() AS ts, version() AS ver');
      res.json({
        ok:          true,
        database:    'connected',
        db:          rows[0],
        cors_origin: req.headers.origin || 'direct',
        hostname:    os.hostname(),
        uptime_s:    Math.floor(process.uptime()),
        uptime:      Math.floor(process.uptime()),
        env:         process.env.NODE_ENV || 'production',
        secret:      process.env.TECHSTOCK_SECRET_NAME || 'não configurado',
      });
    } catch (e) {
      res.status(503).json({ ok: false, error: e.message });
    }
  });

  // ── Categorias ──────────────────────────────────────────────────────────────
  app.get('/api/categorias', async (_req, res) => {
    const { rows } = await q('SELECT * FROM categorias ORDER BY nome');
    res.json(rows);
  });

  app.post('/api/categorias', async (req, res) => {
    const { nome, cor } = req.body;
    if (!nome) return res.status(400).json({ error: 'nome é obrigatório' });
    const { rows } = await q(
      'INSERT INTO categorias (nome, cor) VALUES ($1, $2) RETURNING *',
      [nome, cor || '#6366f1']
    );
    res.status(201).json(rows[0]);
  });

  // ── Produtos ────────────────────────────────────────────────────────────────
  app.get('/api/produtos', async (req, res) => {
    const { busca, categoria_id, alerta } = req.query;
    const params = [];
    const where  = ['p.ativo = TRUE'];

    if (busca) {
      params.push(`%${busca}%`);
      where.push(`(p.nome ILIKE $${params.length} OR p.codigo ILIKE $${params.length})`);
    }
    if (categoria_id) {
      params.push(Number(categoria_id));
      where.push(`p.categoria_id = $${params.length}`);
    }
    if (alerta === '1') {
      where.push('p.quantidade <= p.qtd_minima');
    }

    const { rows } = await q(`
      SELECT p.*, c.nome AS categoria_nome, c.cor AS categoria_cor
      FROM   produtos p
      LEFT   JOIN categorias c ON c.id = p.categoria_id
      WHERE  ${where.join(' AND ')}
      ORDER  BY p.nome
    `, params);
    res.json(rows);
  });

  app.post('/api/produtos', async (req, res) => {
    const { codigo, nome, descricao, categoria_id, unidade,
            quantidade, qtd_minima, preco_custo, localizacao } = req.body;

    if (!codigo || !nome)
      return res.status(400).json({ error: 'codigo e nome são obrigatórios' });

    const { rows } = await q(
      `INSERT INTO produtos
         (codigo,nome,descricao,categoria_id,unidade,quantidade,qtd_minima,preco_custo,localizacao)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9) RETURNING *`,
      [codigo, nome, descricao || null, categoria_id || null,
       unidade || 'un', quantidade || 0, qtd_minima || 5,
       preco_custo || 0, localizacao || null]
    );
    res.status(201).json(rows[0]);
  });

  app.put('/api/produtos/:id', async (req, res) => {
    const { nome, descricao, categoria_id, unidade,
            qtd_minima, preco_custo, localizacao } = req.body;

    const { rows } = await q(
      `UPDATE produtos SET
         nome=$1, descricao=$2, categoria_id=$3, unidade=$4,
         qtd_minima=$5, preco_custo=$6, localizacao=$7
       WHERE id=$8 AND ativo=TRUE RETURNING *`,
      [nome, descricao || null, categoria_id || null, unidade || 'un',
       qtd_minima || 5, preco_custo || 0, localizacao || null, req.params.id]
    );
    if (!rows.length) return res.status(404).json({ error: 'Produto não encontrado' });
    res.json(rows[0]);
  });

  app.delete('/api/produtos/:id', async (req, res) => {
    await q('UPDATE produtos SET ativo=FALSE WHERE id=$1', [req.params.id]);
    res.json({ ok: true });
  });

  // ── Movimentos ──────────────────────────────────────────────────────────────
  app.post('/api/movimentos', async (req, res) => {
    const { produto_id, tipo, quantidade, motivo, responsavel } = req.body;

    if (!produto_id || !tipo || !quantidade)
      return res.status(400).json({ error: 'produto_id, tipo e quantidade são obrigatórios' });

    const client = await pool.connect();
    try {
      await client.query('BEGIN');

      const { rows: [prod] } = await client.query(
        'SELECT id, quantidade FROM produtos WHERE id=$1 AND ativo=TRUE FOR UPDATE',
        [produto_id]
      );
      if (!prod) {
        await client.query('ROLLBACK');
        return res.status(404).json({ error: 'Produto não encontrado' });
      }

      let nova;
      if      (tipo === 'entrada') nova = prod.quantidade + Number(quantidade);
      else if (tipo === 'saida')   nova = prod.quantidade - Number(quantidade);
      else                         nova = Number(quantidade);

      if (nova < 0) {
        await client.query('ROLLBACK');
        return res.status(409).json({ error: 'Estoque insuficiente' });
      }

      await client.query('UPDATE produtos SET quantidade=$1 WHERE id=$2', [nova, produto_id]);

      const { rows: [mov] } = await client.query(
        `INSERT INTO movimentos
           (produto_id,tipo,quantidade,quantidade_anterior,quantidade_nova,motivo,responsavel)
         VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING *`,
        [produto_id, tipo, Number(quantidade), prod.quantidade, nova,
         motivo || null, responsavel || 'web']
      );

      await client.query('COMMIT');
      res.status(201).json({ movimento: mov, quantidade_atual: nova });
    } catch (e) {
      await client.query('ROLLBACK');
      throw e;
    } finally {
      client.release();
    }
  });

  app.get('/api/movimentos/:produto_id', async (req, res) => {
    const { rows } = await q(
      `SELECT m.*, p.nome AS produto_nome, p.codigo AS produto_codigo
       FROM   movimentos m
       JOIN   produtos p ON p.id = m.produto_id
       WHERE  m.produto_id = $1
       ORDER  BY m.criado_em DESC LIMIT 50`,
      [req.params.produto_id]
    );
    res.json(rows);
  });

  // ── Stats ───────────────────────────────────────────────────────────────────
  app.get('/api/stats', async (_req, res) => {
    const [total, alertas, valor, movHoje] = await Promise.all([
      q("SELECT COUNT(*) AS n FROM produtos WHERE ativo=TRUE"),
      q("SELECT COUNT(*) AS n FROM produtos WHERE ativo=TRUE AND quantidade <= qtd_minima"),
      q("SELECT COALESCE(SUM(quantidade * preco_custo),0) AS v FROM produtos WHERE ativo=TRUE"),
      q("SELECT COUNT(*) AS n FROM movimentos WHERE criado_em >= NOW() - INTERVAL '24 hours'"),
    ]);
    res.json({
      total_produtos:  Number(total.rows[0].n),
      alertas_estoque: Number(alertas.rows[0].n),
      valor_total:     Number(valor.rows[0].v),
      movimentos_hoje: Number(movHoje.rows[0].n),
    });
  });

  // ── Error handler ───────────────────────────────────────────────────────────
  // eslint-disable-next-line no-unused-vars
  app.use((err, _req, res, _next) => {
    console.error('[ERROR]', err.stack || err.message);
    res.status(err.status || 500).json({ error: err.message });
  });

  // ── Start ───────────────────────────────────────────────────────────────────
  app.listen(port, '0.0.0.0', () => {
    console.log(`[TechStock] rodando em http://0.0.0.0:${port} | hostname: ${os.hostname()}`);
    console.log(`[TechStock] NODE_ENV=${process.env.NODE_ENV}`);
    console.log(`[TechStock] DB_HOST=${process.env.DB_HOST}`);
    console.log(`[TechStock] DB_SSL=${process.env.DB_SSL}`);
    console.log(`[TechStock] CORS_ORIGIN=${process.env.CORS_ORIGIN}`);
    console.log(`[TechStock] SECRET=${process.env.TECHSTOCK_SECRET_NAME || 'não configurado'}`);

    if (dotenvResult.error) {
      console.warn(`[TechStock] dotenv: .env não encontrado — usando ambiente/systemd`);
    } else {
      console.log('[TechStock] dotenv: .env carregado');
    }
  });
}

// Inicia o servidor
bootstrap().catch(err => {
  console.error('[FATAL] Falha na inicialização:', err.message);
  process.exit(1);
});
