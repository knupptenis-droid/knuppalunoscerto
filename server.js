// Knupp Tênis · Reposições 2.0
// Toda a regra de negócio mora em funções SQL no Supabase (schema.sql).
// Este servidor só confere a senha do professor e repassa os pedidos.

const path = require('path');
const crypto = require('crypto');
const express = require('express');

const { SUPABASE_URL, SUPABASE_SERVICE_KEY, ADMIN_SENHA, PORT = 3000, TEST_PG } = process.env;

if (!ADMIN_SENHA || (!TEST_PG && (!SUPABASE_URL || !SUPABASE_SERVICE_KEY))) {
  console.error('Faltam variaveis de ambiente: SUPABASE_URL, SUPABASE_SERVICE_KEY, ADMIN_SENHA');
  process.exit(1);
}

// ---------- acesso ao banco: sempre por funções (rpc) ----------
let rpc;
if (TEST_PG) {
  // modo de teste local (Postgres direto)
  const { Pool } = require('pg');
  const pool = new Pool({ connectionString: TEST_PG });
  rpc = async (fn, args = {}) => {
    const keys = Object.keys(args);
    const JSONB = ['p_lista', 'p_notas', 'p_checklist', 'p_presencas', 'p_itens', 'p_produto', 'p_store'];
    const vals = keys.map(k => ((JSONB.includes(k) || (fn === 'admin_salvar_config' && k === 'p_valor')) && args[k] !== null
      ? JSON.stringify(args[k]) : args[k]));
    const sql = `select public.${fn}(${keys.map((k, i) => `${k} => $${i + 1}`).join(', ')}) as r`;
    const { rows } = await pool.query(sql, vals);
    return rows[0].r;
  };
} else {
  const { createClient } = require('@supabase/supabase-js');
  const db = createClient(SUPABASE_URL.replace(/\/+$/, ''), SUPABASE_SERVICE_KEY, { auth: { persistSession: false } });
  rpc = async (fn, args = {}) => {
    const { data, error } = await db.rpc(fn, args);
    if (error) throw error;
    return data;
  };
}

const app = express();
app.use(express.json({ limit: '12mb' }));
app.use(express.static(path.join(__dirname, 'public'), {
  setHeaders(res, file) {
    if (file.endsWith('sw.js') || file.endsWith('.html')) res.setHeader('Cache-Control', 'no-cache');
  },
}));

// endereço usado para acordar o site (cron-job.org)
app.get('/ping', (req, res) => res.type('text').send('ok'));

// ---------- proteção simples contra excesso de tentativas ----------
const LIMITE = Number(process.env.LIMITE_POR_MINUTO || 40);
const tentativas = new Map();
function limitar(max) {
  return (req, res, next) => {
    const ip = (req.headers['x-forwarded-for'] || req.ip || '').split(',')[0].trim();
    const agora = Date.now();
    const lista = (tentativas.get(ip) || []).filter(t => agora - t < 60_000);
    lista.push(agora);
    tentativas.set(ip, lista);
    if (lista.length > max) return res.status(429).json({ erro: 'Muitas tentativas. Espere um minuto.' });
    next();
  };
}

function exigirAdmin(req, res, next) {
  if (req.get('x-admin-senha') !== ADMIN_SENHA) return res.status(401).json({ erro: 'Senha incorreta.' });
  next();
}

const rota = fn => async (req, res) => {
  try {
    await fn(req, res);
  } catch (e) {
    console.error(e);
    res.status(500).json({ erro: 'Algo deu errado. Tente de novo em instantes.' });
  }
};

const num = v => (v === null || v === undefined || v === '' ? null : Number(v));
const ints = v => (Array.isArray(v) ? v.map(Number).filter(Number.isFinite) : []);
const txt = v => (v === null || v === undefined ? null : String(v));

// ======================= ALUNO =======================
app.get('/api/info', rota(async (req, res) => {
  res.json(await rpc('publico_info'));
}));

app.post('/api/aluno/entrar', limitar(LIMITE), rota(async (req, res) => {
  res.json(await rpc('aluno_entrar', { p_whatsapp: txt(req.body.whatsapp) }));
}));

app.post('/api/aluno/reservar', limitar(LIMITE), rota(async (req, res) => {
  res.json(await rpc('aluno_reservar', {
    p_whatsapp: txt(req.body.whatsapp), p_aluno_id: num(req.body.aluno_id), p_horario_id: num(req.body.horario_id),
  }));
}));

app.post('/api/aluno/cancelar', limitar(LIMITE), rota(async (req, res) => {
  res.json(await rpc('aluno_cancelar', { p_whatsapp: txt(req.body.whatsapp), p_reserva_id: num(req.body.reserva_id) }));
}));

