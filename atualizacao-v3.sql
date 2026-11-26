-- =====================================================================
-- KNUPP TÊNIS · ÁREA DO ALUNO (v3)
-- ATUALIZAÇÃO QUE NÃO APAGA NADA. Rode inteiro no Supabase → SQL Editor → Run.
-- Pode rodar mais de uma vez sem problema.
-- =====================================================================

-- ---------------------------------------------------------------------
-- NOVAS COLUNAS
-- ---------------------------------------------------------------------
alter table public.alunos add column if not exists valor_mensal numeric(10,2);
alter table public.alunos add column if not exists dia_vencimento int not null default 10;
alter table public.alunos add column if not exists responsavel text;
alter table public.alunos add column if not exists checklist jsonb not null default '{}';
alter table public.alunos add column if not exists codigo text;
alter table public.niveis add column if not exists criterios text[] not null default '{}';

update public.alunos set codigo = lower(substr(md5(id::text || nome || random()::text), 1, 6)) where codigo is null;
create unique index if not exists alunos_codigo_idx on public.alunos (codigo);

-- ---------------------------------------------------------------------
-- NOVAS TABELAS
-- ---------------------------------------------------------------------
create table if not exists public.contas (            -- PIN por número de WhatsApp (família usa o mesmo)
  wpp_chave  text primary key,
  pin_hash   text not null,
  criado_em  timestamptz not null default now()
);

create table if not exists public.sessoes (
  token      text primary key,
  wpp_chave  text not null,
  criado_em  timestamptz not null default now(),
  expira_em  timestamptz not null default now() + interval '180 days'
);

create table if not exists public.turmas (
  id          bigint generated always as identity primary key,
  nome        text,
  dia_semana  int not null check (dia_semana between 0 and 6),   -- 0 = domingo
  hora        time not null,
  nivel_id    int references public.niveis(id) on delete set null,
  capacidade  int not null default 4,
  ativo       boolean not null default true,
  criado_em   timestamptz not null default now()
);

create table if not exists public.turma_alunos (
  turma_id  bigint not null references public.turmas(id) on delete cascade,
  aluno_id  bigint not null references public.alunos(id) on delete cascade,
  primary key (turma_id, aluno_id)
);

create table if not exists public.mensalidades (
  id           bigint generated always as identity primary key,
  aluno_id     bigint not null references public.alunos(id) on delete cascade,
  competencia  date not null,                       -- sempre dia 1 do mês
  valor        numeric(10,2) not null,
  vencimento   date not null,
  status       text not null default 'pendente' check (status in ('pendente','informado','pago','isento')),
  forma        text,
  pago_em      timestamptz,
  recibo       int,
  observacao   text,
  criado_em    timestamptz not null default now(),
  unique (aluno_id, competencia)
);
create sequence if not exists public.recibo_seq start 1001;

create table if not exists public.aulas (
  id          bigint generated always as identity primary key,
  turma_id    bigint references public.turmas(id) on delete set null,
  horario_id  bigint references public.horarios(id) on delete set null,
  data        date not null,
  hora        time not null,
  status      text not null default 'realizada' check (status in ('realizada','cancelada')),
  tema        text,
  comentario  text,
  criado_em   timestamptz not null default now()
);
create unique index if not exists aulas_turma_dia on public.aulas (turma_id, data) where turma_id is not null;
create unique index if not exists aulas_horario on public.aulas (horario_id) where horario_id is not null;

create table if not exists public.presencas (
  aula_id     bigint not null references public.aulas(id) on delete cascade,
  aluno_id    bigint not null references public.alunos(id) on delete cascade,
  status      text not null default 'presente' check (status in ('presente','falta','reposicao')),
  comentario  text,
  nota_aluno  int check (nota_aluno between 1 and 5),
  comentario_aluno text,
  primary key (aula_id, aluno_id)
);

create table if not exists public.avaliacoes (
  id          bigint generated always as identity primary key,
  aluno_id    bigint not null references public.alunos(id) on delete cascade,
  data        date not null default (now() at time zone 'America/Sao_Paulo')::date,
  notas       jsonb not null,
  observacao  text,
  criado_em   timestamptz not null default now()
);

create table if not exists public.conteudos (
  id          bigint generated always as identity primary key,
  titulo      text not null,
  url         text,
  descricao   text,
  nivel_ids   int[] not null default '{}',
  criado_em   timestamptz not null default now()
);

