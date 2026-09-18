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

async function ofertaAtual() {
  const { data, error } = await db
    .from('ofertas')
    .select('*')
    .order('criada_em', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error) throw error;
  return data;
}

async function contarInscricoes(ofertaId) {
  const { count, error } = await db
    .from('inscricoes')
    .select('id', { count: 'exact', head: true })
    .eq('oferta_id', ofertaId);
  if (error) throw error;
  return count || 0;
}

// ---------- rotas publicas ----------

app.get('/api/vagas', async (req, res) => {
  try {
    const oferta = await ofertaAtual();
    if (!oferta) return res.json({ existe: false });

    const ocupadas = await contarInscricoes(oferta.id);
    const restantes = Math.max(oferta.vagas_total - ocupadas, 0);

    res.json({
      existe: true,
      id: oferta.id,
      titulo: oferta.titulo,
      detalhe: oferta.detalhe,
      total: oferta.vagas_total,
      ocupadas,
      restantes,
      aberta: oferta.aberta && restantes > 0,
      niveis: NIVEIS,
    });
  } catch (e) {
    console.error(e);
    res.status(500).json({ erro: 'Não foi possível carregar as vagas. Tente de novo.' });
  }
});

app.post('/api/inscricoes', async (req, res) => {
  try {
    const nome = String(req.body.nome || '').trim();
    const nivel = String(req.body.nivel || '').trim();
    const whatsapp = String(req.body.whatsapp || '').trim();

    if (nome.length < 3) return res.status(400).json({ erro: 'Escreva seu nome completo.' });
    if (!NIVEIS.includes(nivel)) return res.status(400).json({ erro: 'Escolha o seu nível.' });

    const oferta = await ofertaAtual();
    if (!oferta) return res.status(409).json({ erro: 'Não há vagas abertas agora.' });

    const { data, error } = await db.rpc('inscrever', {
      p_oferta_id: oferta.id,
      p_nome: nome,
      p_nivel: nivel,
      p_whatsapp: whatsapp,
    });
    if (error) throw error;

    if (!data.ok) {
      const mensagens = {
        fechada: 'As inscrições desta rodada foram encerradas.',
        esgotada: 'As vagas acabaram de ser preenchidas.',
        duplicada: 'Esse nome já está inscrito nesta rodada.',
        inexistente: 'Não há vagas abertas agora.',
      };
      return res.status(409).json({ erro: mensagens[data.motivo] || 'Não foi possível concluir.' });
    }

    res.json({ posicao: data.posicao, restantes: data.restantes });
  } catch (e) {
    console.error(e);
    res.status(500).json({ erro: 'Não foi possível concluir a inscrição. Tente de novo.' });
  }
});

// ---------- rotas de admin ----------

app.get('/api/admin/painel', exigirAdmin, async (req, res) => {
  try {
    const oferta = await ofertaAtual();
    if (!oferta) return res.json({ existe: false, niveis: NIVEIS });

    const { data: inscricoes, error } = await db
      .from('inscricoes')
      .select('*')
      .eq('oferta_id', oferta.id)
      .order('posicao', { ascending: true });
    if (error) throw error;

    res.json({
      existe: true,
      oferta,
      inscricoes,
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
    const vagas = parseInt(req.body.vagas_total, 10);

    if (!titulo) return res.status(400).json({ erro: 'Escreva um título para a rodada.' });
    if (!Number.isInteger(vagas) || vagas < 1) {
      return res.status(400).json({ erro: 'Informe quantas vagas você vai abrir.' });
    }

    const { data, error } = await db
      .from('ofertas')
      .insert({ titulo, detalhe: detalhe || null, vagas_total: vagas, aberta: true })
      .select()
      .single();
    if (error) throw error;

    res.json({ oferta: data });
  } catch (e) {
    console.error(e);
    res.status(500).json({ erro: 'Não foi possível abrir a rodada.' });
  }
});

app.patch('/api/admin/ofertas/:id', exigirAdmin, async (req, res) => {
  try {
    const patch = {};
    if (req.body.vagas_total !== undefined) {
      const vagas = parseInt(req.body.vagas_total, 10);
      if (!Number.isInteger(vagas) || vagas < 0) {
        return res.status(400).json({ erro: 'Número de vagas inválido.' });
      }
      patch.vagas_total = vagas;
    }
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
