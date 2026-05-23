-- TechStock — Schema PostgreSQL
-- Execute: psql -h <RDS_ENDPOINT> -U techstock_user -d techstock -f schema.sql

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ── Tabelas ───────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS categorias (
  id          SERIAL PRIMARY KEY,
  nome        VARCHAR(80)  NOT NULL UNIQUE,
  cor         VARCHAR(7)   NOT NULL DEFAULT '#6366f1',
  criado_em   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS produtos (
  id              SERIAL PRIMARY KEY,
  codigo          VARCHAR(30)   NOT NULL UNIQUE,
  nome            VARCHAR(120)  NOT NULL,
  descricao       TEXT,
  categoria_id    INT           REFERENCES categorias(id),
  unidade         VARCHAR(20)   NOT NULL DEFAULT 'un',
  quantidade      INT           NOT NULL DEFAULT 0 CHECK (quantidade >= 0),
  qtd_minima      INT           NOT NULL DEFAULT 5,
  preco_custo     NUMERIC(10,2) NOT NULL DEFAULT 0,
  localizacao     VARCHAR(60),
  ativo           BOOLEAN       NOT NULL DEFAULT TRUE,
  criado_em       TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  atualizado_em   TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS movimentos (
  id                  SERIAL PRIMARY KEY,
  produto_id          INT           NOT NULL REFERENCES produtos(id),
  tipo                VARCHAR(10)   NOT NULL CHECK (tipo IN ('entrada','saida','ajuste')),
  quantidade          INT           NOT NULL CHECK (quantidade > 0),
  quantidade_anterior INT           NOT NULL,
  quantidade_nova     INT           NOT NULL,
  motivo              VARCHAR(200),
  responsavel         VARCHAR(80)   NOT NULL DEFAULT 'sistema',
  criado_em           TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- ── Índices de performance — FIX #8 ──────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_produtos_categoria   ON produtos(categoria_id);
CREATE INDEX IF NOT EXISTS idx_produtos_ativo       ON produtos(ativo);
CREATE INDEX IF NOT EXISTS idx_produtos_ativo_alerta ON produtos(ativo, quantidade, qtd_minima);
CREATE INDEX IF NOT EXISTS idx_produtos_nome        ON produtos(nome);
CREATE INDEX IF NOT EXISTS idx_movimentos_produto   ON movimentos(produto_id);
CREATE INDEX IF NOT EXISTS idx_movimentos_criado_em ON movimentos(criado_em DESC);

-- ── Trigger: atualiza atualizado_em ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION set_atualizado_em()
RETURNS TRIGGER AS $$
BEGIN NEW.atualizado_em = NOW(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_produtos_updated ON produtos;
CREATE TRIGGER trg_produtos_updated
  BEFORE UPDATE ON produtos
  FOR EACH ROW EXECUTE FUNCTION set_atualizado_em();

-- ── Dados iniciais ────────────────────────────────────────────────────────────
INSERT INTO categorias (nome, cor) VALUES
  ('Informática',  '#6366f1'),
  ('Elétrico',     '#f59e0b'),
  ('Escritório',   '#10b981'),
  ('Ferramentas',  '#ef4444'),
  ('Limpeza',      '#06b6d4')
ON CONFLICT (nome) DO NOTHING;

INSERT INTO produtos (codigo,nome,descricao,categoria_id,unidade,quantidade,qtd_minima,preco_custo,localizacao) VALUES
  ('TI-001','Cabo USB-C 1m',    'Cabo dados e carga USB-C', 1,'un',  25,10, 12.50,'A1-01'),
  ('TI-002','Mouse sem fio',    'Mouse wireless 2.4GHz',    1,'un',   8, 5, 45.00,'A1-02'),
  ('TI-003','Teclado ABNT2',    'Teclado USB ABNT2',        1,'un',   3, 5, 89.00,'A1-03'),
  ('EL-001','Tomada 3 pinos',   'Tomada embutir 10A',       2,'un',  50,20,  4.80,'B2-01'),
  ('EL-002','Fita LED 5m',      'Fita LED branca 5050',     2,'rolo',12, 5, 28.00,'B2-02'),
  ('ES-001','Papel A4 500fls',  'Resma papel sulfite A4',   3,'cx',  40,15, 22.00,'C1-01'),
  ('ES-002','Caneta azul cx50', 'Caixa c/ 50 canetas',      3,'cx',   7,10, 18.50,'C1-02'),
  ('FE-001','Chave Phillips #2','Chave fenda Phillips',      4,'un',  15, 5,  8.90,'D1-01'),
  ('LI-001','Álcool 70% 1L',   'Álcool isopropílico 1L',   5,'un',  20,10,  9.50,'E1-01'),
  ('LI-002','Papel toalha cx',  'Caixa c/ 1000 folhas',     5,'cx',   4,10, 34.00,'E1-02')
ON CONFLICT (codigo) DO NOTHING;

-- ── Verificação ───────────────────────────────────────────────────────────────
SELECT 'categorias' AS tabela, COUNT(*) AS registros FROM categorias
UNION ALL
SELECT 'produtos',   COUNT(*) FROM produtos
UNION ALL
SELECT 'indexes',    COUNT(*) FROM pg_indexes WHERE tablename IN ('produtos','movimentos');
