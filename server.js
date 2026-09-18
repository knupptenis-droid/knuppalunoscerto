const path = require('path');
const express = require('express');
const { createClient } = require('@supabase/supabase-js');

const {
  SUPABASE_URL,
  SUPABASE_SERVICE_KEY,
  ADMIN_SENHA,
  PORT = 3000,
} = process.env;

if (!SUPABASE_URL || !SUPABASE_SERVICE_KEY || !ADMIN_SENHA) {
  console.error('Faltam variaveis de ambiente: SUPABASE_URL, SUPABASE_SERVICE_KEY, ADMIN_SENHA');
  process.exit(1);
}

const db = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, {
  auth: { persistSession: false },
});

const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

const NIVEIS = ['Iniciante', 'Intermediário', 'Avançado'];

function exigirAdmin(req, res, next) {
  const senha = req.get('x-admin-senha');
  if (senha !== ADMIN_SENHA) {
    return res.status(401).json({ erro: 'Senha incorreta.' });
  }
  next();
}

// ---------- rotas publicas ----------

// Lista todas as rodadas ABERTAS (pode ser mais de uma ao mesmo tempo)
app.get('/api/vagas', async (req, res) => {
  try {
    const { data, error } = await db
      .from('ofertas')
      .select('id, titulo, detalhe, criada_em')
      .eq('aberta', true)
      .order('criada_em', { ascending: true });
    if (error) throw error;

    res.json({ ofertas: data, niveis: NIVEIS });
  } catch (e) {
    console.error(e);
    res.status(500).json({ erro: 'Não foi possível carregar as vagas. Tente de novo.' });
  }
});

app.post('/api/inscricoes', async (req, res) => {
  try {
    const ofertaId = parseInt(req.body.oferta_id, 10);
    const nome = String(req.body.nome || '').trim();
    const nivel = String(req.body.nivel || '').trim();
    const whatsapp = String(req.body.whatsapp || '').trim();

    if (!Number.isInteger(ofertaId)) return res.status(400).json({ erro: 'Escolha um horário.' });
    if (nome.length < 3) return res.status(400).json({ erro: 'Escreva seu nome completo.' });
    if (!NIVEIS.includes(nivel)) return res.status(400).json({ erro: 'Escolha o seu nível.' });
    if (whatsapp.replace(/\D/g, '').length < 10) {
      return res.status(400).json({ erro: 'Escreva um WhatsApp válido, com DDD.' });
    }

    const { data: oferta, error: erroOferta } = await db
      .from('ofertas')
      .select('id, aberta')
      .eq('id', ofertaId)
      .maybeSingle();
    if (erroOferta) throw erroOferta;
    if (!oferta || !oferta.aberta) {
      return res.status(409).json({ erro: 'Esse horário não está mais disponível. Atualize a página.' });
    }

    const { error: erroInsert } = await db
      .from('inscricoes')
      .insert({ oferta_id: ofertaId, nome, nivel, whatsapp, status: 'pendente' });

    if (erroInsert) {
      if (erroInsert.code === '23505') {
        return res.status(409).json({ erro: 'Esse nome já está inscrito nesse horário.' });
      }
      throw erroInsert;
    }

    res.json({ ok: true });
  } catch (e) {
    console.error(e);
    res.status(500).json({ erro: 'Não foi possível concluir a inscrição. Tente de novo.' });
  }
});

// ---------- rotas de admin ----------

// Todas as rodadas (abertas e encerradas), cada uma com seus inscritos
app.get('/api/admin/painel', exigirAdmin, async (req, res) => {
  try {
    const { data: ofertas, error: erroOfertas } = await db
      .from('ofertas')
      .select('*')
      .order('criada_em', { ascending: false })
      .limit(30);
    if (erroOfertas) throw erroOfertas;

    const ids = ofertas.map(o => o.id);
    let inscricoes = [];
    if (ids.length) {
      const { data, error } = await db
        .from('inscricoes')
        .select('*')
        .in('oferta_id', ids)
        .order('criada_em', { ascending: true });
      if (error) throw error;
      inscricoes = data;
    }

    const porOferta = {};
    inscricoes.forEach(i => {
      (porOferta[i.oferta_id] = porOferta[i.oferta_id] || []).push(i);
    });

    res.json({
      ofertas: ofertas.map(o => ({ ...o, inscricoes: porOferta[o.id] || [] })),
      niveis: NIVEIS,
    });
  } catch (e) {
    console.error(e);
    res.status(500).json({ erro: 'Não foi possível carregar o painel.' });
  }
});

app.post('/api/admin/ofertas', exigirAdmin, async (req, res) => {
  try {
    const titulo = String(req.body.titulo || '').trim();
    const detalhe = String(req.body.detalhe || '').trim();

    if (!titulo) return res.status(400).json({ erro: 'Escreva um título para o horário.' });

    const { data, error } = await db
      .from('ofertas')
      .insert({ titulo, detalhe: detalhe || null, aberta: true })
      .select()
      .single();
    if (error) throw error;

    res.json({ oferta: data });
  } catch (e) {
    console.error(e);
    res.status(500).json({ erro: 'Não foi possível abrir o horário.' });
  }
});

app.patch('/api/admin/ofertas/:id', exigirAdmin, async (req, res) => {
  try {
    const patch = {};
    if (req.body.aberta !== undefined) patch.aberta = !!req.body.aberta;
    if (req.body.titulo !== undefined) patch.titulo = String(req.body.titulo).trim();
    if (req.body.detalhe !== undefined) patch.detalhe = String(req.body.detalhe).trim() || null;

    const { data, error } = await db
      .from('ofertas')
      .update(patch)
      .eq('id', req.params.id)
      .select()
      .single();
    if (error) throw error;

    res.json({ oferta: data });
  } catch (e) {
    console.error(e);
    res.status(500).json({ erro: 'Não foi possível salvar a alteração.' });
  }
});

app.patch('/api/admin/inscricoes/:id', exigirAdmin, async (req, res) => {
  try {
    const patch = {};
    if (req.body.status !== undefined) {
      if (!['pendente', 'confirmado'].includes(req.body.status)) {
        return res.status(400).json({ erro: 'Status inválido.' });
      }
      patch.status = req.body.status;
    }

    const { data, error } = await db
      .from('inscricoes')
      .update(patch)
      .eq('id', req.params.id)
      .select()
      .single();
    if (error) throw error;

    res.json({ inscricao: data });
  } catch (e) {
    console.error(e);
    res.status(500).json({ erro: 'Não foi possível salvar a alteração.' });
  }
});

app.delete('/api/admin/inscricoes/:id', exigirAdmin, async (req, res) => {
  try {
    const { error } = await db.from('inscricoes').delete().eq('id', req.params.id);
    if (error) throw error;
    res.json({ ok: true });
  } catch (e) {
    console.error(e);
    res.status(500).json({ erro: 'Não foi possível remover a inscrição.' });
  }
});

app.listen(PORT, () => console.log(`Rodando na porta ${PORT}`));