// ======================= PROFESSOR =======================
const admin = express.Router();
admin.use(limitar(120), exigirAdmin);

admin.get('/dados', rota(async (req, res) => res.json(await rpc('admin_dados'))));
admin.get('/estatisticas', rota(async (req, res) => res.json(await rpc('admin_estatisticas'))));

admin.post('/horario', rota(async (req, res) => {
  const b = req.body;
  if (!b.data || !b.hora) return res.status(400).json({ erro: 'Preencha dia e hora.' });
  if (!(Number(b.vagas) >= 0)) return res.status(400).json({ erro: 'Número de vagas inválido.' });
  res.json(await rpc('admin_salvar_horario', {
    p_id: num(b.id), p_data: b.data, p_hora: b.hora, p_nivel_ids: ints(b.nivel_ids), p_vagas: Number(b.vagas),
    p_observacao: txt(b.observacao), p_abre_em: b.abre_em || null,
  }));
}));
admin.post('/horario/:id/status', rota(async (req, res) =>
  res.json(await rpc('admin_status_horario', { p_id: num(req.params.id), p_status: txt(req.body.status) }))));
admin.post('/horario/:id/abrir-agora', rota(async (req, res) =>
  res.json(await rpc('admin_abrir_agora', { p_id: num(req.params.id) }))));
admin.post('/horario/:id/cancelar', rota(async (req, res) =>
  res.json(await rpc('admin_cancelar_horario', { p_id: num(req.params.id), p_motivo: txt(req.body.motivo) }))));
admin.delete('/horario/:id', rota(async (req, res) =>
  res.json(await rpc('admin_excluir_horario', { p_id: num(req.params.id) }))));

admin.post('/reserva/:id/confirmar', rota(async (req, res) =>
  res.json(await rpc('admin_confirmar', { p_reserva: num(req.params.id) }))));
admin.post('/reserva/:id/recusar', rota(async (req, res) =>
  res.json(await rpc('admin_recusar', { p_reserva: num(req.params.id) }))));
admin.post('/reservar', rota(async (req, res) =>
  res.json(await rpc('admin_reservar', {
    p_aluno_id: num(req.body.aluno_id), p_horario_id: num(req.body.horario_id), p_usar_credito: !!req.body.usar_credito,
  }))));

admin.post('/creditos', rota(async (req, res) => {
  const ids = ints(req.body.aluno_ids);
  if (!ids.length) return res.status(400).json({ erro: 'Escolha pelo menos um aluno.' });
  res.json(await rpc('admin_dar_creditos', {
    p_aluno_ids: ids, p_quantidade: Number(req.body.quantidade) || 1,
    p_origem: txt(req.body.origem) || 'manual', p_motivo: txt(req.body.motivo),
  }));
}));
admin.delete('/credito/:id', rota(async (req, res) =>
  res.json(await rpc('admin_remover_credito', { p_credito: num(req.params.id) }))));
admin.post('/chuva', rota(async (req, res) => {
  if (!req.body.data) return res.status(400).json({ erro: 'Escolha o dia.' });
  res.json(await rpc('admin_chuva', {
    p_data: req.body.data, p_aluno_ids: ints(req.body.aluno_ids), p_motivo: txt(req.body.motivo),
    p_cancelar_reposicoes: !!req.body.cancelar_reposicoes,
  }));
}));

admin.post('/aluno', rota(async (req, res) => {
  const b = req.body;
  if (!b.nome || String(b.nome).trim().length < 2) return res.status(400).json({ erro: 'Escreva o nome do aluno.' });
  if (b.whatsapp && String(b.whatsapp).replace(/\D/g, '').length < 10)
    return res.status(400).json({ erro: 'WhatsApp inválido: coloque DDD + número.' });
  res.json(await rpc('admin_salvar_aluno', {
    p_id: num(b.id), p_nome: String(b.nome), p_whatsapp: txt(b.whatsapp) || null, p_nivel_ids: ints(b.nivel_ids),
    p_turmas: Array.isArray(b.turmas) ? b.turmas.map(String).map(s => s.trim()).filter(Boolean) : [],
    p_observacao: txt(b.observacao), p_ativo: b.ativo !== false,
  }));
}));
admin.delete('/aluno/:id', rota(async (req, res) =>
  res.json(await rpc('admin_excluir_aluno', { p_id: num(req.params.id) }))));
admin.post('/importar', rota(async (req, res) => {
  if (!Array.isArray(req.body.lista)) return res.status(400).json({ erro: 'Lista vazia.' });
  res.json(await rpc('admin_importar_alunos', { p_lista: req.body.lista }));
}));

