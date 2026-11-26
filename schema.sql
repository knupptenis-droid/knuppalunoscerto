-- =====================================================================
-- KNUPP TÊNIS · REPOSIÇÕES 2.0  (créditos de reposição)
-- Rode este arquivo INTEIRO no Supabase → SQL Editor → New query → Run.
-- ATENÇÃO: APAGA TUDO e recria do zero. Use só na primeira instalação.
-- Para atualizar um site que já está no ar, use os arquivos atualizacao-*.sql.
-- Pode rodar de novo sem medo: ele recria tudo do zero.
-- =====================================================================

drop table if exists public.inscricoes cascade;
drop table if exists public.ofertas cascade;
drop function if exists public.inscrever(bigint, text, text, text);

drop table if exists public.pedidos cascade;
drop table if exists public.produtos cascade;
drop table if exists public.presencas cascade;
drop table if exists public.aulas cascade;
drop table if exists public.turma_alunos cascade;
drop table if exists public.turmas cascade;
drop table if exists public.mensalidades cascade;
drop table if exists public.avaliacoes cascade;
drop table if exists public.conteudos cascade;
drop table if exists public.avisos cascade;
drop table if exists public.indicacoes cascade;
drop table if exists public.contas cascade;
drop table if exists public.sessoes cascade;
drop table if exists public.reservas cascade;
drop table if exists public.creditos cascade;
drop table if exists public.horarios cascade;
drop table if exists public.alunos cascade;
drop table if exists public.niveis cascade;
drop table if exists public.config cascade;

-- ---------------------------------------------------------------------
-- TABELAS
-- ---------------------------------------------------------------------
create table public.niveis (
  id     serial primary key,
  nome   text not null unique,
  cor    text not null default '#2BD576',
  ordem  int  not null default 0,
  ativo  boolean not null default true
);

create table public.alunos (
  id          bigint generated always as identity primary key,
  nome        text not null,
  whatsapp    text,                      -- só números, com 55 na frente
  wpp_chave   text,                      -- DDD + 8 últimos dígitos (para achar o aluno)
  nivel_ids   int[] not null default '{}',
  turmas      text[] not null default '{}',
  observacao  text,
  ativo       boolean not null default true,
  criado_em   timestamptz not null default now()
);
create index alunos_wpp_idx on public.alunos (wpp_chave);

create table public.horarios (
  id          bigint generated always as identity primary key,
  data        date not null,
  hora        time not null,
  nivel_ids   int[] not null default '{}',
  vagas       int  not null check (vagas >= 0),
  observacao  text,
  abre_em     timestamptz not null,
  status      text not null default 'ativo' check (status in ('ativo','fechado','cancelado')),
  motivo_cancelamento text,
  criado_em   timestamptz not null default now()
);
create index horarios_data_idx on public.horarios (data, hora);

