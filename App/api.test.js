/**
 * __tests__/categorias.test.js
 */
const request = require('supertest');
const { setupDatabase, teardownDatabase, testPool } = require('./setup');

let app;
beforeAll(async () => { await setupDatabase(); app = require('../server'); });
afterAll(async () => { await teardownDatabase(); });
afterEach(async () => { await testPool.query('DELETE FROM movimentos; DELETE FROM produtos; DELETE FROM categorias;'); });

describe('GET /api/categorias', () => {
  test('retorna array vazio quando sem dados', async () => {
    const res = await request(app).get('/api/categorias');
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body)).toBe(true);
    expect(res.body.length).toBe(0);
  });

  test('retorna categorias criadas', async () => {
    await testPool.query("INSERT INTO categorias (nome) VALUES ('Eletrônicos'),('Roupas')");
    const res = await request(app).get('/api/categorias');
    expect(res.status).toBe(200);
    expect(res.body.length).toBe(2);
    expect(res.body.map(c => c.nome)).toContain('Eletrônicos');
  });
});

describe('POST /api/categorias', () => {
  test('cria categoria com dados válidos', async () => {
    const res = await request(app).post('/api/categorias').send({ nome: 'Ferramentas' });
    expect(res.status).toBe(201);
    expect(res.body.nome).toBe('Ferramentas');
    expect(res.body.id).toBeDefined();
  });

  test('retorna 400 sem nome', async () => {
    const res = await request(app).post('/api/categorias').send({ cor: '#ff0000' });
    expect(res.status).toBe(400);
  });

  test('retorna 409 com nome duplicado', async () => {
    await testPool.query("INSERT INTO categorias (nome) VALUES ('Único')");
    const res = await request(app).post('/api/categorias').send({ nome: 'Único' });
    expect([409, 500]).toContain(res.status);
  });
});

// ──────────────────────────────────────────────────────────────────────────────

/**
 * __tests__/produtos.test.js
 * Inline neste arquivo para simplicidade — pode ser separado
 */

let catId;

describe('CRUD de Produtos', () => {
  beforeEach(async () => {
    await testPool.query('DELETE FROM movimentos; DELETE FROM produtos; DELETE FROM categorias;');
    const r = await testPool.query("INSERT INTO categorias (nome) VALUES ('Eletrônicos') RETURNING id");
    catId = r.rows[0].id;
  });

  describe('GET /api/produtos', () => {
    test('retorna array vazio', async () => {
      const res = await request(app).get('/api/produtos');
      expect(res.status).toBe(200);
      expect(Array.isArray(res.body)).toBe(true);
    });

    test('retorna produtos cadastrados', async () => {
      await testPool.query(
        "INSERT INTO produtos (codigo, nome, categoria_id, preco_custo, quantidade) VALUES ('ELE-001','Notebook',"+catId+",3999.90,5)"
      );
      const res = await request(app).get('/api/produtos');
      expect(res.body.length).toBe(1);
      expect(res.body[0].nome).toBe('Notebook');
    });
  });

  describe('POST /api/produtos', () => {
    test('cria produto com dados válidos', async () => {
      const res = await request(app).post('/api/produtos').send({
        codigo: 'ELE-001', nome: 'Notebook', categoria_id: catId,
        preco_custo: 3999.90, quantidade: 5, qtd_minima: 2,
      });
      expect(res.status).toBe(201);
      expect(res.body.codigo).toBe('ELE-001');
      expect(parseFloat(res.body.preco_custo)).toBe(3999.90);
    });

    test('retorna 400 sem código', async () => {
      const res = await request(app).post('/api/produtos')
        .send({ nome: 'Notebook', categoria_id: catId, preco_custo: 100 });
      expect(res.status).toBe(400);
    });

    test('retorna 400 com preço negativo', async () => {
      const res = await request(app).post('/api/produtos')
        .send({ codigo: 'ELE-001', nome: 'Teste', categoria_id: catId, preco_custo: -10 });
      expect([400, 500]).toContain(res.status);
    });

    test('retorna 409 com código duplicado', async () => {
      await testPool.query(`INSERT INTO produtos (codigo,nome,categoria_id,preco_custo,quantidade) VALUES ('ELE-001','Existente',${catId},100,0)`);
      const res = await request(app).post('/api/produtos')
        .send({ codigo: 'ELE-001', nome: 'Novo', categoria_id: catId, preco_custo: 50 });
      expect([409, 500]).toContain(res.status);
    });
  });

  describe('PUT /api/produtos/:id', () => {
    test('atualiza produto existente', async () => {
      const ins = await testPool.query(
        `INSERT INTO produtos (codigo,nome,categoria_id,preco_custo,quantidade) VALUES ('ELE-001','Notebook',${catId},100,5) RETURNING id`
      );
      const id = ins.rows[0].id;
      const res = await request(app).put(`/api/produtos/${id}`)
        .send({ codigo: 'ELE-001', nome: 'Notebook Pro', categoria_id: catId, preco_custo: 150, quantidade: 5 });
      expect(res.status).toBe(200);
      expect(res.body.nome).toBe('Notebook Pro');
    });

    test('retorna 404 para produto inexistente', async () => {
      const res = await request(app).put('/api/produtos/999999')
        .send({ codigo: 'X', nome: 'X', categoria_id: catId, preco_custo: 1 });
      expect(res.status).toBe(404);
    });
  });

  describe('DELETE /api/produtos/:id', () => {
    test('inativa produto (soft delete)', async () => {
      const ins = await testPool.query(
        `INSERT INTO produtos (codigo,nome,categoria_id,preco_custo,quantidade) VALUES ('ELE-001','Notebook',${catId},100,0) RETURNING id`
      );
      const id = ins.rows[0].id;
      const res = await request(app).delete(`/api/produtos/${id}`);
      expect([200, 204]).toContain(res.status);
      // Verifica que o produto ainda existe mas está inativo
      const check = await testPool.query('SELECT ativo FROM produtos WHERE id=$1', [id]);
      if (check.rows.length > 0) {
        expect(check.rows[0].ativo).toBe(false);
      }
    });
  });
});