create table if not exists public.avisos (
  id          bigint generated always as identity primary key,
  texto       text not null,
  ate         date,
  criado_em   timestamptz not null default now()
);

create table if not exists public.indicacoes (
  id           bigint generated always as identity primary key,
  aluno_id     bigint references public.alunos(id) on delete set null,
  nome         text not null,
  whatsapp     text,
  status       text not null default 'nova' check (status in ('nova','contatada','fechou','nao_fechou')),
  criado_em    timestamptz not null default now()
);

alter table public.contas       enable row level security;
alter table public.sessoes      enable row level security;
alter table public.turmas       enable row level security;
alter table public.turma_alunos enable row level security;
alter table public.mensalidades enable row level security;
alter table public.aulas        enable row level security;
alter table public.presencas    enable row level security;
alter table public.avaliacoes   enable row level security;
alter table public.conteudos    enable row level security;
alter table public.avisos       enable row level security;
alter table public.indicacoes   enable row level security;

-- ---------------------------------------------------------------------
-- AUXILIARES
-- ---------------------------------------------------------------------
create or replace function public.hoje_br() returns date
language sql stable as $$ select (now() at time zone 'America/Sao_Paulo')::date $$;

create or replace function public.em_dia(p_aluno bigint) returns boolean
language sql stable as $$
  select not exists (select 1 from public.mensalidades
                      where aluno_id = p_aluno and status = 'pendente' and vencimento < public.hoje_br())
$$;

