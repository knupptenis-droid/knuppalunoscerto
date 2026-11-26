-- =====================================================================
-- KNUPP TÊNIS · ÁREA DO ALUNO v4: COMPRA DE AULAS + LOJA
-- ATUALIZAÇÃO QUE NÃO APAGA NADA. Rode inteiro no Supabase → SQL Editor → Run.
-- Precisa do atualizacao-v3.sql já rodado. Pode rodar mais de uma vez.
-- =====================================================================

-- créditos agora têm tipo: reposição (chuva/professor) ou aula comprada
alter table public.creditos add column if not exists tipo text not null default 'reposicao';
do $$ begin
  alter table public.creditos drop constraint if exists creditos_origem_check;
  alter table public.creditos add constraint creditos_origem_check check (origem in ('chuva','manual','devolucao','compra'));
end $$;

create table if not exists public.produtos (
  id           text primary key,
  nome         text not null,
  categoria    text,
  condicao     text,
  descricao    text,
  foto         text,
  fotos        jsonb not null default '[]',
  preco        numeric(10,2) not null default 0,
  parcelas     int not null default 1,
  variacoes    jsonb not null default '[]',
  indisponiveis jsonb not null default '[]',
  ativo        boolean not null default true,
  ordem        bigint not null default 0,
  criado_em    timestamptz not null default now()
);

