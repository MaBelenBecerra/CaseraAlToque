-- =====================================================================
--  Monitor Inteligente de Precios y Stock  ·  Base de datos (Supabase)
--  Pegá TODO este archivo en Supabase → SQL Editor → Run.
--  Se puede volver a correr sin romper nada.
-- =====================================================================

-- pg_net permite que la base le mande avisos HTTP (webhooks) a n8n.
create extension if not exists pg_net;

-- ---------------------------------------------------------------------
-- 1. TABLAS
--    user_id guarda el id de Clerk (user_2abc...). Se completa solo con
--    el token de la sesión: auth.jwt()->>'sub'.
-- ---------------------------------------------------------------------

create table if not exists public.negocios (
  user_id          text primary key default (auth.jwt()->>'sub'),
  nombre_negocio   text,
  email            text,
  telegram_chat_id text,
  creado_en        timestamptz not null default now()
);

create table if not exists public.productos (
  id             bigint generated always as identity primary key,
  user_id        text not null default (auth.jwt()->>'sub'),
  nombre         text not null,
  unidad         text not null default 'unidad',
  precio_venta   numeric(12,2) not null default 0,
  costo          numeric(12,2) not null default 0,
  stock          numeric(12,2) not null default 0,
  stock_minimo   numeric(12,2) not null default 0,
  ultima_alerta  timestamptz,
  actualizado_en timestamptz not null default now(),
  creado_en      timestamptz not null default now()
);
create index if not exists productos_user_idx on public.productos(user_id);

create table if not exists public.ventas (
  id              bigint generated always as identity primary key,
  user_id         text not null default (auth.jwt()->>'sub'),
  producto_id     bigint not null references public.productos(id) on delete cascade,
  cantidad        numeric(12,2) not null check (cantidad > 0),
  precio_unitario numeric(12,2),
  total           numeric(12,2),
  nota            text,
  creado_en       timestamptz not null default now()
);
create index if not exists ventas_prod_fecha_idx on public.ventas(producto_id, creado_en);

-- Notas de compra: texto libre ("compré 20 cocas a 8 Bs") y/o foto.
create table if not exists public.compras (
  id        bigint generated always as identity primary key,
  user_id   text not null default (auth.jwt()->>'sub'),
  texto     text,
  foto_path text,               -- ruta dentro del bucket notas-compra
  estado    text not null default 'pendiente',   -- pendiente | procesada | error
  resultado jsonb,
  creado_en timestamptz not null default now(),
  constraint compra_con_algo check (coalesce(texto,'') <> '' or foto_path is not null)
);

create table if not exists public.costos_historial (
  id          bigint generated always as identity primary key,
  user_id     text not null,
  producto_id bigint not null references public.productos(id) on delete cascade,
  compra_id   bigint references public.compras(id) on delete set null,
  costo       numeric(12,2) not null,
  cantidad    numeric(12,2),
  creado_en   timestamptz not null default now()
);