-- cria as mensalidades do mês para quem tem valor cadastrado (não duplica)
create or replace function public.gerar_mensalidades(p_competencia date) returns int
language plpgsql as $$
declare v_mes date := date_trunc('month', p_competencia)::date; v_n int;
begin
  -- só gera a partir do mês em que o financeiro começou (para ninguém nascer "atrasado")
  if v_mes < coalesce((select (valor #>> '{}')::date from public.config where chave = 'financeiro_inicio'), v_mes) then
    return 0;
  end if;
  insert into public.mensalidades (aluno_id, competencia, valor, vencimento)
  select a.id, v_mes, a.valor_mensal,
         v_mes + (least(greatest(a.dia_vencimento, 1), extract(day from (v_mes + interval '1 month - 1 day'))::int) - 1)
    from public.alunos a
   where a.ativo and coalesce(a.valor_mensal, 0) > 0
  on conflict (aluno_id, competencia) do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- ---------------------------------------------------------------------
-- LOGIN (PIN)
-- ---------------------------------------------------------------------
create or replace function public.conta_status(p_whatsapp text) returns json
language sql stable as $$
  select json_build_object(
    'chave', public.wpp_chave(p_whatsapp),
    'existe', exists (select 1 from public.alunos where wpp_chave = public.wpp_chave(p_whatsapp) and ativo),
    'pin_hash', (select pin_hash from public.contas where wpp_chave = public.wpp_chave(p_whatsapp)))
$$;

create or replace function public.conta_definir_pin(p_whatsapp text, p_hash text) returns json
language plpgsql as $$
begin
  insert into public.contas (wpp_chave, pin_hash) values (public.wpp_chave(p_whatsapp), p_hash)
  on conflict (wpp_chave) do nothing;
  return json_build_object('ok', found);
end $$;

create or replace function public.sessao_criar(p_whatsapp text, p_token text) returns json
language plpgsql as $$
begin
  delete from public.sessoes where expira_em < now();
  insert into public.sessoes (token, wpp_chave) values (p_token, public.wpp_chave(p_whatsapp));
  return json_build_object('ok', true);
end $$;

-- devolve um WhatsApp válido para a sessão (ou null)
create or replace function public.sessao_wpp(p_token text) returns text
language sql stable as $$
  select a.whatsapp from public.sessoes s join public.alunos a on a.wpp_chave = s.wpp_chave and a.ativo
   where s.token = p_token and s.expira_em > now() limit 1
$$;

create or replace function public.sessao_sair(p_token text) returns json
language sql as $$ delete from public.sessoes where token = p_token; select json_build_object('ok', true) $$;

create or replace function public.admin_resetar_pin(p_whatsapp text) returns json
language plpgsql as $$
begin
  delete from public.contas where wpp_chave = public.wpp_chave(p_whatsapp);
  delete from public.sessoes where wpp_chave = public.wpp_chave(p_whatsapp);
  return json_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- REPOSIÇÃO: agora só com mensalidade em dia
-- ---------------------------------------------------------------------
create or replace function public.aluno_reservar(p_whatsapp text, p_aluno_id bigint, p_horario_id bigint) returns json
language plpgsql as $$
declare
  v_aluno   public.alunos%rowtype;
  v_h       public.horarios%rowtype;
  v_cred    bigint;
  v_res     bigint;
begin
  select * into v_aluno from public.alunos
   where id = p_aluno_id and wpp_chave = public.wpp_chave(p_whatsapp) and ativo;
  if not found then return json_build_object('ok', false, 'motivo', 'aluno'); end if;
  if not public.em_dia(v_aluno.id) then return json_build_object('ok', false, 'motivo', 'mensalidade'); end if;

  select * into v_h from public.horarios where id = p_horario_id for update;
  if not found or v_h.status = 'cancelado' then return json_build_object('ok', false, 'motivo', 'indisponivel'); end if;
  if v_h.abre_em > now() then return json_build_object('ok', false, 'motivo', 'nao_abriu'); end if;
  if public.inicio_horario(v_h.data, v_h.hora) <= now() then return json_build_object('ok', false, 'motivo', 'passou'); end if;
  if v_h.status = 'fechado' or public.ocupadas(v_h.id) >= v_h.vagas then
    return json_build_object('ok', false, 'motivo', 'lotado');
  end if;
  if cardinality(v_h.nivel_ids) > 0 and not (v_h.nivel_ids && v_aluno.nivel_ids) then
    return json_build_object('ok', false, 'motivo', 'nivel');
  end if;
  if exists (select 1 from public.reservas where horario_id = v_h.id and aluno_id = v_aluno.id
             and status in ('pendente','confirmada')) then
    return json_build_object('ok', false, 'motivo', 'ja_pediu');
  end if;

  select id into v_cred from public.creditos
   where aluno_id = v_aluno.id and status = 'disponivel' and expira_em > now()
   order by expira_em, id limit 1 for update skip locked;
  if v_cred is null then return json_build_object('ok', false, 'motivo', 'sem_credito'); end if;

  insert into public.reservas (horario_id, aluno_id, credito_id) values (v_h.id, v_aluno.id, v_cred) returning id into v_res;
  update public.creditos set status = 'reservado', reserva_id = v_res, atualizado_em = now() where id = v_cred;
  return json_build_object('ok', true, 'reserva_id', v_res);
end $$;

-- ---------------------------------------------------------------------
-- ÁREA DO ALUNO: tudo de uma vez
-- ---------------------------------------------------------------------
create or replace function public.aluno_area(p_whatsapp text) returns json
language plpgsql as $$
declare v_base json; v_extra json;
begin
  perform public.gerar_mensalidades(public.hoje_br());
  v_base := public.aluno_entrar(p_whatsapp);
  if not (v_base ->> 'ok')::boolean then return v_base; end if;

  select coalesce(json_object_agg(a.id, json_build_object(
      'em_dia', public.em_dia(a.id),
      'codigo', a.codigo,
      'valor_mensal', a.valor_mensal,
      'dia_vencimento', a.dia_vencimento,
      'checklist', a.checklist,
      'turmas', (select coalesce(json_agg(json_build_object('id', t.id, 'nome', t.nome, 'dia_semana', t.dia_semana,
                    'hora', t.hora, 'nivel_id', t.nivel_id) order by t.dia_semana, t.hora), '[]')
                   from public.turmas t join public.turma_alunos ta on ta.turma_id = t.id
                  where ta.aluno_id = a.id and t.ativo),
      'mensalidades', (select coalesce(json_agg(json_build_object('id', m.id, 'competencia', m.competencia, 'valor', m.valor,
                    'vencimento', m.vencimento, 'status', m.status, 'forma', m.forma, 'pago_em', m.pago_em, 'recibo', m.recibo)
                    order by m.competencia desc), '[]')
                   from (select * from public.mensalidades where aluno_id = a.id order by competencia desc limit 12) m),
      'aulas', (select coalesce(json_agg(json_build_object('aula_id', au.id, 'data', au.data, 'hora', au.hora,
                    'status_aula', au.status, 'tema', au.tema, 'comentario_geral', au.comentario,
                    'presenca', p.status, 'comentario', p.comentario, 'nota_aluno', p.nota_aluno)
                    order by au.data desc, au.hora desc), '[]')
                   from (select * from public.presencas where aluno_id = a.id) p
                   join public.aulas au on au.id = p.aula_id
                  where au.data >= public.hoje_br() - 180),
      'total_presencas', (select count(*) from public.presencas p join public.aulas au on au.id = p.aula_id
                           where p.aluno_id = a.id and p.status in ('presente','reposicao') and au.status = 'realizada'),
      'avaliacoes', (select coalesce(json_agg(json_build_object('data', v.data, 'notas', v.notas, 'observacao', v.observacao)
                    order by v.data, v.id), '[]') from public.avaliacoes v where v.aluno_id = a.id),
      'indicacoes', (select count(*) from public.indicacoes i where i.aluno_id = a.id),
      'indicacoes_fechadas', (select count(*) from public.indicacoes i where i.aluno_id = a.id and i.status = 'fechou')
    )), '{}') into v_extra
    from public.alunos a where a.wpp_chave = public.wpp_chave(p_whatsapp) and a.ativo;

  return (v_base::jsonb || jsonb_build_object(
    'extra', v_extra,
    'niveis_criterios', (select coalesce(jsonb_object_agg(id, criterios), '{}') from public.niveis),
    'conteudos', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'titulo', c.titulo, 'url', c.url,
                    'descricao', c.descricao, 'nivel_ids', c.nivel_ids) order by c.criado_em desc), '[]') from public.conteudos c),
    'avisos', (select coalesce(jsonb_agg(jsonb_build_object('texto', v.texto, 'criado_em', v.criado_em) order by v.criado_em desc), '[]')
                 from public.avisos v where v.ate is null or v.ate >= public.hoje_br())
  ))::json;
