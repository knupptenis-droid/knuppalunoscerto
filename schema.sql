-- ============================================================
-- Knupp Tênis — Vagas de Reposição
-- Rode este arquivo inteiro no SQL Editor do Supabase.
-- ============================================================

-- Tabela de ofertas (cada "rodada" de vagas que você abre)
create table if not exists public.ofertas (
  id            bigint generated always as identity primary key,
  titulo        text not null,
  detalhe       text,
  vagas_total   integer not null check (vagas_total >= 0),
  aberta        boolean not null default true,
  criada_em     timestamptz not null default now()
);

-- Tabela de inscrições
create table if not exists public.inscricoes (
  id          bigint generated always as identity primary key,
  oferta_id   bigint not null references public.ofertas(id) on delete cascade,
  nome        text not null,
  nivel       text not null,
  whatsapp    text,
  posicao     integer not null,
  criada_em   timestamptz not null default now()
);

create index if not exists inscricoes_oferta_idx on public.inscricoes (oferta_id, posicao);

-- Nenhum acesso direto do navegador: tudo passa pelo backend com service_role
alter table public.ofertas    enable row level security;
alter table public.inscricoes enable row level security;

-- ============================================================
-- Função atômica de inscrição.
-- Trava a linha da oferta, conta as inscrições e só insere se
-- ainda houver vaga. Evita que duas pessoas peguem a mesma vaga
-- ao enviar o formulário no mesmo segundo.
-- ============================================================
create or replace function public.inscrever(
  p_oferta_id bigint,
  p_nome      text,
  p_nivel     text,
  p_whatsapp  text
)
returns json
language plpgsql
security definer
as $$
declare
  v_oferta   public.ofertas%rowtype;
  v_ocupadas integer;
  v_posicao  integer;
begin
  select * into v_oferta
  from public.ofertas
  where id = p_oferta_id
  for update;

  if not found then
    return json_build_object('ok', false, 'motivo', 'inexistente');
  end if;

  if not v_oferta.aberta then
    return json_build_object('ok', false, 'motivo', 'fechada');
  end if;

  select count(*) into v_ocupadas
  from public.inscricoes
  where oferta_id = p_oferta_id;

  if v_ocupadas >= v_oferta.vagas_total then
    return json_build_object('ok', false, 'motivo', 'esgotada');
  end if;

  -- mesmo nome já inscrito nesta rodada
  if exists (
    select 1 from public.inscricoes
    where oferta_id = p_oferta_id
      and lower(btrim(nome)) = lower(btrim(p_nome))
  ) then
    return json_build_object('ok', false, 'motivo', 'duplicada');
  end if;

  v_posicao := v_ocupadas + 1;

  insert into public.inscricoes (oferta_id, nome, nivel, whatsapp, posicao)
  values (p_oferta_id, btrim(p_nome), p_nivel, nullif(btrim(p_whatsapp), ''), v_posicao);

  return json_build_object(
    'ok', true,
    'posicao', v_posicao,
    'restantes', v_oferta.vagas_total - v_posicao
  );
end;
$$;