create table if not exists public.pedidos (
  id          bigint generated always as identity primary key,
  aluno_id    bigint references public.alunos(id) on delete set null,
  tipo        text not null check (tipo in ('aulas','loja')),
  itens       jsonb not null,
  total       numeric(10,2) not null,
  pagamento   text not null default 'pix' check (pagamento in ('pix','cartao')),
  entrega     text not null default 'retirada' check (entrega in ('retirada','entrega')),
  endereco    text,
  observacao  text,
  status      text not null default 'aguardando'
              check (status in ('aguardando','informado','pago','separado','entregue','cancelado')),
  forma       text,
  recibo      int,
  creditado   boolean not null default false,
  pago_em     timestamptz,
  criado_em   timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index if not exists pedidos_aluno_idx on public.pedidos (aluno_id, criado_em desc);

alter table public.produtos enable row level security;
alter table public.pedidos  enable row level security;

insert into public.config (chave, valor) values
  ('preco_aula', '70'),
  ('loja_taxas', '[4.5,5.5,6.5,7.5,8.5,9.5,10.5,11.5,12.5,13.5,14.5,15.5]'),
  ('loja_entrega', '"Retirada nas aulas (Clube Militar) ou entrega combinada em Cabo Frio."'),
  ('loja_categorias', '["Raquetes","Bolas","Acessórios","Vestuário","Serviços","Aulas"]'),
  ('loja_url', '"https://lojaknupptenis.netlify.app/"')
on conflict (chave) do nothing;

-- ---------------------------------------------------------------------
-- RESERVA: usa primeiro o crédito de reposição, depois a aula comprada
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
   order by (tipo = 'aula'), expira_em, id limit 1 for update skip locked;
  if v_cred is null then return json_build_object('ok', false, 'motivo', 'sem_credito'); end if;

  insert into public.reservas (horario_id, aluno_id, credito_id) values (v_h.id, v_aluno.id, v_cred) returning id into v_res;
  update public.creditos set status = 'reservado', reserva_id = v_res, atualizado_em = now() where id = v_cred;
  return json_build_object('ok', true, 'reserva_id', v_res);
end $$;

-- ---------------------------------------------------------------------
-- LOJA (pública)
-- ---------------------------------------------------------------------
create or replace function public.loja_listar() returns json
language sql stable as $$
  select json_build_object(
    'produtos', (select coalesce(json_agg(json_build_object('id', p.id, 'nome', p.nome, 'categoria', p.categoria, 'condicao', p.condicao,
        'descricao', p.descricao, 'foto', p.foto, 'preco', p.preco, 'parcelas', p.parcelas, 'variacoes', p.variacoes,
        'indisponiveis', p.indisponiveis, 'n_fotos', jsonb_array_length(p.fotos)) order by p.ordem desc, p.nome), '[]')
      from public.produtos p where p.ativo),
    'config', (select json_object_agg(chave, valor) from public.config
                where chave in ('preco_aula','loja_taxas','loja_entrega','loja_categorias')))
$$;

create or replace function public.loja_produto(p_id text) returns json
language sql stable as $$ select to_json(p) from public.produtos p where p.id = p_id $$;

-- preço de um item conforme as opções escolhidas (a opção com preço > 0 substitui o preço base)
create or replace function public.loja_preco_item(p_prod public.produtos, p_escolhas jsonb) returns json
language plpgsql stable as $$
declare v jsonb; o jsonb; v_preco numeric := p_prod.preco; v_combo text[] := '{}'; v_escolha text; achou boolean;
begin
  for v in select * from jsonb_array_elements(p_prod.variacoes) loop
    v_escolha := p_escolhas ->> (v ->> 'nome');
    if v_escolha is null then return json_build_object('ok', false, 'motivo', 'escolha', 'variacao', v ->> 'nome'); end if;
    achou := false;
    for o in select * from jsonb_array_elements(v -> 'opcoes') loop
      if o ->> 'nome' = v_escolha then
        achou := true;
        if coalesce((o ->> 'preco')::numeric, 0) > 0 then v_preco := (o ->> 'preco')::numeric; end if;
      end if;
    end loop;
    if not achou then return json_build_object('ok', false, 'motivo', 'opcao'); end if;
    v_combo := v_combo || v_escolha;
  end loop;
  if p_prod.indisponiveis ? array_to_string(v_combo, ' / ') then
    return json_build_object('ok', false, 'motivo', 'indisponivel');
  end if;
  return json_build_object('ok', true, 'preco', v_preco, 'descricao', array_to_string(v_combo, ' / '));
end $$;

-- aluno cria pedido (aulas ou loja). Preços sempre calculados aqui no banco.
create or replace function public.aluno_criar_pedido(p_whatsapp text, p_aluno_id bigint, p_tipo text, p_itens jsonb,
  p_pagamento text default 'pix', p_entrega text default 'retirada', p_endereco text default null, p_observacao text default null) returns json
language plpgsql as $$
declare v_aluno public.alunos%rowtype; v jsonb; v_prod public.produtos%rowtype; v_calc json; v_qtd int;
        v_itens jsonb := '[]'; v_total numeric := 0; v_id bigint; v_preco_aula numeric;
begin
  select * into v_aluno from public.alunos where id = p_aluno_id and wpp_chave = public.wpp_chave(p_whatsapp) and ativo;
  if not found then return json_build_object('ok', false, 'motivo', 'aluno'); end if;

  if p_tipo = 'aulas' then
    if not public.em_dia(v_aluno.id) then return json_build_object('ok', false, 'motivo', 'mensalidade'); end if;
    v_qtd := greatest(1, least(20, coalesce((p_itens -> 0 ->> 'qtd')::int, 1)));
    v_preco_aula := coalesce((select (valor #>> '{}')::numeric from public.config where chave = 'preco_aula'), 70);
    v_itens := jsonb_build_array(jsonb_build_object('nome', 'Aula avulsa (crédito)', 'qtd', v_qtd, 'preco', v_preco_aula));
    v_total := v_qtd * v_preco_aula;
  elsif p_tipo = 'loja' then
    if jsonb_array_length(coalesce(p_itens, '[]')) = 0 then return json_build_object('ok', false, 'motivo', 'vazio'); end if;
    for v in select * from jsonb_array_elements(p_itens) loop
      select * into v_prod from public.produtos where id = v ->> 'produto_id' and ativo;
      if not found then return json_build_object('ok', false, 'motivo', 'produto'); end if;
      v_calc := public.loja_preco_item(v_prod, coalesce(v -> 'escolhas', '{}'));
      if not (v_calc ->> 'ok')::boolean then return (v_calc::jsonb || jsonb_build_object('produto', v_prod.nome))::json; end if;
      v_qtd := greatest(1, least(50, coalesce((v ->> 'qtd')::int, 1)));
      v_itens := v_itens || jsonb_build_object('produto_id', v_prod.id, 'nome', v_prod.nome, 'opcoes', v_calc ->> 'descricao',
                   'qtd', v_qtd, 'preco', (v_calc ->> 'preco')::numeric);
      v_total := v_total + v_qtd * (v_calc ->> 'preco')::numeric;
    end loop;
  else
    return json_build_object('ok', false, 'motivo', 'tipo');
  end if;

  insert into public.pedidos (aluno_id, tipo, itens, total, pagamento, entrega, endereco, observacao)
  values (v_aluno.id, p_tipo, v_itens, v_total, case when p_pagamento = 'cartao' then 'cartao' else 'pix' end,
          case when p_entrega = 'entrega' then 'entrega' else 'retirada' end, nullif(btrim(p_endereco), ''), nullif(btrim(p_observacao), ''))
  returning id into v_id;
  return json_build_object('ok', true, 'pedido_id', v_id, 'total', v_total);
end $$;

create or replace function public.aluno_informar_pedido(p_whatsapp text, p_pedido bigint) returns json
language plpgsql as $$
begin
  update public.pedidos p set status = 'informado', atualizado_em = now() from public.alunos a
   where p.id = p_pedido and a.id = p.aluno_id and a.wpp_chave = public.wpp_chave(p_whatsapp) and p.status = 'aguardando';
  return json_build_object('ok', found);
end $$;

create or replace function public.aluno_cancelar_pedido(p_whatsapp text, p_pedido bigint) returns json
language plpgsql as $$
begin
  update public.pedidos p set status = 'cancelado', atualizado_em = now() from public.alunos a
   where p.id = p_pedido and a.id = p.aluno_id and a.wpp_chave = public.wpp_chave(p_whatsapp) and p.status in ('aguardando','informado');
  return json_build_object('ok', found);
end $$;

-- área do aluno v4 = v3 + saldos separados + pedidos
create or replace function public.aluno_area_v4(p_whatsapp text) returns json
language plpgsql as $$
declare v_base jsonb;
begin
  v_base := public.aluno_area(p_whatsapp)::jsonb;
  if not (v_base ->> 'ok')::boolean then return v_base::json; end if;
  return (v_base || jsonb_build_object(
    'saldos', (select coalesce(jsonb_object_agg(a.id, jsonb_build_object(
        'repo', (select count(*) from public.creditos c where c.aluno_id = a.id and c.status = 'disponivel' and c.expira_em > now() and c.tipo <> 'aula'),
        'aula', (select count(*) from public.creditos c where c.aluno_id = a.id and c.status = 'disponivel' and c.expira_em > now() and c.tipo = 'aula'))), '{}')
      from public.alunos a where a.wpp_chave = public.wpp_chave(p_whatsapp) and a.ativo),
    'pedidos', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'aluno_id', p.aluno_id, 'tipo', p.tipo, 'itens', p.itens, 'total', p.total,
        'pagamento', p.pagamento, 'entrega', p.entrega, 'status', p.status, 'forma', p.forma, 'recibo', p.recibo, 'pago_em', p.pago_em,
        'criado_em', p.criado_em) order by p.criado_em desc), '[]')
      from public.pedidos p join public.alunos a on a.id = p.aluno_id
      where a.wpp_chave = public.wpp_chave(p_whatsapp) and p.criado_em > now() - interval '180 days'),
    'preco_aula', (select valor from public.config where chave = 'preco_aula')
  ))::json;