end $$;

create or replace function public.aluno_informar_pagamento(p_whatsapp text, p_mensalidade bigint) returns json
language plpgsql as $$
begin
  update public.mensalidades m set status = 'informado'
    from public.alunos a
   where m.id = p_mensalidade and a.id = m.aluno_id and a.wpp_chave = public.wpp_chave(p_whatsapp) and m.status = 'pendente';
  return json_build_object('ok', found);
end $$;

create or replace function public.aluno_avaliar_aula(p_whatsapp text, p_aluno_id bigint, p_aula_id bigint, p_nota int, p_comentario text default null) returns json
language plpgsql as $$
begin
  update public.presencas p set nota_aluno = greatest(1, least(5, p_nota)), comentario_aluno = nullif(btrim(p_comentario), '')
    from public.alunos a
   where p.aula_id = p_aula_id and p.aluno_id = p_aluno_id and a.id = p_aluno_id and a.wpp_chave = public.wpp_chave(p_whatsapp);
  return json_build_object('ok', found);
end $$;

create or replace function public.aluno_indicar(p_whatsapp text, p_aluno_id bigint, p_nome text, p_wpp_amigo text default null) returns json
language plpgsql as $$
begin
  if not exists (select 1 from public.alunos where id = p_aluno_id and wpp_chave = public.wpp_chave(p_whatsapp)) then
    return json_build_object('ok', false);
  end if;
  if coalesce(btrim(p_nome), '') = '' then return json_build_object('ok', false, 'motivo', 'nome'); end if;
  insert into public.indicacoes (aluno_id, nome, whatsapp) values (p_aluno_id, btrim(p_nome), public.wpp_numero(p_wpp_amigo));
  return json_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- PAINEL: dados extras
