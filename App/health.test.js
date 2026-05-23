/**
 * __tests__/health.test.js
 * Testa o endpoint /api/health — primeiro sinal de vida do sistema
 */
const request = require('supertest');
const { setupDatabase, teardownDatabase } = require('./setup');

// Importa o app sem iniciar o servidor (supertest faz isso internamente)
let app;

beforeAll(async () => {
  await setupDatabase();
  // Configura variáveis de ambiente ANTES de importar o app
  process.env.DB_NAME = process.env.DB_NAME || 'techstock_test';
  process.env.DB_SSL  = 'false';
  app = require('../server');
});

afterAll(async () => {
  await teardownDatabase();
  // Fecha o pool do app para evitar hanging de Jest
  if (app.locals && app.locals.pool) {
    await app.locals.pool.end();
  }
});

describe('GET /api/health', () => {

  test('retorna 200 com status ok', async () => {
    const res = await request(app).get('/api/health');
    expect(res.status).toBe(200);
    expect(res.body.ok).toBe(true);
  });

  test('inclui timestamp válido', async () => {
    const res = await request(app).get('/api/health');
    expect(res.body.timestamp).toBeDefined();
    expect(new Date(res.body.timestamp).getTime()).not.toBeNaN();
  });

  test('inclui status do banco de dados', async () => {
    const res = await request(app).get('/api/health');
    expect(res.body.database).toBeDefined();
    // Em ambiente de teste com banco real: connected
    // Em ambiente sem banco: o campo existe mas pode ser 'error'
    expect(['connected', 'error']).toContain(res.body.database);
  });

  test('inclui hostname da instância', async () => {
    const res = await request(app).get('/api/health');
    expect(res.body.hostname).toBeDefined();
    expect(typeof res.body.hostname).toBe('string');
    expect(res.body.hostname.length).toBeGreaterThan(0);
  });

  test('inclui uptime positivo', async () => {
    const res = await request(app).get('/api/health');
    // server retorna uptime_s (e também uptime como alias)
    expect(res.body.uptime_s ?? res.body.uptime).toBeGreaterThan(0);
  });

  test('retorna Content-Type JSON', async () => {
    const res = await request(app).get('/api/health');
    expect(res.headers['content-type']).toMatch(/application\/json/);
  });
});

describe('GET /metrics (Prometheus)', () => {

  test('retorna 200', async () => {
    const res = await request(app).get('/metrics');
    expect(res.status).toBe(200);
  });

  test('retorna formato Prometheus (text/plain)', async () => {
    const res = await request(app).get('/metrics');
    expect(res.headers['content-type']).toMatch(/text\/plain/);
  });

  test('contém métricas padrão do Node.js', async () => {
    const res = await request(app).get('/metrics');
    // prom-client coleta métricas padrão com prefixo configurado
    expect(res.text).toMatch(/nodejs_heap_size_total_bytes|techstock_nodejs/);
  });
});
