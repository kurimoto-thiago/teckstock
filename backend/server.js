'use strict';

// Carrega .env — o EnvironmentFile do systemd já injeta as variáveis,
// mas o dotenv garante funcionamento em desenvolvimento local
const dotenvResult = require('dotenv').config();

require('express-async-errors'); // FIX #2: captura erros async em todas as rotas

const express    = require('express');
const { Pool }   = require('pg');
const cors       = require('cors');
const helmet     = require('helmet');
const promClient = require('prom-client');
const path       = require('path');
const os         = require('os');

const app  = express();
const port = process.env.PORT || 3000;

// ── Prometheus ────────────────────────────────────────────────────────────────
promClient.collectDefaultMetrics({ prefix: 'techstock_' });
const httpRequests = new promClient.Counter({
  name: 'techstock_http_requests_total',
  help: 'Total de requisições HTTP',
  labelNames: ['method', 'path', 'status'],
});

// ── CORS — FIX #1: lê CORS_ORIGIN do .env, suporta múltiplas origens ─────────
const allowedOrigins = (process.env.CORS_ORIGIN || '*')
  .split(',').map(o => o.trim()).filter(Boolean);

app.use(cors({
  origin: (origin, cb) => {
    if (!origin || allowedOrigins.includes('*') || allowedOrigins.includes(origin)) {
      return cb(null, true);
    }
    cb(new Error(`CORS: origem bloqueada — ${origin}`));
  },
  methods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],
  allowedHeaders: ['Content-Type', 'x-api-key'],
}));

// ── Segurança ─────────────────────────────────────────────────────────────────
app.use(helmet({ contentSecurityPolicy: false }));

// ── API Key (ativo somente se API_KEY estiver definida no .env) ───────────────
app.use((req, res, next) => {
  const key = process.env.API_KEY;
  if (!key) return next();
  if (req.path === '/api/health' || req.path === '/metrics') return next();
  if (req.headers['x-api-key'] !== key) {
    return res.status(401).json({ error: 'Unauthorized — x-api-key inválida' });
  }
  next();
});

// ── Contador de requisições (Prometheus) ──────────────────────────────────────
app.use((req, _res, next) => {
  _res.on('finish', () => {
    httpRequests.inc({ method: req.method, path: req.path, status: _res.statusCode });
  });
  next();
});

// ── Pool PostgreSQL ───────────────────────────────────────────────────────────
const pool = new Pool({
  host:     process.env.DB_HOST     || 'localhost',
  port:     Number(process.env.DB_PORT) || 5432,
  database: process.env.DB_NAME     || 'techstock',
  user:     process.env.DB_USER     || 'techstock_user',
  password: process.env.DB_PASSWORD || '',
  min:      Number(process.env.DB_POOL_MIN) || 1,
  max:      Number(process.env.DB_POOL_MAX) || 5,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
  // RDS exige SSL; rejectUnauthorized:false aceita o certificado auto-assinado da AWS
  ssl: process.env.DB_SSL === 'false' ? false : { rejectUnauthorized: false },
});

pool.on('error', (err) => console.error('[Pool error]', err.message));

async function q(sql, params = []) {
  const client = await pool.connect();
  try { return await client.query(sql, params); }
  finally { client.release(); }
}

// ── Middlewares ───────────────────────────────────────────────────────────────
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// ── Prometheus metrics endpoint (somente via rede interna) ────────────────────
app.get('/metrics', async (_req, res) => {
  res.set('Content-Type', promClient.register.contentType);
  res.end(await promClient.register.metrics());
});

// ── Health — FIX #4: retorna cors_origin, hostname e uptime ──────────────────
app.get('/api/health', async (req, res) => {
  try {
    const { rows } = await q('SELECT NOW() AS ts, version() AS ver');
    res.json({
      ok:          true,
      database:    'connected',  // para compatibilidade com testes
      db:          rows[0],
      cors_origin: req.headers.origin || 'direct',
      hostname:    os.hostname(),
      uptime:      Math.floor(process.uptime()),
      uptime_s:    Math.floor(process.uptime()),  // alias para compatibilidade
      env:         process.env.NODE_ENV || 'production',
    });
  } catch (e) {
    res.status(503).json({ ok: false, error: e.message });
  }
});

// ── Categorias ────────────────────────────────────────────────────────────────
app.get('/api/categorias', async (_req, res) => {
  const { rows } = await q('SELECT * FROM categorias ORDER BY nome');
  res.json(rows);
});

// ── Produtos — listagem + filtros ─────────────────────────────────────────────
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

// ── Produto — criar ───────────────────────────────────────────────────────────
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

// ── Produto — editar ──────────────────────────────────────────────────────────
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

// ── Produto — inativar ────────────────────────────────────────────────────────
app.delete('/api/produtos/:id', async (req, res) => {
  await q('UPDATE produtos SET ativo=FALSE WHERE id=$1', [req.params.id]);
  res.json({ ok: true });
});

// ── Movimento — entrada / saída / ajuste ──────────────────────────────────────
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

// ── Movimentos — histórico ────────────────────────────────────────────────────
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

// ── Dashboard stats ───────────────────────────────────────────────────────────
app.get('/api/stats', async (_req, res) => {
  const [total, alertas, valor, movHoje] = await Promise.all([
    q("SELECT COUNT(*) AS n FROM produtos WHERE ativo=TRUE"),
    q("SELECT COUNT(*) AS n FROM produtos WHERE ativo=TRUE AND quantidade <= qtd_minima"),
    q("SELECT COALESCE(SUM(quantidade * preco_custo),0) AS v FROM produtos WHERE ativo=TRUE"),
    q("SELECT COUNT(*) AS n FROM movimentos WHERE criado_em >= NOW() - INTERVAL '24 hours'"),
  ]);
  res.json({
    total_produtos:   Number(total.rows[0].n),
    alertas_estoque:  Number(alertas.rows[0].n),
    valor_total:      Number(valor.rows[0].v),
    movimentos_hoje:  Number(movHoje.rows[0].n),
  });
});

// ── Error handler global ──────────────────────────────────────────────────────
// eslint-disable-next-line no-unused-vars
app.use((err, _req, res, _next) => {
  console.error('[ERROR]', err.stack || err.message);
  res.status(err.status || 500).json({ error: err.message });
});

app.listen(port, '0.0.0.0', () => {
  console.log(`[TechStock] rodando em http://0.0.0.0:${port} | hostname: ${os.hostname()}`);
  console.log(`[TechStock] NODE_ENV=${process.env.NODE_ENV}`);
  console.log(`[TechStock] DB_HOST=${process.env.DB_HOST}`);
  console.log(`[TechStock] DB_SSL=${process.env.DB_SSL}`);
  console.log(`[TechStock] CORS_ORIGIN=${process.env.CORS_ORIGIN}`);
  if (dotenvResult.error) {
    console.warn(`[TechStock] dotenv: .env não encontrado (${dotenvResult.error.message}) — usando variáveis do ambiente/systemd`);
  } else {
    console.log('[TechStock] dotenv: .env carregado com sucesso');
  }
});