-- ---------------------------------------------------------------------
create or replace function public.admin_dados_v3() returns json
language plpgsql as $$
begin
  perform public.gerar_mensalidades(public.hoje_br());
  return (public.admin_dados()::jsonb || jsonb_build_object(
    'alunos_extra', (select coalesce(jsonb_object_agg(a.id, jsonb_build_object(
        'valor_mensal', a.valor_mensal, 'dia_vencimento', a.dia_vencimento, 'responsavel', a.responsavel,
        'checklist', a.checklist, 'em_dia', public.em_dia(a.id),
        'tem_pin', exists (select 1 from public.contas c where c.wpp_chave = a.wpp_chave),
        'turma_ids', (select coalesce(jsonb_agg(ta.turma_id), '[]') from public.turma_alunos ta where ta.aluno_id = a.id))), '{}')
      from public.alunos a),
    'turmas', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'nome', t.nome, 'dia_semana', t.dia_semana, 'hora', t.hora,
        'nivel_id', t.nivel_id, 'capacidade', t.capacidade, 'ativo', t.ativo,
        'aluno_ids', (select coalesce(jsonb_agg(ta.aluno_id), '[]') from public.turma_alunos ta where ta.turma_id = t.id))
        order by t.dia_semana, t.hora), '[]') from public.turmas t),
    'conteudos', (select coalesce(jsonb_agg(to_jsonb(c) order by c.criado_em desc), '[]') from public.conteudos c),
    'avisos', (select coalesce(jsonb_agg(to_jsonb(v) order by v.criado_em desc), '[]') from public.avisos v),
    'indicacoes', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'nome', i.nome, 'whatsapp', i.whatsapp, 'status', i.status,
        'criado_em', i.criado_em, 'indicador', a.nome) order by i.criado_em desc), '[]')
        from public.indicacoes i left join public.alunos a on a.id = i.aluno_id),
    'pendencias', jsonb_build_object(
        'atrasadas', (select count(*) from public.mensalidades where status = 'pendente' and vencimento < public.hoje_br()),
        'informadas', (select count(*) from public.mensalidades where status = 'informado'),
        'indicacoes_novas', (select count(*) from public.indicacoes where status = 'nova'))
  ))::json;
end $$;

-- extras do aluno (não mexe na função antiga)
create or replace function public.admin_salvar_aluno_extra(p_id bigint, p_valor numeric default null, p_dia int default 10, p_responsavel text default null,
  p_checklist jsonb default null, p_turma_ids bigint[] default null) returns json
language plpgsql as $$
begin
  update public.alunos set valor_mensal = p_valor, dia_vencimento = coalesce(p_dia, 10),
         responsavel = nullif(btrim(p_responsavel), ''), checklist = coalesce(p_checklist, checklist)
   where id = p_id;
  if p_turma_ids is not null then
    delete from public.turma_alunos where aluno_id = p_id;
    insert into public.turma_alunos (turma_id, aluno_id) select unnest(p_turma_ids), p_id on conflict do nothing;
  end if;
  return json_build_object('ok', found);
end $$;

-- Turmas ------------------------------------------------------------------
create or replace function public.admin_salvar_turma(p_id bigint default null, p_nome text default null, p_dia int default 1, p_hora time default '18:00', p_nivel_id int default null,
  p_capacidade int default 4, p_aluno_ids bigint[] default null, p_ativo boolean default true) returns json
language plpgsql as $$
declare v_id bigint;
begin
  if p_id is null then
    insert into public.turmas (nome, dia_semana, hora, nivel_id, capacidade, ativo)
    values (nullif(btrim(p_nome), ''), p_dia, p_hora, p_nivel_id, coalesce(p_capacidade, 4), coalesce(p_ativo, true)) returning id into v_id;
  else
    update public.turmas set nome = nullif(btrim(p_nome), ''), dia_semana = p_dia, hora = p_hora, nivel_id = p_nivel_id,
           capacidade = coalesce(p_capacidade, 4), ativo = coalesce(p_ativo, true) where id = p_id returning id into v_id;
  end if;
  if v_id is not null and p_aluno_ids is not null then
    delete from public.turma_alunos where turma_id = v_id;
    insert into public.turma_alunos (turma_id, aluno_id) select v_id, unnest(p_aluno_ids) on conflict do nothing;
  end if;
  return json_build_object('ok', v_id is not null, 'id', v_id);
end $$;

create or replace function public.admin_excluir_turma(p_id bigint) returns json
language plpgsql as $$ begin delete from public.turmas where id = p_id; return json_build_object('ok', found); end $$;

