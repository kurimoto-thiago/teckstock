const { Pool } = require('pg');
const testPool = new Pool({
  host:     process.env.DB_HOST     || 'localhost',
  port:     parseInt(process.env.DB_PORT || '5432'),
  database: process.env.DB_NAME     || 'techstock_test',
  user:     process.env.DB_USER     || 'techstock_user',
  password: process.env.DB_PASSWORD || 'test_password',
  ssl:      process.env.DB_SSL === 'true' ? { rejectUnauthorized: false } : false,
  max: 3,
});

async function setupDatabase() {
  await testPool.query(`
    DROP TABLE IF EXISTS movimentos CASCADE;
    DROP TABLE IF EXISTS produtos CASCADE;
    DROP TABLE IF EXISTS categorias CASCADE;
    CREATE TABLE categorias (
      id SERIAL PRIMARY KEY, nome VARCHAR(80) NOT NULL UNIQUE,
      cor VARCHAR(7) NOT NULL DEFAULT '#6366f1', criado_em TIMESTAMPTZ DEFAULT NOW()
    );
    CREATE TABLE produtos (
      id SERIAL PRIMARY KEY, codigo VARCHAR(30) NOT NULL UNIQUE,
      nome VARCHAR(120) NOT NULL, descricao TEXT, categoria_id INT REFERENCES categorias(id),
      unidade VARCHAR(20) NOT NULL DEFAULT 'un',
      quantidade INT NOT NULL DEFAULT 0 CHECK (quantidade >= 0),
      qtd_minima INT NOT NULL DEFAULT 5,
      preco_custo NUMERIC(10,2) NOT NULL DEFAULT 0,
      localizacao VARCHAR(60), ativo BOOLEAN NOT NULL DEFAULT TRUE,
      criado_em TIMESTAMPTZ DEFAULT NOW(), atualizado_em TIMESTAMPTZ DEFAULT NOW()
    );
    CREATE TABLE movimentos (
      id SERIAL PRIMARY KEY, produto_id INT NOT NULL REFERENCES produtos(id),
      tipo VARCHAR(10) NOT NULL CHECK (tipo IN ('entrada','saida','ajuste')),
      quantidade INT NOT NULL CHECK (quantidade > 0),
      quantidade_anterior INT NOT NULL, quantidade_nova INT NOT NULL,
      motivo VARCHAR(200), responsavel VARCHAR(80) NOT NULL DEFAULT 'sistema',
      criado_em TIMESTAMPTZ DEFAULT NOW()
    );
  `);
}
async function teardownDatabase() { await testPool.end(); }
module.exports = { testPool, setupDatabase, teardownDatabase };