create table if not exists public.alertas (
  id          bigint generated always as identity primary key,
  user_id     text not null,
  producto_id bigint references public.productos(id) on delete cascade,
  tipo        text not null default 'stock_bajo',
  mensaje     text not null,
  creado_en   timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 2. SEGURIDAD (RLS): cada persona ve y toca sólo lo suyo.
-- ---------------------------------------------------------------------
alter table public.negocios         enable row level security;
alter table public.productos        enable row level security;
alter table public.ventas           enable row level security;
alter table public.compras          enable row level security;
alter table public.costos_historial enable row level security;
alter table public.alertas          enable row level security;

drop policy if exists "dueño negocio"      on public.negocios;
drop policy if exists "dueño productos"    on public.productos;
drop policy if exists "ver mis ventas"     on public.ventas;
drop policy if exists "crear mis ventas"   on public.ventas;
drop policy if exists "ver mis compras"    on public.compras;
drop policy if exists "crear mis compras"  on public.compras;
drop policy if exists "ver mis costos"     on public.costos_historial;
drop policy if exists "ver mis alertas"    on public.alertas;

create policy "dueño negocio" on public.negocios for all to authenticated
  using ((select auth.jwt()->>'sub') = user_id)
  with check ((select auth.jwt()->>'sub') = user_id);

create policy "dueño productos" on public.productos for all to authenticated
  using ((select auth.jwt()->>'sub') = user_id)
  with check ((select auth.jwt()->>'sub') = user_id);

create policy "ver mis ventas" on public.ventas for select to authenticated
  using ((select auth.jwt()->>'sub') = user_id);
create policy "crear mis ventas" on public.ventas for insert to authenticated
  with check ((select auth.jwt()->>'sub') = user_id);

create policy "ver mis compras" on public.compras for select to authenticated
  using ((select auth.jwt()->>'sub') = user_id);
create policy "crear mis compras" on public.compras for insert to authenticated
  with check ((select auth.jwt()->>'sub') = user_id);

create policy "ver mis costos" on public.costos_historial for select to authenticated
  using ((select auth.jwt()->>'sub') = user_id);

create policy "ver mis alertas" on public.alertas for select to authenticated
  using ((select auth.jwt()->>'sub') = user_id);

-- ---------------------------------------------------------------------
-- 3. CONFIGURACIÓN PRIVADA (dirección de n8n y secreto compartido).
--    El esquema "privado" no se publica en la API: nadie desde la web
--    puede leerlo.
-- ---------------------------------------------------------------------
create schema if not exists privado;
revoke all on schema privado from public, anon, authenticated;

create table if not exists privado.config_n8n (
  id      int primary key default 1 check (id = 1),
  url     text not null default '',
  secreto text not null default ''
);
insert into privado.config_n8n (id) values (1) on conflict (id) do nothing;

-- Manda un aviso JSON a n8n (asíncrono: no frena la venta).
create or replace function privado.avisar_n8n(payload jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare c record;
begin
  select url, secreto into c from privado.config_n8n where id = 1;
  if c.url is null or c.url = '' then return; end if;
  perform net.http_post(
    url     := c.url,
    body    := payload,
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'x-webhook-secret', c.secreto),
    timeout_milliseconds := 10000
  );
end $$;

-- ---------------------------------------------------------------------
-- 4. TRIGGERS
-- ---------------------------------------------------------------------

-- 4a. Al registrar una venta: valida, completa precio y descuenta stock.
create or replace function public.tg_venta_descuenta_stock()
returns trigger language plpgsql set search_path = '' as $$
declare p record;
begin
  select * into p from public.productos
   where id = new.producto_id and user_id = new.user_id
   for update;
  if not found then
    raise exception 'El producto % no existe o no es tuyo', new.producto_id;
  end if;
  if p.stock < new.cantidad then
    raise exception 'Stock insuficiente de "%": quedan % %', p.nombre, p.stock, p.unidad;
  end if;
  new.precio_unitario := coalesce(new.precio_unitario, p.precio_venta);
  new.total := round(new.cantidad * new.precio_unitario, 2);
  update public.productos
     set stock = stock - new.cantidad, actualizado_en = now()
   where id = p.id;
  return new;
end $$;

drop trigger if exists venta_descuenta_stock on public.ventas;
create trigger venta_descuenta_stock
  before insert on public.ventas
  for each row execute function public.tg_venta_descuenta_stock();

-- 4b. Cada vez que cambia el stock o el mínimo de un producto → aviso a n8n.
create or replace function privado.tg_producto_aviso()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform privado.avisar_n8n(jsonb_build_object(
    'tipo', 'producto_actualizado',
    'operacion', tg_op,
    'record', to_jsonb(new),
    'old_record', case when tg_op = 'UPDATE' then to_jsonb(old) else null end
  ));
  return new;
end $$;

drop trigger if exists producto_aviso_upd on public.productos;
create trigger producto_aviso_upd
  after update of stock, stock_minimo on public.productos
  for each row
  when (old.stock is distinct from new.stock or old.stock_minimo is distinct from new.stock_minimo)
  execute function privado.tg_producto_aviso();

drop trigger if exists producto_aviso_ins on public.productos;
create trigger producto_aviso_ins
  after insert on public.productos
  for each row execute function privado.tg_producto_aviso();

-- 4c. Cada nota de compra nueva → aviso a n8n (Gemini la lee).
create or replace function privado.tg_compra_aviso()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform privado.avisar_n8n(jsonb_build_object(
    'tipo', 'compra_registrada',
    'record', to_jsonb(new)
  ));
  return new;
end $$;

drop trigger if exists compra_aviso on public.compras;
create trigger compra_aviso
  after insert on public.compras
  for each row execute function privado.tg_compra_aviso();

-- ---------------------------------------------------------------------
-- 5. FUNCIONES QUE USA n8n (sólo con la service_role key).
-- ---------------------------------------------------------------------

-- 5a. Todo lo que Gemini necesita para recomendar una reposición.
create or replace function public.contexto_reposicion(p_producto_id bigint)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'producto', to_jsonb(p),
    'negocio', (select to_jsonb(n) from public.negocios n where n.user_id = p.user_id),
    'vendido_7_dias',  (select coalesce(sum(cantidad),0) from public.ventas v
                         where v.producto_id = p.id and v.creado_en > now() - interval '7 days'),
    'vendido_30_dias', (select coalesce(sum(cantidad),0) from public.ventas v
                         where v.producto_id = p.id and v.creado_en > now() - interval '30 days'),
    'ventas_por_dia',  (select coalesce(jsonb_agg(d order by d.dia), '[]'::jsonb) from (
                          select (creado_en at time zone 'America/La_Paz')::date as dia,
                                 sum(cantidad) as cantidad
                            from public.ventas v
                           where v.producto_id = p.id and v.creado_en > now() - interval '30 days'
                           group by 1) d),
    'costos_recientes', (select coalesce(jsonb_agg(c order by c.creado_en desc), '[]'::jsonb) from (
                          select costo, cantidad, creado_en from public.costos_historial h
                           where h.producto_id = p.id order by creado_en desc limit 5) c)
  )
  from public.productos p where p.id = p_producto_id;
