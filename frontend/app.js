'use strict';

// ══════════════════════════════════════════════════════════════════════════════
// CONFIG
// ══════════════════════════════════════════════════════════════════════════════
const LS_KEY = 'techstock_api_url';

function getApiUrl() {
  return (
    localStorage.getItem(LS_KEY) ||
    (window.TECHSTOCK_CONFIG && window.TECHSTOCK_CONFIG.apiUrl) ||
    (location.hostname === 'localhost' ? 'http://localhost:3000' : '')
  ).replace(/\/$/, '');
}

function setApiUrl(url) {
  localStorage.setItem(LS_KEY, url.replace(/\/$/, ''));
}

async function api(path, opts = {}) {
  const base = getApiUrl();
  if (!base) throw new Error('Backend não configurado. Clique em ⚙ para configurar.');
  const res = await fetch(base + path, {
    headers: { 'Content-Type': 'application/json', ...opts.headers },
    ...opts,
  });
  if (!res.ok) {
    const err = await res.json().catch(() => ({ error: res.statusText }));
    throw new Error(err.error || `HTTP ${res.status}`);
  }
  return res.json();
}

// ══════════════════════════════════════════════════════════════════════════════
// ESTADO GLOBAL
// ══════════════════════════════════════════════════════════════════════════════
let cats = [];
const _prodCache = new Map();

// ══════════════════════════════════════════════════════════════════════════════
// MODAIS
// FIX: ov-prod, ov-cfg e ov-hist não fecham ao clicar fora
// ══════════════════════════════════════════════════════════════════════════════
const MODAL_NO_OUTSIDE_CLOSE = new Set(['ov-prod', 'ov-cfg', 'ov-hist', 'ov-mov-novo']);

function openModal(id)  { document.getElementById(id).classList.add('open'); }
function closeModal(id) { document.getElementById(id).classList.remove('open'); }

function initModais() {
  document.querySelectorAll('.ov').forEach(overlay => {
    if (MODAL_NO_OUTSIDE_CLOSE.has(overlay.id)) return;
    overlay.addEventListener('click', function(e) {
      if (e.target === overlay) overlay.classList.remove('open');
    });
  });
  document.addEventListener('keydown', function(e) {
    if (e.key !== 'Escape') return;
    document.querySelectorAll('.ov.open').forEach(o => {
      if (!MODAL_NO_OUTSIDE_CLOSE.has(o.id)) o.classList.remove('open');
    });
  });
}

// ══════════════════════════════════════════════════════════════════════════════
// INIT
// ══════════════════════════════════════════════════════════════════════════════
document.addEventListener('DOMContentLoaded', () => {
  initModais();
  checkApi();
  loadCats();
  loadDash();
  setInterval(checkApi, 30000);
});