admin.post('/nivel', rota(async (req, res) => {
  const b = req.body;
  if (!b.nome) return res.status(400).json({ erro: 'Escreva o nome do nível.' });
  res.json(await rpc('admin_salvar_nivel', {
    p_id: num(b.id), p_nome: String(b.nome), p_cor: txt(b.cor), p_ordem: num(b.ordem), p_ativo: b.ativo !== false,
  }));
}));
admin.delete('/nivel/:id', rota(async (req, res) =>
  res.json(await rpc('admin_excluir_nivel', { p_id: num(req.params.id) }))));

const CONFIG_PERMITIDA = ['validade_dias', 'hora_abertura', 'local_nome', 'local_endereco', 'professor_nome',
  'professor_bio', 'professor_whatsapp', 'instagram', 'foto', 'regras', 'msg_confirmacao', 'msg_grupo', 'msg_cancelamento',
  'pix_tipo', 'pix_chave', 'pix_nome', 'pix_cidade', 'msg_cobranca', 'msg_lembrete_aula', 'indicacao_beneficio', 'habilidades', 'financeiro_inicio',
  'preco_aula', 'loja_taxas', 'loja_entrega', 'loja_categorias', 'loja_url',
  'plano_desconto', 'taxa_credito_1x', 'taxa_credito_3x'];
admin.post('/config', rota(async (req, res) => {
  const itens = Object.entries(req.body || {}).filter(([k]) => CONFIG_PERMITIDA.includes(k));
  for (const [k, v] of itens) await rpc('admin_salvar_config', { p_chave: k, p_valor: v });
  res.json({ ok: true, salvos: itens.length });
}));


// ======================= ÁREA DO ALUNO v3 (login com PIN) =======================
function hashPin(pin) {
  const sal = crypto.randomBytes(16).toString('hex');
  return sal + ':' + crypto.scryptSync(String(pin), sal, 32).toString('hex');
}
function confereHash(pin, guardado) {
  const [sal, h] = String(guardado || '').split(':');
  if (!sal || !h) return false;
  const a = Buffer.from(crypto.scryptSync(String(pin), sal, 32).toString('hex'));
  const b = Buffer.from(h);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}
const errosPin = new Map(); // chave -> {n, ate}
function bloqueado(chave) { const e = errosPin.get(chave); return e && e.ate > Date.now(); }
function errou(chave) {
  const e = errosPin.get(chave) || { n: 0, ate: 0 };
  e.n += 1; if (e.n >= 5) { e.ate = Date.now() + 15 * 60_000; e.n = 0; }
  errosPin.set(chave, e);
}

app.post('/api/v3/login', limitar(LIMITE), rota(async (req, res) => {
  const wpp = txt(req.body.whatsapp) || '';
  const pin = String(req.body.pin || '');
  const st = await rpc('conta_status', { p_whatsapp: wpp });
  if (!st.chave) return res.json({ ok: false, motivo: 'numero_invalido' });
  if (!st.existe) return res.json({ ok: false, motivo: 'nao_cadastrado' });
  if (bloqueado(st.chave)) return res.json({ ok: false, motivo: 'bloqueado' });
  if (!st.pin_hash) {
    if (!pin) return res.json({ ok: false, motivo: 'criar_pin' });
    if (!/^\d{4}$/.test(pin)) return res.json({ ok: false, motivo: 'pin_formato' });
    await rpc('conta_definir_pin', { p_whatsapp: wpp, p_hash: hashPin(pin) });
  } else {
    if (!pin) return res.json({ ok: false, motivo: 'pedir_pin' });
    if (!confereHash(pin, st.pin_hash)) { errou(st.chave); return res.json({ ok: false, motivo: 'pin_errado' }); }
  }
  errosPin.delete(st.chave);
  const token = crypto.randomBytes(24).toString('hex');
  await rpc('sessao_criar', { p_whatsapp: wpp, p_token: token });
  res.json({ ok: true, token });
}));

async function sessao(req, res) {
  const token = req.get('x-token') || '';
  const wpp = token ? await rpc('sessao_wpp', { p_token: token }) : null;
  if (!wpp) { res.status(401).json({ erro: 'Sessão expirada. Entre de novo.' }); return null; }
  return wpp;
}

app.post('/api/v3/sair', rota(async (req, res) => {
  await rpc('sessao_sair', { p_token: req.get('x-token') || '' }); res.json({ ok: true });
}));