end $$;

-- ---------------------------------------------------------------------
-- PAINEL
-- ---------------------------------------------------------------------
create or replace function public.admin_dados_v4() returns json
language plpgsql as $$
declare v3 jsonb := public.admin_dados_v3()::jsonb;
begin
  return (v3 || jsonb_build_object(
    'pedidos', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'aluno_id', p.aluno_id, 'nome', a.nome, 'whatsapp', a.whatsapp,
        'responsavel', a.responsavel, 'tipo', p.tipo, 'itens', p.itens, 'total', p.total, 'pagamento', p.pagamento, 'entrega', p.entrega,
        'endereco', p.endereco, 'observacao', p.observacao, 'status', p.status, 'forma', p.forma, 'recibo', p.recibo,
        'pago_em', p.pago_em, 'criado_em', p.criado_em) order by p.criado_em desc), '[]')
      from public.pedidos p left join public.alunos a on a.id = p.aluno_id where p.criado_em > now() - interval '120 days'),
    'produtos', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'nome', p.nome, 'categoria', p.categoria, 'condicao', p.condicao,
        'foto', p.foto, 'preco', p.preco, 'ativo', p.ativo, 'n_variacoes', jsonb_array_length(p.variacoes)) order by p.ordem desc, p.nome), '[]')
      from public.produtos p),
    'saldo_aulas', (select coalesce(jsonb_object_agg(aluno_id, n), '{}') from (select aluno_id, count(*) n from public.creditos
        where tipo = 'aula' and status = 'disponivel' group by 1) x),
    'pendencias', (v3 -> 'pendencias') || jsonb_build_object(
        'pedidos_novos', (select count(*) from public.pedidos where status in ('aguardando','informado')),
        'pedidos_separar', (select count(*) from public.pedidos where status in ('pago','separado') and tipo = 'loja'))
  ))::json;
end $$;