create table public.reservas (
  id            bigint generated always as identity primary key,
  horario_id    bigint not null references public.horarios(id) on delete cascade,
  aluno_id      bigint not null references public.alunos(id) on delete cascade,
  credito_id    bigint,
  status        text not null default 'pendente'
                check (status in ('pendente','confirmada','cancelada_aluno','cancelada_chuva','recusada')),
  perdeu_credito boolean not null default false,
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create unique index reservas_ativa_unica on public.reservas (horario_id, aluno_id)
  where status in ('pendente','confirmada');

create table public.creditos (
  id          bigint generated always as identity primary key,
  aluno_id    bigint not null references public.alunos(id) on delete cascade,
  origem      text not null default 'manual' check (origem in ('chuva','manual','devolucao')),
  motivo      text,
  status      text not null default 'disponivel'
              check (status in ('disponivel','reservado','usado','perdido','removido')),
  reserva_id  bigint references public.reservas(id) on delete set null,
  criado_em   timestamptz not null default now(),
  expira_em   timestamptz not null,
  atualizado_em timestamptz not null default now()
);
create index creditos_aluno_idx on public.creditos (aluno_id, status, expira_em);

alter table public.reservas
  add constraint reservas_credito_fk foreign key (credito_id) references public.creditos(id) on delete set null;

create table public.config (
  chave  text primary key,
  valor  jsonb not null
);

-- Nada é acessível direto pelo navegador: tudo passa pelo servidor.
alter table public.niveis   enable row level security;
alter table public.alunos   enable row level security;
alter table public.horarios enable row level security;
alter table public.reservas enable row level security;
alter table public.creditos enable row level security;
alter table public.config   enable row level security;

-- ---------------------------------------------------------------------
-- FUNÇÕES AUXILIARES
-- ---------------------------------------------------------------------
create or replace function public.wpp_numero(p text) returns text
language sql immutable as $$
  select case
    when p is null then null
    when length(regexp_replace(p, '\D', '', 'g')) < 10 then null
    when length(regexp_replace(p, '\D', '', 'g')) >= 12 and left(regexp_replace(p, '\D', '', 'g'), 2) = '55'
      then regexp_replace(p, '\D', '', 'g')
    else '55' || regexp_replace(p, '\D', '', 'g')
  end
$$;

create or replace function public.wpp_chave(p text) returns text
language sql immutable as $$
  select case when public.wpp_numero(p) is null then null
    else substr(public.wpp_numero(p), 3, 2) || right(public.wpp_numero(p), 8) end
$$;

create or replace function public.agora_br() returns timestamp
language sql stable as $$ select (now() at time zone 'America/Sao_Paulo') $$;

-- início da aula como timestamptz
create or replace function public.inicio_horario(p_data date, p_hora time) returns timestamptz
language sql immutable as $$ select ((p_data + p_hora) at time zone 'America/Sao_Paulo') $$;

-- regra padrão: abre na véspera às 14h (segunda abre no domingo 14h)
create or replace function public.abertura_padrao(p_data date) returns timestamptz
language sql stable as $$
  select (((p_data - 1) + (coalesce((select (valor #>> '{}') from public.config where chave = 'hora_abertura'), '14:00'))::time)
          at time zone 'America/Sao_Paulo')
$$;

create or replace function public.validade_dias() returns int
language sql stable as $$
  select coalesce((select (valor #>> '{}')::int from public.config where chave = 'validade_dias'), 40)
$$;

create or replace function public.ocupadas(p_horario bigint) returns int
language sql stable as $$
  select count(*)::int from public.reservas where horario_id = p_horario and status in ('pendente','confirmada')
$$;

create or replace function public.creditos_disponiveis(p_aluno bigint) returns int
language sql stable as $$
  select count(*)::int from public.creditos
  where aluno_id = p_aluno and status = 'disponivel' and expira_em > now()
$$;

-- devolve o crédito de uma reserva (aula de reposição cancelada / recusada)
create or replace function public.devolver_credito(p_reserva bigint) returns void
language plpgsql as $$
begin
  update public.creditos
     set status = 'disponivel', reserva_id = null, atualizado_em = now(),
         expira_em = greatest(expira_em, now() + make_interval(days => public.validade_dias()))
   where reserva_id = p_reserva and status in ('reservado','usado');
end $$;

-- ---------------------------------------------------------------------
-- ÁREA DO ALUNO
-- ---------------------------------------------------------------------

-- Tudo que a página pública precisa (sem dados de alunos)
create or replace function public.publico_info() returns json
language sql stable as $$
  select json_build_object(
    'agora', now(),
    'niveis', (select coalesce(json_agg(n order by n.ordem, n.nome), '[]') from public.niveis n where n.ativo),
    'config', (select coalesce(json_object_agg(chave, valor), '{}') from public.config where chave <> 'senha'),
    'proxima_abertura', (select min(abre_em) from public.horarios
                           where status = 'ativo' and abre_em > now()),
    'abertos_agora', (select count(*) from public.horarios h
                       where h.status = 'ativo' and h.abre_em <= now()
                         and public.inicio_horario(h.data, h.hora) > now()
                         and public.ocupadas(h.id) < h.vagas)
  )
$$;

-- Aluno entra pelo WhatsApp: devolve os alunos daquele número + vagas abertas
create or replace function public.aluno_entrar(p_whatsapp text) returns json
language plpgsql stable as $$
declare
  v_chave text := public.wpp_chave(p_whatsapp);
  v_alunos json;
begin
  if v_chave is null then
    return json_build_object('ok', false, 'motivo', 'numero_invalido');
  end if;

  select json_agg(x order by x.nome) into v_alunos from (
    select a.id, a.nome, a.nivel_ids,
      public.creditos_disponiveis(a.id) as creditos,
      (select coalesce(json_agg(json_build_object('id', c.id, 'expira_em', c.expira_em, 'origem', c.origem, 'motivo', c.motivo)
               order by c.expira_em), '[]')
         from public.creditos c
        where c.aluno_id = a.id and c.status = 'disponivel' and c.expira_em > now()) as lista_creditos,
      (select coalesce(json_agg(json_build_object(
                'id', r.id, 'status', r.status, 'perdeu_credito', r.perdeu_credito,
                'horario_id', h.id, 'data', h.data, 'hora', h.hora, 'observacao', h.observacao,
                'motivo_cancelamento', h.motivo_cancelamento)
               order by h.data desc, h.hora desc), '[]')
         from public.reservas r join public.horarios h on h.id = r.horario_id
        where r.aluno_id = a.id
          and h.data >= (public.agora_br())::date - 7) as reservas
    from public.alunos a
    where a.wpp_chave = v_chave and a.ativo
  ) x;

  if v_alunos is null then
    return json_build_object('ok', false, 'motivo', 'nao_cadastrado');
  end if;

  return json_build_object(
    'ok', true,
    'alunos', v_alunos,
    'horarios', (
      select coalesce(json_agg(json_build_object(
          'id', h.id, 'data', h.data, 'hora', h.hora, 'nivel_ids', h.nivel_ids,
          'observacao', h.observacao, 'lotado', public.ocupadas(h.id) >= h.vagas or h.status = 'fechado')
        order by h.data, h.hora), '[]')
      from public.horarios h
      where h.status in ('ativo','fechado')
        and h.abre_em <= now()
        and public.inicio_horario(h.data, h.hora) > now()
    )
  );
end $$;

-- Pedir uma vaga (atômico: trava o horário, ninguém pega a mesma vaga)
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
   order by expira_em, id
   limit 1 for update skip locked;
  if v_cred is null then return json_build_object('ok', false, 'motivo', 'sem_credito'); end if;

  insert into public.reservas (horario_id, aluno_id, credito_id)
  values (v_h.id, v_aluno.id, v_cred) returning id into v_res;

  update public.creditos set status = 'reservado', reserva_id = v_res, atualizado_em = now() where id = v_cred;

  if public.ocupadas(v_h.id) >= v_h.vagas then
    -- lotou: continua "ativo" mas aparece como lotado
    null;
  end if;

  return json_build_object('ok', true, 'reserva_id', v_res);
end $$;

-- Aluno cancela: antes da confirmação o crédito volta; depois, perde o crédito
create or replace function public.aluno_cancelar(p_whatsapp text, p_reserva_id bigint) returns json
language plpgsql as $$
declare
  v_r public.reservas%rowtype;
  v_perde boolean;
begin
  select r.* into v_r from public.reservas r join public.alunos a on a.id = r.aluno_id
   where r.id = p_reserva_id and a.wpp_chave = public.wpp_chave(p_whatsapp)
   for update of r;
  if not found then return json_build_object('ok', false, 'motivo', 'nao_encontrada'); end if;
  if v_r.status not in ('pendente','confirmada') then return json_build_object('ok', false, 'motivo', 'ja_cancelada'); end if;

  v_perde := v_r.status = 'confirmada';
  update public.reservas set status = 'cancelada_aluno', perdeu_credito = v_perde, atualizado_em = now()
   where id = v_r.id;

  if v_perde then
    update public.creditos set status = 'perdido', atualizado_em = now() where reserva_id = v_r.id;
  else
    update public.creditos set status = 'disponivel', reserva_id = null, atualizado_em = now() where reserva_id = v_r.id;
  end if;
  return json_build_object('ok', true, 'perdeu_credito', v_perde);
end $$;

-- ---------------------------------------------------------------------
-- ÁREA DO PROFESSOR (admin)
-- ---------------------------------------------------------------------

create or replace function public.admin_dados() returns json
language sql stable as $$
  select json_build_object(
    'agora', now(),
    'niveis', (select coalesce(json_agg(n order by n.ordem, n.nome), '[]') from public.niveis n),
    'config', (select coalesce(json_object_agg(chave, valor), '{}') from public.config),
    'alunos', (select coalesce(json_agg(json_build_object(
          'id', a.id, 'nome', a.nome, 'whatsapp', a.whatsapp, 'nivel_ids', a.nivel_ids, 'turmas', a.turmas,
          'observacao', a.observacao, 'ativo', a.ativo,
          'creditos', public.creditos_disponiveis(a.id),
          'proximo_vencimento', (select min(expira_em) from public.creditos c
                                  where c.aluno_id = a.id and c.status = 'disponivel' and c.expira_em > now()))
        order by a.nome), '[]') from public.alunos a),
    'horarios', (select coalesce(json_agg(json_build_object(
          'id', h.id, 'data', h.data, 'hora', h.hora, 'nivel_ids', h.nivel_ids, 'vagas', h.vagas,
          'observacao', h.observacao, 'abre_em', h.abre_em, 'status', h.status,
          'motivo_cancelamento', h.motivo_cancelamento, 'ocupadas', public.ocupadas(h.id),
          'reservas', (select coalesce(json_agg(json_build_object(
                'id', r.id, 'status', r.status, 'aluno_id', r.aluno_id, 'nome', a.nome, 'whatsapp', a.whatsapp,
                'perdeu_credito', r.perdeu_credito, 'criado_em', r.criado_em) order by r.criado_em), '[]')
              from public.reservas r join public.alunos a on a.id = r.aluno_id where r.horario_id = h.id))
        order by h.data desc, h.hora desc), '[]')
      from public.horarios h where h.data >= (public.agora_br())::date - 30),
    'creditos', (select coalesce(json_agg(json_build_object(
          'id', c.id, 'aluno_id', c.aluno_id, 'nome', a.nome, 'origem', c.origem, 'motivo', c.motivo,
          'status', case when c.status = 'disponivel' and c.expira_em <= now() then 'vencido' else c.status end,
          'criado_em', c.criado_em, 'expira_em', c.expira_em) order by c.criado_em desc), '[]')
      from public.creditos c join public.alunos a on a.id = c.aluno_id
      where c.criado_em >= now() - interval '120 days')
  )
$$;

-- Horários ---------------------------------------------------------------
create or replace function public.admin_salvar_horario(
  p_id bigint, p_data date, p_hora time, p_nivel_ids int[], p_vagas int,
  p_observacao text, p_abre_em timestamptz) returns json
language plpgsql as $$
declare v_id bigint;
begin
  if p_id is null then
    insert into public.horarios (data, hora, nivel_ids, vagas, observacao, abre_em)
    values (p_data, p_hora, coalesce(p_nivel_ids, '{}'), p_vagas, nullif(btrim(p_observacao), ''),
            coalesce(p_abre_em, public.abertura_padrao(p_data)))
    returning id into v_id;
  else
    update public.horarios set data = p_data, hora = p_hora, nivel_ids = coalesce(p_nivel_ids, '{}'),
           vagas = p_vagas, observacao = nullif(btrim(p_observacao), ''),
           abre_em = coalesce(p_abre_em, public.abertura_padrao(p_data))
     where id = p_id returning id into v_id;
  end if;
  return json_build_object('ok', v_id is not null, 'id', v_id);
end $$;

create or replace function public.admin_status_horario(p_id bigint, p_status text) returns json
language plpgsql as $$
begin
  if p_status not in ('ativo','fechado') then return json_build_object('ok', false); end if;
  update public.horarios set status = p_status where id = p_id and status <> 'cancelado';
  return json_build_object('ok', found);
end $$;

create or replace function public.admin_abrir_agora(p_id bigint) returns json
language plpgsql as $$
begin
  update public.horarios set abre_em = now() where id = p_id;
  return json_build_object('ok', found);
end $$;

-- Cancelar horário de reposição (chuva): devolve crédito de todo mundo
create or replace function public.admin_cancelar_horario(p_id bigint, p_motivo text) returns json
language plpgsql as $$
declare v_afetados json;
begin
  select coalesce(json_agg(json_build_object('nome', a.nome, 'whatsapp', a.whatsapp)), '[]') into v_afetados
    from public.reservas r join public.alunos a on a.id = r.aluno_id
   where r.horario_id = p_id and r.status in ('pendente','confirmada');

  perform public.devolver_credito(r.id) from public.reservas r
   where r.horario_id = p_id and r.status in ('pendente','confirmada');
  update public.reservas set status = 'cancelada_chuva', atualizado_em = now()
   where horario_id = p_id and status in ('pendente','confirmada');
  update public.horarios set status = 'cancelado', motivo_cancelamento = nullif(btrim(p_motivo), '') where id = p_id;
  return json_build_object('ok', true, 'afetados', v_afetados);
end $$;

-- Apagar horário de vez (se tinha gente marcada, o crédito volta antes)
create or replace function public.admin_excluir_horario(p_id bigint) returns json
language plpgsql as $$
begin
  perform public.devolver_credito(r.id) from public.reservas r
   where r.horario_id = p_id and r.status in ('pendente','confirmada');
  delete from public.horarios where id = p_id;
  return json_build_object('ok', true);
end $$;

-- Pedidos ----------------------------------------------------------------
create or replace function public.admin_confirmar(p_reserva bigint) returns json
language plpgsql as $$
begin
  update public.reservas set status = 'confirmada', atualizado_em = now()
   where id = p_reserva and status = 'pendente';
  if not found then return json_build_object('ok', false); end if;
  update public.creditos set status = 'usado', atualizado_em = now() where reserva_id = p_reserva;
  return json_build_object('ok', true);
end $$;

create or replace function public.admin_recusar(p_reserva bigint) returns json
language plpgsql as $$
begin
  perform public.devolver_credito(p_reserva);
  update public.reservas set status = 'recusada', atualizado_em = now()
   where id = p_reserva and status in ('pendente','confirmada');
  return json_build_object('ok', found);
end $$;

-- Professor marca alguém direto (ex.: aluno pediu pelo WhatsApp)
create or replace function public.admin_reservar(p_aluno_id bigint, p_horario_id bigint, p_usar_credito boolean) returns json
language plpgsql as $$
declare v_cred bigint; v_res bigint;
begin
  if exists (select 1 from public.reservas where horario_id = p_horario_id and aluno_id = p_aluno_id
             and status in ('pendente','confirmada')) then
    return json_build_object('ok', false, 'motivo', 'ja_pediu');
  end if;
  if p_usar_credito then
    select id into v_cred from public.creditos
     where aluno_id = p_aluno_id and status = 'disponivel' and expira_em > now()
     order by expira_em, id limit 1 for update;
    if v_cred is null then return json_build_object('ok', false, 'motivo', 'sem_credito'); end if;
  end if;
  insert into public.reservas (horario_id, aluno_id, credito_id, status)
  values (p_horario_id, p_aluno_id, v_cred, 'confirmada') returning id into v_res;
  if v_cred is not null then
    update public.creditos set status = 'usado', reserva_id = v_res, atualizado_em = now() where id = v_cred;
  end if;
  return json_build_object('ok', true, 'reserva_id', v_res);
end $$;

-- Créditos ---------------------------------------------------------------
create or replace function public.admin_dar_creditos(p_aluno_ids bigint[], p_quantidade int, p_origem text, p_motivo text) returns json
language plpgsql as $$
declare v_total int := 0; v_id bigint; i int;
begin
  foreach v_id in array p_aluno_ids loop
    for i in 1..greatest(coalesce(p_quantidade, 1), 1) loop
      insert into public.creditos (aluno_id, origem, motivo, expira_em)
      values (v_id, coalesce(nullif(p_origem, ''), 'manual'), nullif(btrim(p_motivo), ''),
              now() + make_interval(days => public.validade_dias()));
      v_total := v_total + 1;
    end loop;
  end loop;
  return json_build_object('ok', true, 'criados', v_total);
end $$;

create or replace function public.admin_remover_credito(p_credito bigint) returns json
language plpgsql as $$
begin
  update public.creditos set status = 'removido', atualizado_em = now()
   where id = p_credito and status = 'disponivel';
  return json_build_object('ok', found);
end $$;

-- Dia de chuva: dá crédito para os alunos escolhidos e (opcional) cancela as reposições do dia
create or replace function public.admin_chuva(p_data date, p_aluno_ids bigint[], p_motivo text, p_cancelar_reposicoes boolean) returns json
language plpgsql as $$
declare v_cred json; v_h record; v_afetados jsonb := '[]';
begin
  v_cred := public.admin_dar_creditos(coalesce(p_aluno_ids, '{}'), 1, 'chuva', p_motivo);
  if p_cancelar_reposicoes then
    for v_h in select id from public.horarios where data = p_data and status <> 'cancelado' loop
      v_afetados := v_afetados || (public.admin_cancelar_horario(v_h.id, p_motivo) -> 'afetados')::jsonb;
    end loop;
  end if;
  return json_build_object('ok', true, 'creditos', v_cred -> 'criados', 'afetados', v_afetados);
end $$;

-- Alunos -----------------------------------------------------------------
create or replace function public.admin_salvar_aluno(
  p_id bigint, p_nome text, p_whatsapp text, p_nivel_ids int[], p_turmas text[],
  p_observacao text, p_ativo boolean) returns json
language plpgsql as $$
declare v_id bigint;
begin
  if p_id is null then
    insert into public.alunos (nome, whatsapp, wpp_chave, nivel_ids, turmas, observacao, ativo)
    values (btrim(p_nome), public.wpp_numero(p_whatsapp), public.wpp_chave(p_whatsapp),
            coalesce(p_nivel_ids, '{}'), coalesce(p_turmas, '{}'), nullif(btrim(p_observacao), ''), coalesce(p_ativo, true))
    returning id into v_id;
  else
    update public.alunos set nome = btrim(p_nome), whatsapp = public.wpp_numero(p_whatsapp),
           wpp_chave = public.wpp_chave(p_whatsapp), nivel_ids = coalesce(p_nivel_ids, '{}'),
           turmas = coalesce(p_turmas, '{}'), observacao = nullif(btrim(p_observacao), ''),
           ativo = coalesce(p_ativo, true)
     where id = p_id returning id into v_id;
  end if;
  return json_build_object('ok', v_id is not null, 'id', v_id);
end $$;

create or replace function public.admin_excluir_aluno(p_id bigint) returns json
language plpgsql as $$
begin
  delete from public.alunos where id = p_id;
  return json_build_object('ok', found);
end $$;

-- importa vários de uma vez: [{nome, whatsapp, nivel, turmas}]
create or replace function public.admin_importar_alunos(p_lista jsonb) returns json
language plpgsql as $$
declare v jsonb; v_nivel int; v_total int := 0;
begin
  for v in select * from jsonb_array_elements(p_lista) loop
    if coalesce(btrim(v ->> 'nome'), '') = '' then continue; end if;
    select id into v_nivel from public.niveis where lower(nome) = lower(btrim(v ->> 'nivel'));
    insert into public.alunos (nome, whatsapp, wpp_chave, nivel_ids, turmas)
    values (btrim(v ->> 'nome'), public.wpp_numero(v ->> 'whatsapp'), public.wpp_chave(v ->> 'whatsapp'),
            case when v_nivel is null then '{}' else array[v_nivel] end,
            coalesce((select array_agg(btrim(t)) from jsonb_array_elements_text(coalesce(v -> 'turmas', '[]')) t
                       where btrim(t) <> ''), '{}'));
    v_total := v_total + 1;
  end loop;
  return json_build_object('ok', true, 'importados', v_total);
end $$;

-- Níveis -----------------------------------------------------------------
create or replace function public.admin_salvar_nivel(p_id int, p_nome text, p_cor text, p_ordem int, p_ativo boolean) returns json
language plpgsql as $$
declare v_id int;
begin
  if p_id is null then
    insert into public.niveis (nome, cor, ordem, ativo)
    values (btrim(p_nome), coalesce(p_cor, '#2BD576'), coalesce(p_ordem, 99), coalesce(p_ativo, true))
    returning id into v_id;
  else
    update public.niveis set nome = btrim(p_nome), cor = coalesce(p_cor, cor), ordem = coalesce(p_ordem, ordem),
           ativo = coalesce(p_ativo, true) where id = p_id returning id into v_id;
  end if;
  return json_build_object('ok', v_id is not null, 'id', v_id);
end $$;

create or replace function public.admin_excluir_nivel(p_id int) returns json
language plpgsql as $$
begin
  update public.alunos set nivel_ids = array_remove(nivel_ids, p_id);
  update public.horarios set nivel_ids = array_remove(nivel_ids, p_id);
  delete from public.niveis where id = p_id;
  return json_build_object('ok', found);
end $$;

-- Configurações ----------------------------------------------------------
create or replace function public.admin_salvar_config(p_chave text, p_valor jsonb) returns json
language plpgsql as $$
begin
  insert into public.config (chave, valor) values (p_chave, p_valor)
  on conflict (chave) do update set valor = excluded.valor;
  return json_build_object('ok', true);
end $$;

-- Estatísticas -----------------------------------------------------------
create or replace function public.admin_estatisticas() returns json
language sql stable as $$
  select json_build_object(
    'por_mes', (select coalesce(json_agg(x order by x.mes), '[]') from (
        select to_char(date_trunc('month', h.data), 'YYYY-MM') as mes,
               count(*) filter (where r.status = 'confirmada') as confirmadas,
               count(*) filter (where r.status in ('cancelada_aluno')) as canceladas_aluno,
               count(*) filter (where r.status = 'cancelada_chuva') as canceladas_chuva,
               count(*) as pedidos
          from public.reservas r join public.horarios h on h.id = r.horario_id
         where h.data >= (public.agora_br())::date - 365
         group by 1) x),
    'por_horario', (select coalesce(json_agg(x order by x.pedidos desc), '[]') from (
        select extract(isodow from h.data)::int as dia_semana, to_char(h.hora, 'HH24:MI') as hora, count(r.id) as pedidos
          from public.horarios h left join public.reservas r on r.horario_id = h.id
         where h.data >= (public.agora_br())::date - 120
         group by 1, 2 having count(r.id) > 0 limit 10) x),
    'creditos', json_build_object(
        'disponiveis', (select count(*) from public.creditos where status = 'disponivel' and expira_em > now()),
        'vencendo_7d', (select count(*) from public.creditos where status = 'disponivel'
                          and expira_em > now() and expira_em <= now() + interval '7 days'),
        'vencidos_30d', (select count(*) from public.creditos where status = 'disponivel'
                          and expira_em <= now() and expira_em > now() - interval '30 days'),
        'gerados_30d', (select count(*) from public.creditos where criado_em > now() - interval '30 days'),
        'usados_30d', (select count(*) from public.creditos where status = 'usado' and atualizado_em > now() - interval '30 days')),
    'alunos_com_credito', (select count(distinct aluno_id) from public.creditos where status = 'disponivel' and expira_em > now())
  )
$$;

-- =====================================================================
-- DADOS INICIAIS
-- =====================================================================
insert into public.niveis (nome, cor, ordem) values
  ('Iniciante',     '#3B9EFF', 1),
  ('Básico',        '#2BD576', 2),
  ('Intermediário', '#F5A623', 3),
  ('Avançado',      '#A78BFA', 4),
  ('Kids Amarela',  '#FACC15', 5),
  ('Kids Laranja',  '#FB923C', 6);

insert into public.config (chave, valor) values
  ('validade_dias', '40'),
  ('hora_abertura', '"14:00"'),
  ('local_nome', '"Clube Militar"'),
  ('local_endereco', '"Cabo Frio · RJ"'),
  ('professor_nome', '"Matheus Knupp"'),
  ('professor_bio', '"Professor de tênis há mais de 4 anos, jogando há mais de 14. Aulas para todos os níveis no Clube Militar."'),
  ('professor_whatsapp', '""'),
  ('instagram', '"knupp_tenis"'),
  ('foto', '""'),
  ('regras', '["A reposição existe quando a aula é cancelada por chuva ou pelo professor.", "Falta do aluno, com ou sem aviso, não gera reposição.", "Cada crédito vale 40 dias. Depois disso, ele vence.", "As vagas de amanhã abrem todos os dias às 14h (de domingo a quinta). Quem pede primeiro tem prioridade.", "Seu pedido só vale depois que o professor confirmar pelo WhatsApp.", "Antes da confirmação você pode cancelar e o crédito volta. Depois de confirmada, se cancelar, o crédito é perdido."]'),
  ('msg_confirmacao', '"Oi, {nome}! Sua reposição está CONFIRMADA ✅\n📅 {dia} às {hora}\n📍 {local}\nTe espero na quadra! 🎾"'),
  ('msg_grupo', '"🎾 VAGAS DE REPOSIÇÃO ABERTAS!\nAs vagas de {dia} já estão no site. Quem tem crédito de reposição pode pedir agora:\n👉 {link}"'),
  ('msg_cancelamento', '"Oi, {nome}! A reposição de {dia} às {hora} foi cancelada ({motivo}). Seu crédito voltou e você pode marcar outro horário pelo site 👉 {link}"');

-- Alunos importados do TennisCoach Pro (sem WhatsApp — complete pelo painel)
select public.admin_importar_alunos('[
 {"nome":"Paulo","nivel":"Intermediário"},
 {"nome":"Bernardo","nivel":"Intermediário"},
 {"nome":"Adrian","nivel":"Iniciante"},
 {"nome":"Camila","nivel":"Iniciante"},
 {"nome":"Joãozinho","nivel":"Kids Laranja"},
 {"nome":"Davizinho","nivel":"Kids Laranja"},
 {"nome":"Gustavo","nivel":"Intermediário"},
 {"nome":"Filipinho","nivel":"Kids Laranja"},
 {"nome":"Joil","nivel":"Básico"},
 {"nome":"Giovanni","nivel":"Intermediário"},
 {"nome":"Nahun","nivel":"Intermediário"},
 {"nome":"Juan","nivel":"Iniciante"},
 {"nome":"Murilo","nivel":"Kids Amarela"},
 {"nome":"Breno","nivel":"Kids Amarela"},
 {"nome":"Flavio","nivel":"Intermediário"},
 {"nome":"Fabio","nivel":"Intermediário"},
 {"nome":"Victor","nivel":"Kids Laranja"},
 {"nome":"Heitor","nivel":"Kids Laranja"},
 {"nome":"Luiza","nivel":"Kids Amarela"},
 {"nome":"Clarice","nivel":"Kids Amarela"},
 {"nome":"Claudio","nivel":"Básico"},
 {"nome":"Simone","nivel":"Básico"},
 {"nome":"Ronaldo","nivel":"Básico"},
 {"nome":"Sergio","nivel":"Iniciante"},
 {"nome":"Patricia","nivel":"Iniciante"},
 {"nome":"Mariana","nivel":"Iniciante"},
 {"nome":"Nanaia","nivel":"Iniciante"},
 {"nome":"Sophia","nivel":"Iniciante"},
 {"nome":"Gabriel","nivel":"Iniciante"},
 {"nome":"Bruninho","nivel":"Kids Laranja"},
 {"nome":"Kaio","nivel":"Kids Laranja"},
 {"nome":"Gigi","nivel":"Kids Amarela"},
 {"nome":"Davi Gio","nivel":"Kids Amarela"},
 {"nome":"Pedro Miguel","nivel":"Iniciante"},
 {"nome":"Vitor Sartorio","nivel":"Iniciante"},
 {"nome":"Hiago","nivel":"Iniciante"},
 {"nome":"Millene","nivel":"Iniciante"},
 {"nome":"Luiza Keila","nivel":"Kids Laranja"},
 {"nome":"Fred","nivel":"Intermediário"},
 {"nome":"Gabriel (Avançado)","nivel":"Avançado"},
 {"nome":"João Lucas","nivel":"Intermediário"},
 {"nome":"Guilherme Cantarino","nivel":"Intermediário"},
 {"nome":"Gabriela","nivel":"Intermediário"},
 {"nome":"Vivian","nivel":"Iniciante"},
 {"nome":"Julia","nivel":"Kids Laranja"},
 {"nome":"Matheus Pena","nivel":"Iniciante"},
 {"nome":"Camila Pinheiro","nivel":"Iniciante"},
 {"nome":"Igor","nivel":"Iniciante"},
 {"nome":"Jose","nivel":"Kids Laranja"},
 {"nome":"Laura T","nivel":"Iniciante"},
 {"nome":"Leozinho","nivel":"Kids Laranja"},
 {"nome":"Filha Hiago","nivel":"Kids Amarela"},
 {"nome":"Thais","nivel":"Iniciante"},
 {"nome":"Jhanna","nivel":"Iniciante"},
 {"nome":"Savio","nivel":"Iniciante"},
 {"nome":"Laura","nivel":"Kids Laranja"},
 {"nome":"Melina","nivel":"Kids Laranja"},
 {"nome":"Daniel","nivel":"Intermediário"}
]'::jsonb);

-- Pronto! Confira: select count(*) from public.alunos;  (deve dar 58)

-- avisa a API do Supabase que as funções mudaram
notify pgrst, 'reload schema';