$$;

-- 5b. La nota de compra + la lista de productos del negocio (para que
--     Gemini relacione "coca 2L" con el producto correcto).
create or replace function public.contexto_compra(p_compra_id bigint)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'compra', to_jsonb(c),
    'negocio', (select to_jsonb(n) from public.negocios n where n.user_id = c.user_id),
    'productos', (select coalesce(jsonb_agg(jsonb_build_object(
                     'id', p.id, 'nombre', p.nombre, 'unidad', p.unidad, 'costo', p.costo)), '[]'::jsonb)
                    from public.productos p where p.user_id = c.user_id)
  )
  from public.compras c where c.id = p_compra_id;
$$;

-- 5c. Aplica lo que Gemini leyó de la nota: suma stock, actualiza costo,
--     guarda historial y devuelve cuánto variaron los costos.
--     p_items = [{"producto_id": 3, "nombre": "...", "cantidad": 20, "costo_unitario": 8.5}, ...]
create or replace function public.aplicar_compra(p_compra_id bigint, p_items jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c public.compras%rowtype;
  it jsonb;
  p public.productos%rowtype;
  cambios jsonb := '[]'::jsonb;
  sin_match jsonb := '[]'::jsonb;
  v_cant numeric; v_costo numeric;
begin
  select * into c from public.compras where id = p_compra_id for update;
  if not found then raise exception 'Compra % no existe', p_compra_id; end if;
  if c.estado <> 'pendiente' then
    return jsonb_build_object('ya_procesada', true);
  end if;

  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    v_cant  := nullif(it->>'cantidad','')::numeric;
    v_costo := nullif(it->>'costo_unitario','')::numeric;
    select * into p from public.productos
     where id = nullif(it->>'producto_id','')::bigint and user_id = c.user_id
     for update;
    if not found then
      sin_match := sin_match || jsonb_build_array(it);
      continue;
    end if;
    update public.productos set
      stock  = stock + coalesce(v_cant, 0),
      costo  = coalesce(v_costo, costo),
      actualizado_en = now()
    where id = p.id;
    if v_costo is not null then
      insert into public.costos_historial (user_id, producto_id, compra_id, costo, cantidad)
      values (c.user_id, p.id, c.id, v_costo, v_cant);
    end if;
    cambios := cambios || jsonb_build_array(jsonb_build_object(
      'producto', p.nombre,
      'cantidad', v_cant,
      'stock_nuevo', p.stock + coalesce(v_cant, 0),
      'costo_anterior', p.costo,
      'costo_nuevo', coalesce(v_costo, p.costo),
      'variacion_pct', case when p.costo > 0 and v_costo is not null
                            then round((v_costo - p.costo) / p.costo * 100, 1) end
    ));
  end loop;

  update public.compras
     set estado = 'procesada',
         resultado = jsonb_build_object('cambios', cambios, 'no_encontrados', sin_match)
   where id = c.id;
  return jsonb_build_object('cambios', cambios, 'no_encontrados', sin_match);
end $$;

-- 5d. Guarda la alerta enviada y marca la hora (para no repetir avisos).
create or replace function public.registrar_alerta(p_producto_id bigint, p_mensaje text)
returns void language sql security definer set search_path = '' as $$
  update public.productos set ultima_alerta = now() where id = p_producto_id;
  insert into public.alertas (user_id, producto_id, mensaje)
  select user_id, id, p_mensaje from public.productos where id = p_producto_id;
$$;

-- 5e. Marca una compra con error (si Gemini no pudo leerla).
create or replace function public.marcar_compra_error(p_compra_id bigint, p_detalle text)
returns void language sql security definer set search_path = '' as $$
  update public.compras set estado = 'error', resultado = jsonb_build_object('error', p_detalle)
   where id = p_compra_id and estado = 'pendiente';
$$;

-- Estas funciones NO las puede llamar nadie desde la web, sólo n8n.
revoke execute on function public.contexto_reposicion(bigint)       from public, anon, authenticated;
revoke execute on function public.contexto_compra(bigint)           from public, anon, authenticated;
revoke execute on function public.aplicar_compra(bigint, jsonb)     from public, anon, authenticated;
revoke execute on function public.registrar_alerta(bigint, text)    from public, anon, authenticated;
revoke execute on function public.marcar_compra_error(bigint, text) from public, anon, authenticated;
grant  execute on function public.contexto_reposicion(bigint)       to service_role;
grant  execute on function public.contexto_compra(bigint)           to service_role;
grant  execute on function public.aplicar_compra(bigint, jsonb)     to service_role;
grant  execute on function public.registrar_alerta(bigint, text)    to service_role;
grant  execute on function public.marcar_compra_error(bigint, text) to service_role;

-- ---------------------------------------------------------------------
-- 6. FOTOS DE NOTAS DE COMPRA (Storage, bucket privado)
--    Cada persona sube a una carpeta con su id: user_2abc/1700000.jpg
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('notas-compra', 'notas-compra', false)
on conflict (id) do nothing;

drop policy if exists "subir mis notas" on storage.objects;
drop policy if exists "ver mis notas"   on storage.objects;

create policy "subir mis notas" on storage.objects for insert to authenticated
  with check (bucket_id = 'notas-compra'
              and (storage.foldername(name))[1] = (select auth.jwt()->>'sub'));
create policy "ver mis notas" on storage.objects for select to authenticated
  using (bucket_id = 'notas-compra'
         and (storage.foldername(name))[1] = (select auth.jwt()->>'sub'));

-- =====================================================================
--  ÚLTIMO PASO (después de publicar el workflow en n8n):
--  reemplazá los dos valores y corré sólo estas líneas.
--
--  update privado.config_n8n
--     set url = 'https://TU-N8N/webhook/monitor-stock',
--         secreto = 'una-frase-larga-y-secreta'
--   where id = 1;
-- =====================================================================