// ══════════════════════════════════════════════════════════════════════════════
// STATUS DA API
// ══════════════════════════════════════════════════════════════════════════════
async function checkApi() {
  const el = document.getElementById('api-badge');
  el.className = 'api-badge busy';
  el.textContent = '⬤ Conectando...';
  try {
    const d = await api('/api/health');
    el.className = 'api-badge ok';
    el.textContent = d.ok ? '⬤ API Online' : '⬤ API Degradada';
    const hi = document.getElementById('hostname-info');
    if (hi) hi.textContent = `host: ${d.hostname}`;
  } catch {
    el.className = 'api-badge fail';
    el.textContent = '⬤ API Offline';
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// NAVEGAÇÃO
// ══════════════════════════════════════════════════════════════════════════════
const pages = ['dashboard', 'produtos', 'movimentacoes', 'alertas'];

function showPage(name) {
  pages.forEach((p, i) => {
    const pg  = document.getElementById('page-' + p);
    const btn = document.querySelectorAll('.nav-btn')[i];
    if (pg)  pg.classList.toggle('active', p === name);
    if (btn) btn.classList.toggle('active', p === name);
  });
  if (name === 'dashboard')     loadDash();
  if (name === 'produtos')      loadProd();
  if (name === 'movimentacoes') loadMovPage();
  if (name === 'alertas')       loadAlert();
}

// ══════════════════════════════════════════════════════════════════════════════
// DASHBOARD
// ══════════════════════════════════════════════════════════════════════════════
async function loadDash() {
  try {
    const [st, crit] = await Promise.all([
      api('/api/stats'),
      api('/api/produtos?alerta=1'),
    ]);
    document.getElementById('s-total').textContent = st.total_produtos;
    document.getElementById('s-alert').textContent = st.alertas_estoque;
    document.getElementById('s-mov').textContent   = st.movimentos_hoje;
    document.getElementById('s-valor').textContent =
      'R$ ' + Number(st.valor_total).toLocaleString('pt-BR', { minimumFractionDigits: 2 });

    const b = document.getElementById('banner');
    if (st.alertas_estoque > 0) {
      b.classList.remove('hidden');
      document.getElementById('banner-txt').textContent =
        `${st.alertas_estoque} produto(s) abaixo do mínimo!`;
    } else {
      b.classList.add('hidden');
    }

    const tb = document.getElementById('dash-tb');
    if (!crit.length) {
      tb.innerHTML = '<tr class="empty"><td colspan="5">✅ Nenhum item crítico</td></tr>';
      return;
    }
    tb.innerHTML = crit.map(p => `<tr>
      <td>${codeBadge(p.codigo)}</td>
      <td>${esc(p.nome)}</td>
      <td>${catBadge(p.categoria_nome, p.categoria_cor)}</td>
      <td>${esc(p.localizacao || '—')}</td>
      <td>${qBar(p.quantidade, p.qtd_minima)}</td>
    </tr>`).join('');
  } catch (e) {
    document.getElementById('dash-tb').innerHTML = errRow(5, e.message);
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// CATEGORIAS
// ══════════════════════════════════════════════════════════════════════════════
async function loadCats() {
  try {
    cats = await api('/api/categorias');
    ['p-cat', 'f-cat', 'mn-cat'].forEach(id => {
      const s = document.getElementById(id);
      if (!s) return;
      const base = id === 'f-cat' || id === 'mn-cat'
        ? '<option value="">Todas categorias</option>'
        : '<option value="">Sem categoria</option>';
      s.innerHTML = base + cats.map(c =>
        `<option value="${c.id}">${esc(c.nome)}</option>`
      ).join('');
    });
  } catch { /* silencioso */ }
}

// ══════════════════════════════════════════════════════════════════════════════
// PRODUTOS
// ══════════════════════════════════════════════════════════════════════════════
async function loadProd() {
  const pr = new URLSearchParams();
  const b  = document.getElementById('busca').value;
  const c  = document.getElementById('f-cat').value;
  if (b) pr.set('busca', b);
  if (c) pr.set('categoria_id', c);

  const tb = document.getElementById('prod-tb');
  tb.innerHTML = loadRow(7);
  try {
    const rows = await api('/api/produtos?' + pr);
    _prodCache.clear();
    rows.forEach(p => _prodCache.set(p.id, p));

    if (!rows.length) {
      tb.innerHTML = '<tr class="empty"><td colspan="7">Nenhum produto encontrado</td></tr>';
      return;
    }
    tb.innerHTML = rows.map(p => `<tr>
      <td>${codeBadge(p.codigo)}</td>
      <td>
        <div style="font-weight:500">${esc(p.nome)}</div>
        ${p.descricao ? `<div style="font-size:12px;color:var(--muted)">${esc(p.descricao)}</div>` : ''}
      </td>
      <td>${catBadge(p.categoria_nome, p.categoria_cor)}</td>
      <td>${esc(p.localizacao || '—')}</td>
      <td>${qBar(p.quantidade, p.qtd_minima)}</td>
      <td>R$ ${Number(p.preco_custo).toLocaleString('pt-BR', { minimumFractionDigits: 2 })}</td>
      <td><div style="display:flex;gap:4px;flex-wrap:wrap">
        <button class="btn btn-sm btn-g" data-id="${p.id}" onclick="openMovById(this)" title="Movimentar">↕</button>
        <button class="btn btn-sm btn-o" data-id="${p.id}" onclick="openHistById(this)" title="Histórico">📋</button>
        <button class="btn btn-sm btn-o" data-id="${p.id}" onclick="openEditById(this)" title="Editar">✏️</button>
        <button class="btn btn-sm btn-r" data-id="${p.id}" data-nome="${esc(p.nome)}" onclick="delProdById(this)" title="Inativar">🗑</button>
      </div></td>
    </tr>`).join('');
  } catch (e) {
    tb.innerHTML = errRow(7, e.message);
  }
}

function openEditById(btn) { const p = _prodCache.get(Number(btn.dataset.id)); if (p) openEdit(p); }
function openMovById(btn)  { const p = _prodCache.get(Number(btn.dataset.id)); if (p) openMov(p.id, p.nome); }
function openHistById(btn) { openHist(Number(btn.dataset.id)); }
function delProdById(btn)  { delProd(Number(btn.dataset.id), btn.dataset.nome); }

// ══════════════════════════════════════════════════════════════════════════════
// ALERTAS
// ══════════════════════════════════════════════════════════════════════════════
async function loadAlert() {
  const tb = document.getElementById('alert-tb');
  tb.innerHTML = loadRow(6);
  try {
    const rows = await api('/api/produtos?alerta=1');
    if (!rows.length) {
      tb.innerHTML = '<tr class="empty"><td colspan="6">✅ Nenhum produto abaixo do mínimo!</td></tr>';
      return;
    }
    tb.innerHTML = rows.map(p => `<tr>
      <td>${codeBadge(p.codigo, 'b-bad')}</td>
      <td><strong>${esc(p.nome)}</strong></td>
      <td>${catBadge(p.categoria_nome, p.categoria_cor)}</td>
      <td>${esc(p.localizacao || '—')}</td>
      <td>${qBar(p.quantidade, p.qtd_minima)}</td>
      <td><button class="btn btn-sm btn-g" data-id="${p.id}" data-nome="${esc(p.nome)}" onclick="openMovById(this)">📥 Repor</button></td>
    </tr>`).join('');
  } catch (e) {
    tb.innerHTML = errRow(6, e.message);
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// MOVIMENTAÇÕES — PÁGINA DEDICADA
// ══════════════════════════════════════════════════════════════════════════════
let _movFiltro = { tipo: '', produto: '', cat: '' };

async function loadMovPage() {
  // Popula select de produtos
  await _loadMovProdSelect();
  await _fetchMovs();
}

async function _loadMovProdSelect() {
  const sel = document.getElementById('mn-prod');
  if (!sel || sel.dataset.loaded) return;
  try {
    const prods = await api('/api/produtos');
    sel.innerHTML = '<option value="">Todos os produtos</option>' +
      prods.map(p => `<option value="${p.id}">${esc(p.nome)}</option>`).join('');
    sel.dataset.loaded = '1';
  } catch { /* silencioso */ }
}

async function _fetchMovs() {
  const tb = document.getElementById('mov-tb');
  if (!tb) return;
  tb.innerHTML = loadRow(7);

  const tipo   = document.getElementById('mn-tipo')?.value || '';
  const prodId = document.getElementById('mn-prod')?.value || '';

  const icons  = { entrada: '📥', saida: '📤', ajuste: '⚖️' };
  const tipoCls = { entrada: 'b-ok', saida: 'b-bad', ajuste: 'b-warn' };

  function renderRows(rows) {
    if (tipo) rows = rows.filter(m => m.tipo === tipo);
    rows.sort((a, b) => new Date(b.criado_em) - new Date(a.criado_em));
    document.getElementById('mov-count').textContent = `${rows.length} registro(s)`;
    if (!rows.length) {
      tb.innerHTML = '<tr class="empty"><td colspan="7">Nenhum movimento encontrado.</td></tr>';
      return;
    }
    tb.innerHTML = rows.map(m => {
      const delta = m.tipo === 'entrada' ? `+${m.quantidade}`
                  : m.tipo === 'saida'   ? `-${m.quantidade}`
                  :                        `→${m.quantidade_nova ?? m.quantidade}`;
      const cls = m.tipo === 'entrada' ? 'pos' : m.tipo === 'saida' ? 'neg' : '';
      const dt  = new Date(m.criado_em).toLocaleString('pt-BR');
      // nome do produto: tenta campo da API, depois busca no cache
      const pNome = m.produto_nome
        || (_prodCache.get(Number(m.produto_id))?.nome)
        || String(m.produto_id || '—');
      return `<tr>
        <td>${dt}</td>
        <td><span class="badge ${tipoCls[m.tipo]}">${icons[m.tipo]} ${m.tipo.toUpperCase()}</span></td>
        <td><strong>${esc(pNome)}</strong></td>
        <td style="text-align:center">${m.quantidade_anterior ?? '—'}</td>
        <td style="text-align:center;font-weight:700" class="${cls}">${delta}</td>
        <td style="text-align:center">${m.quantidade_nova ?? '—'}</td>
        <td style="color:var(--muted);font-size:12px">${esc(m.motivo || '—')} · ${esc(m.responsavel || '—')}</td>
      </tr>`;
    }).join('');
  }

  try {
    if (prodId) {
      // Produto selecionado — rota direta
      const rows = await api(`/api/movimentos/${prodId}`);
      renderRows(rows);
    } else {
      // Sem filtro — busca movimentos de todos os produtos em paralelo
      // Garante que o cache de produtos está populado
      if (!_prodCache.size) {
        const prods = await api('/api/produtos');
        prods.forEach(p => _prodCache.set(p.id, p));
      }
      const ids = [..._prodCache.keys()];
      const results = await Promise.all(
        ids.map(id => api(`/api/movimentos/${id}`).catch(() => []))
      );
      renderRows(results.flat());
    }
  } catch (e) {
    tb.innerHTML = errRow(7, e.message);
  }
}

function abrirNovaMovimentacao() {
  // Abre modal de movimentação sem produto pré-selecionado
  // Para usar a partir da página de movimentações
  document.getElementById('mn-mov-pid').value          = '';
  document.getElementById('mn-mov-psel').value         = '';
  document.getElementById('mn-mov-tipo').value         = 'saida';
  document.getElementById('mn-mov-qty').value          = 1;
  document.getElementById('mn-mov-motivo').value       = '';
  document.getElementById('mn-mov-resp').value         = 'web';
  document.getElementById('mn-mov-pnome').textContent  = '';
  openModal('ov-mov-novo');
}

async function onMovProdSelect() {
  const sel  = document.getElementById('mn-mov-psel');
  const id   = sel.value;
  const nome = sel.options[sel.selectedIndex]?.text || '';
  document.getElementById('mn-mov-pid').value         = id;
  document.getElementById('mn-mov-pnome').textContent = nome ? `Produto: ${nome}` : '';
}

async function saveMovNovo() {
  const prodId = document.getElementById('mn-mov-pid').value;
  if (!prodId) {
    alert('Selecione um produto.');
    return;
  }
  const qtd = Number(document.getElementById('mn-mov-qty').value);
  if (!qtd || qtd <= 0 || !Number.isInteger(qtd)) {
    alert('Quantidade deve ser um número inteiro maior que zero.');
    document.getElementById('mn-mov-qty').focus();
    return;
  }
  const body = {
    produto_id:  Number(prodId),
    tipo:        document.getElementById('mn-mov-tipo').value,
    quantidade:  qtd,
    motivo:      document.getElementById('mn-mov-motivo').value.trim(),
    responsavel: document.getElementById('mn-mov-resp').value.trim() || 'web',
  };
  try {
    await api('/api/movimentos', { method: 'POST', body: JSON.stringify(body) });
    closeModal('ov-mov-novo');
    // Invalida cache de produtos para forçar reload com nova qtd
    document.getElementById('mn-prod').dataset.loaded = '';
    await loadMovPage();
    loadDash();
  } catch (e) { alert('Erro: ' + e.message); }
}

// ══════════════════════════════════════════════════════════════════════════════
// CÓDIGO AUTOMÁTICO
// ══════════════════════════════════════════════════════════════════════════════
const CAT_PREFIX = {
  'informática': 'TI', 'informatica': 'TI',
  'elétrico':    'EL', 'eletrico':    'EL',
  'escritório':  'ES', 'escritorio':  'ES',
  'ferramentas': 'FE',
  'limpeza':     'LI',
};

function catToPrefix(nome) {
  if (!nome) return 'PR';
  const norm = nome.toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '');
  return CAT_PREFIX[nome.toLowerCase()]
      || CAT_PREFIX[norm]
      || nome.replace(/[^a-zA-Z]/g, '').substring(0, 2).toUpperCase()
      || 'PR';
}

async function gerarCodigo(categoriaId) {
  const el = document.getElementById('p-cod');
  if (!el) return;

  let prefix = 'PR';
  try {
    if (!cats.length) await loadCats();
    const cat = cats.find(c => String(c.id) === String(categoriaId));
    prefix = catToPrefix(cat ? cat.nome : '');
  } catch { /* usa PR */ }

  el.value = `${prefix}-…`;

  try {
    const produtos = await api(
      categoriaId ? `/api/produtos?categoria_id=${categoriaId}` : '/api/produtos'
    );
    const re = new RegExp(`^${prefix}-(\\d+)$`);
    const nums = produtos
      .map(p => { const m = String(p.codigo || '').match(re); return m ? parseInt(m[1], 10) : 0; })
      .filter(n => n > 0);
    const proximo = nums.length ? Math.max(...nums) + 1 : 1;
    el.value = `${prefix}-${String(proximo).padStart(3, '0')}`;
  } catch {
    el.value = `${prefix}-001`;
  }
}

async function onCatChange() {
  if (!document.getElementById('p-id').value) {
    await gerarCodigo(document.getElementById('p-cat').value);
  }
}

function setCodReadonly(el) {
  el.readOnly = true;
  el.style.cssText =
    'width:100%;background:#F1F5F9;color:#64748B;cursor:default;' +
    'border:1px solid #E2E8F0;border-radius:8px;padding:8px 12px;font-size:14px;';
}

// ══════════════════════════════════════════════════════════════════════════════
// CRUD PRODUTO
// ══════════════════════════════════════════════════════════════════════════════
async function openNovo() {
  document.getElementById('m-prod-title').textContent = 'Novo Produto';
  document.getElementById('p-id').value    = '';
  document.getElementById('p-nome').value  = '';
  document.getElementById('p-desc').value  = '';
  document.getElementById('p-loc').value   = '';
  document.getElementById('p-qty').value   = 0;
  document.getElementById('p-min').value   = 5;
  document.getElementById('p-custo').value = 0;
  document.getElementById('p-un').value    = 'un';
  document.getElementById('p-cat').value   = '';

  // Hint: qty é editável apenas em novo produto
  const qtyEl = document.getElementById('p-qty');
  qtyEl.readOnly = false;
  qtyEl.style.cssText = '';
  const hint = document.getElementById('p-qty-hint');
  if (hint) hint.textContent = '';

  setCodReadonly(document.getElementById('p-cod'));
  openModal('ov-prod');
  gerarCodigo('');
}

function openEdit(p) {
  document.getElementById('m-prod-title').textContent = 'Editar Produto';
  document.getElementById('p-id').value    = p.id;
  document.getElementById('p-nome').value  = p.nome;
  document.getElementById('p-desc').value  = p.descricao || '';
  document.getElementById('p-loc').value   = p.localizacao || '';
  document.getElementById('p-qty').value   = p.quantidade;
  document.getElementById('p-min').value   = p.qtd_minima;
  document.getElementById('p-custo').value = p.preco_custo;
  document.getElementById('p-un').value    = p.unidade || 'un';
  document.getElementById('p-cat').value   = p.categoria_id || '';

  // FIX: em edição, quantidade é somente leitura
  // Para alterar estoque use o botão ↕ Movimentar
  const qtyEl = document.getElementById('p-qty');
  qtyEl.readOnly = true;
  qtyEl.style.cssText =
    'width:100%;background:#F1F5F9;color:#64748B;cursor:default;' +
    'border:1px solid #E2E8F0;border-radius:8px;padding:8px 12px;font-size:14px;';
  const hint = document.getElementById('p-qty-hint');
  if (hint) hint.innerHTML =
    `<span style="font-size:11px;color:var(--muted)">Use o botão ↕ para movimentar estoque</span>`;

  const cod = document.getElementById('p-cod');
  cod.value = p.codigo;
  setCodReadonly(cod);
  openModal('ov-prod');
}

async function saveProd() {
  const id   = document.getElementById('p-id').value;
  const nome = document.getElementById('p-nome').value.trim();

  if (!nome) {
    alert('Nome é obrigatório.');
    document.getElementById('p-nome').focus();
    return;
  }

  let codigo = document.getElementById('p-cod').value.trim();
  if (!codigo || codigo.includes('…')) {
    await gerarCodigo(document.getElementById('p-cat').value);
    codigo = document.getElementById('p-cod').value.trim();
  }
  if (!codigo || codigo.includes('…')) {
    const cat = cats.find(c => String(c.id) === String(document.getElementById('p-cat').value));
    codigo = `${catToPrefix(cat ? cat.nome : '')}-${Date.now().toString().slice(-3)}`;
    document.getElementById('p-cod').value = codigo;
  }

  const body = {
    codigo,
    nome,
    descricao:    document.getElementById('p-desc').value.trim() || null,
    categoria_id: document.getElementById('p-cat').value || null,
    unidade:      document.getElementById('p-un').value,
    quantidade:   Number(document.getElementById('p-qty').value),
    qtd_minima:   Number(document.getElementById('p-min').value),
    preco_custo:  Number(document.getElementById('p-custo').value),
    localizacao:  document.getElementById('p-loc').value.trim() || null,
  };

  try {
    if (id) await api(`/api/produtos/${id}`, { method: 'PUT',  body: JSON.stringify(body) });
    else    await api('/api/produtos',        { method: 'POST', body: JSON.stringify(body) });
    closeModal('ov-prod');
    loadProd();
    loadDash();
  } catch (e) {
    alert('Erro ao salvar: ' + e.message);
  }
}

async function delProd(id, nome) {
  if (!confirm(`Inativar "${nome}"?`)) return;
  try {
    await api(`/api/produtos/${id}`, { method: 'DELETE' });
    loadProd();
    loadDash();
  } catch (e) { alert('Erro: ' + e.message); }
}

// ══════════════════════════════════════════════════════════════════════════════
// MOVIMENTAÇÃO (modal rápido — acessado via botão ↕ na tabela de produtos)
// ══════════════════════════════════════════════════════════════════════════════
function openMov(id, nome) {
  document.getElementById('m-pid').value         = id;
  document.getElementById('m-pnome').textContent = nome;
  document.getElementById('m-qty').value         = 1;
  document.getElementById('m-tipo').value        = 'saida';
  document.getElementById('m-motivo').value      = '';
  document.getElementById('m-resp').value        = 'web';
  openModal('ov-mov');
}

async function saveMov() {
  const qtd = Number(document.getElementById('m-qty').value);
  if (!qtd || qtd <= 0 || !Number.isInteger(qtd)) {
    alert('Quantidade deve ser um número inteiro maior que zero.');
    document.getElementById('m-qty').focus();
    return;
  }
  const body = {
    produto_id:  Number(document.getElementById('m-pid').value),
    tipo:        document.getElementById('m-tipo').value,
    quantidade:  qtd,
    motivo:      document.getElementById('m-motivo').value.trim(),
    responsavel: document.getElementById('m-resp').value.trim() || 'web',
  };
  try {
    await api('/api/movimentos', { method: 'POST', body: JSON.stringify(body) });
    closeModal('ov-mov');
    loadProd();
    loadDash();
    if (document.getElementById('page-alertas').classList.contains('active'))       loadAlert();
    if (document.getElementById('page-movimentacoes').classList.contains('active')) loadMovPage();
  } catch (e) { alert('Erro: ' + e.message); }
}

// ══════════════════════════════════════════════════════════════════════════════
// HISTÓRICO
// ══════════════════════════════════════════════════════════════════════════════
async function openHist(id) {
  openModal('ov-hist');
  const b = document.getElementById('hist-body');
  b.innerHTML = '<div style="text-align:center;padding:30px;color:var(--muted)"><span class="spin"></span>Carregando...</div>';
  try {
    const movs = await api(`/api/movimentos/${id}`);
    if (!movs.length) {
      b.innerHTML = '<div style="text-align:center;padding:30px;color:var(--muted)">Sem movimentos</div>';
      return;
    }
    const icons = { entrada: '📥', saida: '📤', ajuste: '⚖️' };
    b.innerHTML = movs.map(m => {
      const delta = m.tipo === 'entrada' ? `+${m.quantidade}`
                  : m.tipo === 'saida'   ? `-${m.quantidade}`
                  :                        `→${m.quantidade_nova}`;
      const cls = m.tipo === 'entrada' ? 'pos' : m.tipo === 'saida' ? 'neg' : '';
      const dt  = new Date(m.criado_em).toLocaleString('pt-BR');
      return `<div class="hi">
        <div class="hi-ico ${m.tipo}">${icons[m.tipo]}</div>
        <div class="hi-d">
          <div class="hi-t">${m.tipo.toUpperCase()} · ${dt}</div>
          <div class="hi-m">${esc(m.motivo || '—')} · ${esc(m.responsavel)}</div>
          <div class="hi-m">${m.quantidade_anterior} → ${m.quantidade_nova}</div>
        </div>
        <div class="hi-q ${cls}">${delta}</div>
      </div>`;
    }).join('');
  } catch (e) {
    b.innerHTML = `<div style="color:var(--red);text-align:center;padding:20px">Erro: ${esc(e.message)}</div>`;
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// CONFIG DE ENDPOINT
// ══════════════════════════════════════════════════════════════════════════════
function openConfig() {
  document.getElementById('cfg-url').value         = getApiUrl();
  document.getElementById('cfg-atual').textContent = getApiUrl() || '(não configurado)';
  document.getElementById('cfg-res').textContent   = '';
  document.getElementById('cfg-res').className     = 'tr-res';
  openModal('ov-cfg');
}

async function testApi() {
  const url = document.getElementById('cfg-url').value.trim().replace(/\/$/, '');
  const el  = document.getElementById('cfg-res');
  el.className   = 'tr-res busy';
  el.textContent = '🔌 Testando...';
  try {
    const r = await fetch(url + '/api/health', { signal: AbortSignal.timeout(6000) });
    const d = await r.json();
    el.className   = 'tr-res ok';
    el.textContent = d.ok
      ? `✅ OK · DB: ${d.db?.ts ? new Date(d.db.ts).toLocaleTimeString('pt-BR') : '?'} · Host: ${d.hostname}`
      : '⚠️ API respondeu com erro';
  } catch (e) {
    el.className   = 'tr-res fail';
    el.textContent = `❌ ${e.message}`;
  }
}

function saveConfig() {
  const url = document.getElementById('cfg-url').value.trim().replace(/\/$/, '');
  if (!url) { alert('Informe a URL do backend.'); return; }
  setApiUrl(url);
  closeModal('ov-cfg');
  location.reload();
}

// ══════════════════════════════════════════════════════════════════════════════
// UTILS
// ══════════════════════════════════════════════════════════════════════════════
function esc(s) {
  return String(s ?? '')
    .replace(/&/g,  '&amp;')
    .replace(/</g,  '&lt;')
    .replace(/>/g,  '&gt;')
    .replace(/"/g,  '&quot;')
    .replace(/'/g,  '&#39;');
}

function codeBadge(c, cls = 'b-info') {
  return `<span class="badge ${cls}">${esc(c)}</span>`;
}

function catBadge(nome, cor) {
  if (!nome) return '<span style="color:var(--muted)">—</span>';
  const bg = cor ? cor + '22' : '#f1f5f9';
  const tc = cor || '#64748b';
  return `<span style="background:${bg};color:${tc};padding:2px 8px;border-radius:20px;font-size:11px;font-weight:600">${esc(nome)}</span>`;
}

function qBar(qty, min) {
  const pct   = min > 0 ? Math.min((qty / (min * 2)) * 100, 100) : 100;
  const cls   = qty <= 0 ? 'bad' : qty <= min ? 'warn' : 'ok';
  const badge = qty <= 0   ? '<span class="badge b-bad">ZERADO</span>'
              : qty <= min ? '<span class="badge b-warn">BAIXO</span>' : '';
  return `<div class="qb"><div class="bar"><div class="bar-fill ${cls}" style="width:${pct}%"></div></div><span class="qn">${qty}</span>${badge}</div>`;
}

function loadRow(cols) {
  return `<tr class="empty"><td colspan="${cols}"><span class="spin"></span>Carregando...</td></tr>`;
}
function errRow(cols, msg) {
  return `<tr class="empty"><td colspan="${cols}" style="color:var(--red)">Erro: ${esc(msg)} · <button class="btn btn-sm btn-o" onclick="openConfig()">⚙ Configurar</button></td></tr>`;
}

let _dt = {};
function debounce(fn, ms) {
  return (...a) => {
    clearTimeout(_dt[fn.name]);
    _dt[fn.name] = setTimeout(() => fn(...a), ms);
  };
}