-- Financeiro --------------------------------------------------------------
create or replace function public.admin_financeiro(p_mes date) returns json
language plpgsql as $$
declare v_mes date := date_trunc('month', p_mes)::date;
begin
  if v_mes <= date_trunc('month', public.hoje_br() + 40)::date then perform public.gerar_mensalidades(v_mes); end if;
  return json_build_object(
    'mes', v_mes,
    'itens', (select coalesce(json_agg(json_build_object('id', m.id, 'aluno_id', m.aluno_id, 'nome', a.nome, 'whatsapp', a.whatsapp,
        'responsavel', a.responsavel, 'valor', m.valor, 'vencimento', m.vencimento, 'status', m.status, 'forma', m.forma,
        'pago_em', m.pago_em, 'recibo', m.recibo, 'observacao', m.observacao) order by a.nome), '[]')
        from public.mensalidades m join public.alunos a on a.id = m.aluno_id where m.competencia = v_mes),
    'atrasadas_outros_meses', (select coalesce(json_agg(json_build_object('id', m.id, 'nome', a.nome, 'whatsapp', a.whatsapp,
        'valor', m.valor, 'vencimento', m.vencimento, 'competencia', m.competencia, 'status', m.status)), '[]')
        from public.mensalidades m join public.alunos a on a.id = m.aluno_id
        where m.competencia < v_mes and m.status in ('pendente','informado')),
    'historico', (select coalesce(json_agg(x order by x.mes), '[]') from (
        select to_char(competencia, 'YYYY-MM') as mes, sum(valor) filter (where status = 'pago') as recebido, sum(valor) as previsto
          from public.mensalidades where competencia >= v_mes - interval '5 months' and competencia <= v_mes group by 1) x)
  );
end $$;

create or replace function public.admin_mensalidade(p_id bigint, p_status text default null, p_forma text default null, p_valor numeric default null, p_observacao text default null) returns json
language plpgsql as $$
begin
  update public.mensalidades set
    status = coalesce(p_status, status),
    forma = case when p_status = 'pago' then coalesce(nullif(p_forma, ''), forma, 'PIX') when p_status in ('pendente','informado') then null else forma end,
    pago_em = case when p_status = 'pago' then coalesce(pago_em, now()) when p_status in ('pendente','informado') then null else pago_em end,
    recibo = case when p_status = 'pago' then coalesce(recibo, nextval('public.recibo_seq')::int) else recibo end,
    valor = coalesce(p_valor, valor),
    observacao = coalesce(nullif(btrim(p_observacao), ''), observacao)
   where id = p_id;
  return json_build_object('ok', found);
end $$;

create or replace function public.admin_excluir_mensalidade(p_id bigint) returns json
language plpgsql as $$ begin delete from public.mensalidades where id = p_id; return json_build_object('ok', found); end $$;

-- Aulas / chamada / diário -----------------------------------------------
create or replace function public.admin_aulas_dia(p_data date) returns json
language sql stable as $$
  select json_build_object(
    'data', p_data,
    'turmas', (select coalesce(json_agg(json_build_object('turma_id', t.id, 'nome', t.nome, 'hora', t.hora, 'nivel_id', t.nivel_id,
        'aluno_ids', (select coalesce(json_agg(ta.aluno_id), '[]') from public.turma_alunos ta join public.alunos al on al.id = ta.aluno_id
                       where ta.turma_id = t.id and al.ativo),
        'aula', (select to_json(au) from public.aulas au where au.turma_id = t.id and au.data = p_data),
        'reposicoes', (select coalesce(json_agg(json_build_object('aluno_id', r.aluno_id, 'nome', a.nome)), '[]')
                         from public.horarios h join public.reservas r on r.horario_id = h.id and r.status = 'confirmada'
                         join public.alunos a on a.id = r.aluno_id
                        where h.data = p_data and h.hora = t.hora and h.status <> 'cancelado'))
        order by t.hora), '[]')
      from public.turmas t where t.ativo and t.dia_semana = extract(dow from p_data)::int),
    'presencas', (select coalesce(json_agg(json_build_object('aula_id', p.aula_id, 'aluno_id', p.aluno_id, 'status', p.status,
        'comentario', p.comentario, 'nota_aluno', p.nota_aluno, 'comentario_aluno', p.comentario_aluno)), '[]')
      from public.presencas p join public.aulas au on au.id = p.aula_id where au.data = p_data)
  )
$$;

-- salva a chamada e o diário de uma turma num dia
create or replace function public.admin_salvar_aula(p_turma_id bigint, p_data date, p_hora time, p_status text default 'realizada',
  p_tema text default null, p_comentario text default null, p_presencas jsonb default '[]') returns json
