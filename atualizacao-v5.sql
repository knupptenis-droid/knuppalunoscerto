-- =====================================================================
-- KNUPP TÊNIS · ÁREA DO ALUNO v5: PLANO TRIMESTRAL + MENSALIDADE NO CARTÃO
-- ATUALIZAÇÃO QUE NÃO APAGA NADA. Precisa do v3 e do v4 já rodados.
-- =====================================================================

alter table public.mensalidades add column if not exists plano bigint;

do $$ begin
  alter table public.pedidos drop constraint if exists pedidos_tipo_check;
  alter table public.pedidos add constraint pedidos_tipo_check check (tipo in ('aulas','loja','plano'));
end $$;

insert into public.config (chave, valor) values
  ('plano_desconto', '10'),          -- % de desconto do trimestral (PIX à vista)
  ('taxa_credito_1x', '3.15'),       -- % da maquininha no crédito à vista
  ('taxa_credito_3x', '6.12')        -- % da maquininha no crédito em 3x
on conflict (chave) do nothing;

create or replace function public.cfg_num(p_chave text, p_padrao numeric) returns numeric
language sql stable as $$ select coalesce((select (valor #>> '{}')::numeric from public.config where chave = p_chave), p_padrao) $$;

-- Preços do plano (todos arredondados para cima, em reais inteiros).
-- Cartão = valor do PIX "com a taxa por cima": você recebe líquido o mesmo do PIX.
create or replace function public.plano_precos(p_mensal numeric) returns json
language plpgsql stable as $$
declare d numeric := public.cfg_num('plano_desconto', 10) / 100;
        t1 numeric := public.cfg_num('taxa_credito_1x', 3.15) / 100;
        t3 numeric := public.cfg_num('taxa_credito_3x', 6.12) / 100;
        v_pix numeric; v_c1 numeric; v_p3 numeric;
begin
  if coalesce(p_mensal, 0) <= 0 then return null; end if;
  v_pix := ceiling(3 * p_mensal * (1 - d));
  v_c1  := ceiling(v_pix / (1 - t1));
  v_p3  := ceiling(v_pix / (1 - t3) / 3);
  return json_build_object(
    'mensal', p_mensal, 'cheio', 3 * p_mensal,
    'pix', v_pix, 'cartao1', v_c1, 'parcela3', v_p3, 'cartao3', v_p3 * 3,
    'economia_pix', 3 * p_mensal - v_pix, 'economia_cartao3', 3 * p_mensal - v_p3 * 3,
    'mensal_cartao', ceiling(p_mensal / (1 - t1)));
end $$;

-- os 3 próximos meses (a partir do mês que vem) que ainda não estão pagos
create or replace function public.plano_meses(p_aluno bigint) returns date[]
language plpgsql stable as $$
declare v_mes date := (date_trunc('month', public.hoje_br()) + interval '1 month')::date; v_out date[] := '{}'; i int := 0;
begin
  while cardinality(v_out) < 3 and i < 24 loop
    if not exists (select 1 from public.mensalidades where aluno_id = p_aluno and competencia = v_mes and status in ('pago','isento')) then
      v_out := v_out || v_mes;
    end if;
    v_mes := (v_mes + interval '1 month')::date; i := i + 1;
  end loop;
  return v_out;
end $$;

create or replace function public.plano_ativo_ate(p_aluno bigint) returns date
language sql stable as $$
  select max(competencia) from public.mensalidades
   where aluno_id = p_aluno and plano is not null and status = 'pago' and competencia >= date_trunc('month', public.hoje_br())::date
$$;

-- ---------------------------------------------------------------------
-- Pedido: agora também aceita tipo 'plano'
-- ---------------------------------------------------------------------
create or replace function public.aluno_criar_pedido(p_whatsapp text, p_aluno_id bigint, p_tipo text, p_itens jsonb,
  p_pagamento text default 'pix', p_entrega text default 'retirada', p_endereco text default null, p_observacao text default null) returns json
language plpgsql as $$
declare v_aluno public.alunos%rowtype; v jsonb; v_prod public.produtos%rowtype; v_calc json; v_qtd int;
        v_itens jsonb := '[]'; v_total numeric := 0; v_id bigint; v_preco_aula numeric; v_precos json; v_forma text; v_meses date[];
begin
  select * into v_aluno from public.alunos where id = p_aluno_id and wpp_chave = public.wpp_chave(p_whatsapp) and ativo;
  if not found then return json_build_object('ok', false, 'motivo', 'aluno'); end if;

  if p_tipo = 'aulas' then
    if not public.em_dia(v_aluno.id) then return json_build_object('ok', false, 'motivo', 'mensalidade'); end if;
    v_qtd := greatest(1, least(20, coalesce((p_itens -> 0 ->> 'qtd')::int, 1)));
    v_preco_aula := public.cfg_num('preco_aula', 70);
    v_itens := jsonb_build_array(jsonb_build_object('nome', 'Aula avulsa (crédito)', 'qtd', v_qtd, 'preco', v_preco_aula));
    v_total := v_qtd * v_preco_aula;
  elsif p_tipo = 'plano' then
    v_precos := public.plano_precos(v_aluno.valor_mensal);
    if v_precos is null then return json_build_object('ok', false, 'motivo', 'sem_valor'); end if;
    if exists (select 1 from public.pedidos where aluno_id = v_aluno.id and tipo = 'plano' and status in ('aguardando','informado')) then
      return json_build_object('ok', false, 'motivo', 'plano_pendente');
    end if;
    v_forma := coalesce(p_itens -> 0 ->> 'forma', 'pix');
    if v_forma not in ('pix','cartao1','cartao3') then v_forma := 'pix'; end if;
    v_total := (v_precos ->> case v_forma when 'pix' then 'pix' when 'cartao1' then 'cartao1' else 'cartao3' end)::numeric;
    v_meses := public.plano_meses(v_aluno.id);
    v_itens := jsonb_build_array(jsonb_build_object('nome', 'Plano trimestral', 'qtd', 1, 'preco', v_total, 'forma', v_forma,
      'parcelas', case v_forma when 'cartao3' then 3 else 1 end, 'meses', to_jsonb(v_meses),
      'opcoes', case v_forma when 'pix' then 'PIX à vista' when 'cartao1' then 'Cartão à vista' else '3x de R$ ' || (v_precos ->> 'parcela3') || ' sem juros' end));
    p_pagamento := case when v_forma = 'pix' then 'pix' else 'cartao' end;
    p_entrega := 'retirada';
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

-- "Recebi": compra de aulas lança créditos; plano marca os 3 meses como pagos
create or replace function public.admin_pedido_status(p_id bigint, p_status text, p_forma text default null) returns json
language plpgsql as $$
declare v_p public.pedidos%rowtype; v_qtd int; i int; v_mes date; v_meses jsonb; v_parte numeric; v_dia int; v_rec int; v_forma text;
begin
  select * into v_p from public.pedidos where id = p_id for update;
  if not found then return json_build_object('ok', false); end if;
  update public.pedidos set status = p_status, atualizado_em = now(),
    forma = case when p_status in ('pago','separado','entregue') then coalesce(nullif(p_forma, ''), forma, case when pagamento = 'cartao' then 'Cartão' else 'PIX' end) else forma end,
    pago_em = case when p_status in ('pago','separado','entregue') then coalesce(pago_em, now()) else pago_em end,
    recibo = case when p_status in ('pago','separado','entregue') then coalesce(recibo, nextval('public.recibo_seq')::int) else recibo end
   where id = p_id returning recibo, forma into v_rec, v_forma;

  if p_status in ('pago','separado','entregue') and not v_p.creditado and v_p.aluno_id is not null then
    if v_p.tipo = 'aulas' then
      v_qtd := coalesce((v_p.itens -> 0 ->> 'qtd')::int, 1);
      for i in 1..v_qtd loop
        insert into public.creditos (aluno_id, origem, tipo, motivo, expira_em)
        values (v_p.aluno_id, 'compra', 'aula', 'Compra #' || v_p.id, '2099-12-31');
      end loop;
    elsif v_p.tipo = 'plano' then
      v_meses := v_p.itens -> 0 -> 'meses';
      v_parte := round(v_p.total / greatest(jsonb_array_length(v_meses), 1), 2);
      select dia_vencimento into v_dia from public.alunos where id = v_p.aluno_id;
      for v_mes in select (x #>> '{}')::date from jsonb_array_elements(v_meses) x loop
        insert into public.mensalidades (aluno_id, competencia, valor, vencimento, status, forma, pago_em, recibo, plano, observacao)
        values (v_p.aluno_id, v_mes, v_parte, v_mes + (least(greatest(coalesce(v_dia, 10), 1), 28) - 1), 'pago',
                'Plano trimestral · ' || v_forma, now(), v_rec, v_p.id, 'Plano trimestral #' || v_p.id)
        on conflict (aluno_id, competencia) do update set status = 'pago', valor = excluded.valor, forma = excluded.forma,
          pago_em = excluded.pago_em, recibo = excluded.recibo, plano = excluded.plano, observacao = excluded.observacao;
      end loop;
    end if;
    update public.pedidos set creditado = true where id = p_id;
  end if;
  return json_build_object('ok', true);
end $$;

-- aluno avisa que vai pagar a mensalidade no cartão (na maquininha, na aula)
create or replace function public.aluno_pagar_cartao(p_whatsapp text, p_mensalidade bigint) returns json
language plpgsql as $$
declare v_valor numeric;
begin
  select ceiling(m.valor / (1 - public.cfg_num('taxa_credito_1x', 3.15) / 100)) into v_valor
    from public.mensalidades m join public.alunos a on a.id = m.aluno_id
   where m.id = p_mensalidade and a.wpp_chave = public.wpp_chave(p_whatsapp) and m.status = 'pendente';
  if v_valor is null then return json_build_object('ok', false); end if;
  update public.mensalidades set status = 'informado', forma = 'Cartão (na aula)',
         observacao = 'Vai pagar no cartão na aula: R$ ' || v_valor where id = p_mensalidade;
  return json_build_object('ok', true, 'valor_cartao', v_valor);
end $$;

-- área do aluno v5 = v4 + plano
create or replace function public.aluno_area_v5(p_whatsapp text) returns json
language plpgsql as $$
declare v_base jsonb;
begin
  v_base := public.aluno_area_v4(p_whatsapp)::jsonb;
  if not (v_base ->> 'ok')::boolean then return v_base::json; end if;
  return (v_base || jsonb_build_object(
    'plano', (select coalesce(jsonb_object_agg(a.id, jsonb_build_object(
        'precos', public.plano_precos(a.valor_mensal),
        'ativo_ate', public.plano_ativo_ate(a.id),
        'meses', to_jsonb(public.plano_meses(a.id)),
        'pendente', exists (select 1 from public.pedidos p where p.aluno_id = a.id and p.tipo = 'plano' and p.status in ('aguardando','informado')))), '{}')
      from public.alunos a where a.wpp_chave = public.wpp_chave(p_whatsapp) and a.ativo)
  ))::json;
end $$;

create or replace function public.admin_dados_v5() returns json
language plpgsql as $$
declare v4 jsonb := public.admin_dados_v4()::jsonb;
begin
  return (v4 || jsonb_build_object(
    'planos', (select coalesce(jsonb_agg(jsonb_build_object('aluno_id', a.id, 'nome', a.nome, 'whatsapp', a.whatsapp,
        'ativo_ate', public.plano_ativo_ate(a.id), 'precos', public.plano_precos(a.valor_mensal)) order by public.plano_ativo_ate(a.id)), '[]')
      from public.alunos a where a.ativo and public.plano_ativo_ate(a.id) is not null)
  ))::json;
end $$;

notify pgrst, 'reload schema';