// funções que o aluno pode chamar (o WhatsApp vem da sessão, nunca do navegador)
const FUNCOES_ALUNO = {
  aluno_area: () => ({}),
  aluno_reservar: b => ({ p_aluno_id: num(b.aluno_id), p_horario_id: num(b.horario_id) }),
  aluno_cancelar: b => ({ p_reserva_id: num(b.reserva_id) }),
  aluno_informar_pagamento: b => ({ p_mensalidade: num(b.mensalidade_id) }),
  aluno_avaliar_aula: b => ({ p_aluno_id: num(b.aluno_id), p_aula_id: num(b.aula_id), p_nota: num(b.nota), p_comentario: txt(b.comentario) }),
  aluno_indicar: b => ({ p_aluno_id: num(b.aluno_id), p_nome: txt(b.nome), p_wpp_amigo: txt(b.whatsapp) }),
  aluno_area_v4: () => ({}),
  aluno_criar_pedido: b => ({ p_aluno_id: num(b.aluno_id), p_tipo: txt(b.tipo), p_itens: Array.isArray(b.itens) ? b.itens : [],
    p_pagamento: txt(b.pagamento) || 'pix', p_entrega: txt(b.entrega) || 'retirada', p_endereco: txt(b.endereco), p_observacao: txt(b.observacao) }),
  aluno_informar_pedido: b => ({ p_pedido: num(b.pedido_id) }),
  aluno_cancelar_pedido: b => ({ p_pedido: num(b.pedido_id) }),
  aluno_area_v5: () => ({}),
  aluno_pagar_cartao: b => ({ p_mensalidade: num(b.mensalidade_id) }),
};

// ======================= LOJA (pública) =======================
app.get('/api/loja', rota(async (req, res) => res.json(await rpc('loja_listar'))));
app.get('/api/loja/:id', rota(async (req, res) => res.json(await rpc('loja_produto', { p_id: String(req.params.id) }))));
app.post('/api/v3/aluno/:fn', limitar(LIMITE), rota(async (req, res) => {
  const montar = FUNCOES_ALUNO[req.params.fn];
  if (!montar) return res.status(404).json({ erro: 'Ação inválida.' });
  const wpp = await sessao(req, res); if (!wpp) return;
  res.json(await rpc(req.params.fn, { p_whatsapp: wpp, ...montar(req.body || {}) }));
}));

// funções novas do painel (repassa os parâmetros como vieram, com prefixo p_)
const FUNCOES_ADMIN = ['admin_dados_v3', 'admin_salvar_aluno_extra', 'admin_salvar_turma', 'admin_excluir_turma',
  'admin_financeiro', 'admin_mensalidade', 'admin_excluir_mensalidade', 'admin_aulas_dia', 'admin_salvar_aula',
  'admin_salvar_avaliacao', 'admin_avaliacoes', 'admin_excluir_avaliacao', 'admin_nivel_criterios',
  'admin_salvar_conteudo', 'admin_excluir_conteudo', 'admin_salvar_aviso', 'admin_excluir_aviso',
  'admin_indicacao_status', 'admin_resetar_pin', 'gerar_mensalidades',
  'admin_dados_v4', 'admin_pedido_status', 'admin_salvar_produto', 'admin_excluir_produto', 'loja_produto', 'admin_importar_loja', 'admin_dados_v5'];

// importa os produtos da vitrine antiga (lê o JSON que fica dentro do index.html dela)
admin.post('/importar-loja', rota(async (req, res) => {
  const url = String(req.body.url || '').trim();
  if (!/^https:\/\/[a-z0-9.-]+\.netlify\.app\/?$/i.test(url) && !/^https:\/\/[a-z0-9.-]+\.[a-z.]+\/?$/i.test(url))
    return res.status(400).json({ erro: 'Endereço inválido.' });
  let html;
  try { const r = await fetch(url); html = await r.text(); } catch (e) { return res.status(502).json({ erro: 'Não consegui abrir a loja.' }); }
  const m = html.match(/<script[^>]*id=["']store["'][^>]*>([\s\S]*?)<\/script>/i);
  if (!m) return res.status(422).json({ erro: 'Não achei os produtos nessa página.' });
  let store; try { store = JSON.parse(m[1]); } catch (e) { return res.status(422).json({ erro: 'Os dados da loja estão num formato inesperado.' }); }
  res.json(await rpc('admin_importar_loja', { p_store: store }));
}));
admin.post('/v3/:fn', rota(async (req, res) => {
  if (!FUNCOES_ADMIN.includes(req.params.fn)) return res.status(404).json({ erro: 'Ação inválida.' });
  const args = {};
  for (const [k, v] of Object.entries(req.body || {})) args['p_' + k] = v === '' ? null : v;
  res.json(await rpc(req.params.fn, args));
}));

app.use('/api/admin', admin);

app.listen(PORT, () => console.log(`Reposições Knupp rodando na porta ${PORT}`));