language plpgsql as $$
declare v_id bigint; v jsonb;
begin
  select id into v_id from public.aulas where turma_id = p_turma_id and data = p_data;
  if v_id is null then
    insert into public.aulas (turma_id, data, hora, status, tema, comentario)
    values (p_turma_id, p_data, p_hora, coalesce(p_status, 'realizada'), nullif(btrim(p_tema), ''), nullif(btrim(p_comentario), ''))
    returning id into v_id;
  else
    update public.aulas set status = coalesce(p_status, 'realizada'), tema = nullif(btrim(p_tema), ''),
           comentario = nullif(btrim(p_comentario), ''), hora = p_hora where id = v_id;
  end if;
  for v in select * from jsonb_array_elements(coalesce(p_presencas, '[]')) loop
    insert into public.presencas (aula_id, aluno_id, status, comentario)
    values (v_id, (v ->> 'aluno_id')::bigint, coalesce(v ->> 'status', 'presente'), nullif(btrim(v ->> 'comentario'), ''))
    on conflict (aula_id, aluno_id) do update set status = excluded.status, comentario = excluded.comentario;
  end loop;
  delete from public.presencas p where p.aula_id = v_id
    and not exists (select 1 from jsonb_array_elements(coalesce(p_presencas, '[]')) x where (x ->> 'aluno_id')::bigint = p.aluno_id);
  return json_build_object('ok', true, 'id', v_id);
end $$;

-- Avaliação técnica ----------------------------------------------------------
create or replace function public.admin_salvar_avaliacao(p_aluno_id bigint, p_data date default null, p_notas jsonb default '{}', p_observacao text default null) returns json
language plpgsql as $$
declare v_id bigint;
begin
  insert into public.avaliacoes (aluno_id, data, notas, observacao)
  values (p_aluno_id, coalesce(p_data, public.hoje_br()), p_notas, nullif(btrim(p_observacao), '')) returning id into v_id;
  return json_build_object('ok', true, 'id', v_id);
end $$;

create or replace function public.admin_avaliacoes(p_aluno_id bigint) returns json
language sql stable as $$
  select coalesce(json_agg(json_build_object('id', id, 'data', data, 'notas', notas, 'observacao', observacao) order by data desc, id desc), '[]')
    from public.avaliacoes where aluno_id = p_aluno_id
$$;

create or replace function public.admin_excluir_avaliacao(p_id bigint) returns json
language plpgsql as $$ begin delete from public.avaliacoes where id = p_id; return json_build_object('ok', found); end $$;

create or replace function public.admin_nivel_criterios(p_id int, p_criterios text[]) returns json
language plpgsql as $$
begin
  update public.niveis set criterios = coalesce(p_criterios, '{}') where id = p_id;
  return json_build_object('ok', found);
end $$;

-- Conteúdo, avisos, indicações ---------------------------------------------
create or replace function public.admin_salvar_conteudo(p_id bigint default null, p_titulo text default null, p_url text default null, p_descricao text default null, p_nivel_ids int[] default '{}') returns json
language plpgsql as $$
begin
  if p_id is null then
    insert into public.conteudos (titulo, url, descricao, nivel_ids) values (btrim(p_titulo), nullif(btrim(p_url), ''), nullif(btrim(p_descricao), ''), coalesce(p_nivel_ids, '{}'));
  else
    update public.conteudos set titulo = btrim(p_titulo), url = nullif(btrim(p_url), ''), descricao = nullif(btrim(p_descricao), ''),
           nivel_ids = coalesce(p_nivel_ids, '{}') where id = p_id;
  end if;
  return json_build_object('ok', true);
end $$;
create or replace function public.admin_excluir_conteudo(p_id bigint) returns json
language plpgsql as $$ begin delete from public.conteudos where id = p_id; return json_build_object('ok', found); end $$;

create or replace function public.admin_salvar_aviso(p_texto text, p_ate date default null) returns json
language plpgsql as $$ begin insert into public.avisos (texto, ate) values (btrim(p_texto), p_ate); return json_build_object('ok', true); end $$;
create or replace function public.admin_excluir_aviso(p_id bigint) returns json
language plpgsql as $$ begin delete from public.avisos where id = p_id; return json_build_object('ok', found); end $$;