-- muda o status do pedido; ao marcar "pago", gera recibo e (se for compra de aulas) lança os créditos
create or replace function public.admin_pedido_status(p_id bigint, p_status text, p_forma text default null) returns json
language plpgsql as $$
declare v_p public.pedidos%rowtype; v_qtd int; i int;
begin
  select * into v_p from public.pedidos where id = p_id for update;
  if not found then return json_build_object('ok', false); end if;
  update public.pedidos set status = p_status, atualizado_em = now(),
    forma = case when p_status in ('pago','separado','entregue') then coalesce(nullif(p_forma, ''), forma, case when pagamento = 'cartao' then 'Cartão' else 'PIX' end) else forma end,
    pago_em = case when p_status in ('pago','separado','entregue') then coalesce(pago_em, now()) else pago_em end,
    recibo = case when p_status in ('pago','separado','entregue') then coalesce(recibo, nextval('public.recibo_seq')::int) else recibo end
   where id = p_id;
  if v_p.tipo = 'aulas' and p_status in ('pago','separado','entregue') and not v_p.creditado and v_p.aluno_id is not null then
    v_qtd := coalesce((v_p.itens -> 0 ->> 'qtd')::int, 1);
    for i in 1..v_qtd loop
      insert into public.creditos (aluno_id, origem, tipo, motivo, expira_em)
      values (v_p.aluno_id, 'compra', 'aula', 'Compra #' || v_p.id, '2099-12-31');
    end loop;
    update public.pedidos set creditado = true where id = p_id;
  end if;
  return json_build_object('ok', true);
end $$;

create or replace function public.admin_salvar_produto(p_produto jsonb) returns json
language plpgsql as $$
declare v_id text := coalesce(nullif(p_produto ->> 'id', ''), 'p' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS'));
begin
  insert into public.produtos (id, nome, categoria, condicao, descricao, foto, fotos, preco, parcelas, variacoes, indisponiveis, ativo, ordem)
  values (v_id, btrim(p_produto ->> 'nome'), nullif(p_produto ->> 'categoria', ''), nullif(p_produto ->> 'condicao', ''),
          nullif(p_produto ->> 'descricao', ''), nullif(p_produto ->> 'foto', ''), coalesce(p_produto -> 'fotos', '[]'),
          coalesce((p_produto ->> 'preco')::numeric, 0), coalesce((p_produto ->> 'parcelas')::int, 1),
          coalesce(p_produto -> 'variacoes', '[]'), coalesce(p_produto -> 'indisponiveis', '[]'),
          coalesce((p_produto ->> 'ativo')::boolean, true), coalesce((p_produto ->> 'ordem')::bigint, extract(epoch from now())::bigint))
  on conflict (id) do update set nome = excluded.nome, categoria = excluded.categoria, condicao = excluded.condicao,
    descricao = excluded.descricao, foto = excluded.foto, fotos = excluded.fotos, preco = excluded.preco, parcelas = excluded.parcelas,
    variacoes = excluded.variacoes, indisponiveis = excluded.indisponiveis, ativo = excluded.ativo;
  return json_build_object('ok', true, 'id', v_id);
end $$;

create or replace function public.admin_excluir_produto(p_id text) returns json
language plpgsql as $$ begin delete from public.produtos where id = p_id; return json_build_object('ok', found); end $$;

-- importa o JSON da vitrine antiga (lojaknupptenis.netlify.app). Atualiza quem já existe, não apaga nada.
create or replace function public.admin_importar_loja(p_store jsonb) returns json
language plpgsql as $$
declare p jsonb; v_n int := 0;
begin
  for p in select * from jsonb_array_elements(coalesce(p_store -> 'produtos', '[]')) loop
    perform public.admin_salvar_produto(jsonb_build_object(
      'id', p ->> 'id', 'nome', p ->> 'nome', 'categoria', p ->> 'categoria', 'condicao', p ->> 'condicao',
      'descricao', p ->> 'descricao', 'foto', p ->> 'foto', 'fotos', coalesce(p -> 'fotos', '[]'),
      'preco', coalesce(p ->> 'precoPix', '0'), 'parcelas', coalesce(p ->> 'parcelas', '1'),
      'variacoes', coalesce(p -> 'variacoes', '[]'), 'indisponiveis', coalesce(p -> 'indisponiveis', '[]'),
      'ativo', coalesce(p ->> 'ativo', 'true'), 'ordem', coalesce(p ->> 'criadoEm', '0')));
    v_n := v_n + 1;
  end loop;
  if p_store #> '{config,taxas}' is not null then
    perform public.admin_salvar_config('loja_taxas', p_store #> '{config,taxas}');
  end if;
  if p_store #> '{config,entrega}' is not null then
    perform public.admin_salvar_config('loja_entrega', p_store #> '{config,entrega}');
  end if;
  if p_store #> '{config,ordemCategorias}' is not null then
    perform public.admin_salvar_config('loja_categorias', p_store #> '{config,ordemCategorias}');
  end if;
  return json_build_object('ok', true, 'importados', v_n);
end $$;

notify pgrst, 'reload schema';