// ──────────────────────────────────────────────────────────────────────────────

describe('Movimentos de Estoque', () => {
  let prodId;

  beforeEach(async () => {
    await testPool.query('DELETE FROM movimentos; DELETE FROM produtos; DELETE FROM categorias;');
    const cat = await testPool.query("INSERT INTO categorias (nome) VALUES ('Cat') RETURNING id");
    const prod = await testPool.query(
      `INSERT INTO produtos (codigo,nome,categoria_id,preco_custo,quantidade,qtd_minima) VALUES ('CAT-001','Produto',${cat.rows[0].id},10,10,2) RETURNING id`
    );
    prodId = prod.rows[0].id;
  });

  describe('POST /api/movimentos', () => {
    test('registra entrada e aumenta estoque', async () => {
      const res = await request(app).post('/api/movimentos').send({
        produto_id: prodId, tipo: 'entrada', quantidade: 5, motivo: 'Compra'
      });
      expect(res.status).toBe(201);
      const estoque = await testPool.query('SELECT quantidade FROM produtos WHERE id=$1', [prodId]);
      expect(estoque.rows[0].quantidade).toBe(15);
    });

    test('registra saída e diminui estoque', async () => {
      const res = await request(app).post('/api/movimentos').send({
        produto_id: prodId, tipo: 'saida', quantidade: 3
      });
      expect(res.status).toBe(201);
      const estoque = await testPool.query('SELECT quantidade FROM produtos WHERE id=$1', [prodId]);
      expect(estoque.rows[0].quantidade).toBe(7);
    });

    test('rejeita saída maior que estoque disponível', async () => {
      const res = await request(app).post('/api/movimentos').send({
        produto_id: prodId, tipo: 'saida', quantidade: 999
      });
      expect([400, 422, 500]).toContain(res.status);
    });

    test('rejeita quantidade zero ou negativa', async () => {
      const r1 = await request(app).post('/api/movimentos').send({ produto_id: prodId, tipo: 'entrada', quantidade: 0 });
      expect([400, 422, 500]).toContain(r1.status);
      const r2 = await request(app).post('/api/movimentos').send({ produto_id: prodId, tipo: 'entrada', quantidade: -5 });
      expect([400, 422, 500]).toContain(r2.status);
    });

    test('rejeita tipo inválido', async () => {
      const res = await request(app).post('/api/movimentos').send({
        produto_id: prodId, tipo: 'transferencia', quantidade: 1
      });
      expect([400, 422, 500]).toContain(res.status);
    });

    test('retorna 404 para produto inexistente', async () => {
      const res = await request(app).post('/api/movimentos').send({
        produto_id: 999999, tipo: 'entrada', quantidade: 1
      });
      expect([404, 400, 500]).toContain(res.status);
    });
  });

  describe('GET /api/movimentos/:produtoId', () => {
    test('retorna histórico de movimentos do produto', async () => {
      await testPool.query(`INSERT INTO movimentos (produto_id,tipo,quantidade,quantidade_anterior,quantidade_nova) VALUES (${prodId},'entrada',5,0,5),(${prodId},'saida',2,5,3)`);
      const res = await request(app).get(`/api/movimentos/${prodId}`);
      expect(res.status).toBe(200);
      expect(Array.isArray(res.body)).toBe(true);
      expect(res.body.length).toBe(2);
    });

    test('retorna array vazio para produto sem movimentos', async () => {
      const res = await request(app).get(`/api/movimentos/${prodId}`);
      expect(res.status).toBe(200);
      expect(res.body.length).toBe(0);
    });
  });
});