create or replace function public.admin_indicacao_status(p_id bigint, p_status text) returns json
language plpgsql as $$ begin update public.indicacoes set status = p_status where id = p_id; return json_build_object('ok', found); end $$;

-- =====================================================================
-- DADOS INICIAIS
-- =====================================================================
-- critérios para subir de nível (edite no painel → Ajustes → Níveis)
update public.niveis set criterios = array['Empunhadura correta no forehand e backhand','Mantém 10 bolas seguidas no fundo','Saque por cima entrando','Conhece a contagem de pontos']
 where nome = 'Iniciante' and cardinality(criterios) = 0;
update public.niveis set criterios = array['Rally de 20 bolas com direção','Backhand consistente na cruzada','Saque com segundo saque seguro','Joga um set completo com contagem']
 where nome = 'Básico' and cardinality(criterios) = 0;
update public.niveis set criterios = array['Varia altura e profundidade','Aproximação e voleio','Devolução de saque agressiva','Estratégia de pontos']
 where nome = 'Intermediário' and cardinality(criterios) = 0;
update public.niveis set criterios = array['Saque com efeito (slice/kick)','Transição defesa-ataque','Jogo de rede completo','Joga torneios']
 where nome = 'Avançado' and cardinality(criterios) = 0;
update public.niveis set criterios = array['Coordenação e deslocamento','Rebate a bola por cima da rede','Troca de bolas com o professor','Saque por baixo']
 where nome like 'Kids%' and cardinality(criterios) = 0;

-- mensalidades dos prints do TennisCoach (só preenche quem ainda está sem valor)
update public.alunos a set valor_mensal = v.valor from (values
 ('Paulo',1090),('Bernardo',900),('Adrian',550),('Camila',260),('Joãozinho',470),('Davizinho',470),('Gustavo',460),
 ('Filipinho',375),('Joil',365),('Giovanni',260),('Nahun',260),('Juan',350),('Murilo',305),('Breno',312),('Flavio',260),
 ('Fabio',260),('Victor',210),('Heitor',210),('Luiza',210),('Clarice',210),('Claudio',210),('Simone',210),('Ronaldo',210),
 ('Sergio',210),('Patricia',210),('Mariana',210),('Nanaia',210),('Sophia',260),('Gabriel',375),('Bruninho',200),('Kaio',200),
 ('Gigi',260),('Davi Gio',260),('Pedro Miguel',375),('Vitor Sartorio',210),('Hiago',375),('Millene',210),('Luiza Keila',200),
 ('Fred',490),('Gabriel (Avançado)',315),('João Lucas',375),('Guilherme Cantarino',565),('Gabriela',315),('Vivian',260),
 ('Julia',260),('Matheus Pena',450),('Camila Pinheiro',470),('Igor',250),('Jose',210),('Laura T',210),('Leozinho',260),
 ('Filha Hiago',210),('Thais',422),('Jhanna',450),('Savio',422),('Laura',260),('Melina',260),('Daniel',260)
) as v(nome, valor) where a.nome = v.nome and a.valor_mensal is null;

insert into public.config (chave, valor) values
  ('pix_chave', '""'), ('pix_nome', '"Matheus Knupp"'), ('pix_cidade', '"Cabo Frio"'),
  ('msg_cobranca', '"Oi, {nome}! Passando para lembrar da mensalidade de {mes} ({valor}), com vencimento em {vencimento}. Você pode pagar pelo PIX direto na sua área do aluno 👉 {link}"'),
  ('msg_lembrete_aula', '"Oi, {nome}! Lembrete da sua aula {dia} às {hora} 🎾 Te espero na quadra!"'),
  ('indicacao_beneficio', '"Indicou um amigo e ele fechou? Você ganha uma aula de reposição de presente!"'),
  ('financeiro_inicio', to_jsonb(to_char(date_trunc('month', (now() at time zone 'America/Sao_Paulo')) + interval '1 month', 'YYYY-MM-DD'))),
  ('habilidades', '["Forehand","Backhand","Saque","Devolução","Voleio","Movimentação","Tático","Mental"]')
on conflict (chave) do nothing;

-- as mensalidades começam no mês que vem (dá para mudar em Ajustes)
select public.gerar_mensalidades((now() at time zone 'America/Sao_Paulo')::date) as mensalidades_criadas;

notify pgrst, 'reload schema';
