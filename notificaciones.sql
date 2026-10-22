-- =====================================================================
-- NOTIFICACIONES · Registro de Solicitudes CEDIS
-- Ejecutar UNA VEZ en Supabase: SQL Editor > New query > pegar > Run
-- =====================================================================

-- 1) Tabla de notificaciones (una fila por usuario destinatario)
create table if not exists public.notificaciones (
  id             bigint generated always as identity primary key,
  user_id        uuid not null references auth.users(id) on delete cascade,
  tipo           text not null,            -- 'nueva' | 'aprobada' | 'cargada' | 'rechazada' | 'eliminada'
  nro_solicitud  text,
  mensaje        text not null,
  leida          boolean not null default false,
  created_at     timestamptz not null default now()
);

create index if not exists notificaciones_user_idx
  on public.notificaciones (user_id, leida, created_at desc);

-- 2) Seguridad (RLS): cada usuario ve y modifica solo sus notificaciones.
--    No hay política de INSERT: solo los triggers (security definer) crean filas.
alter table public.notificaciones enable row level security;

drop policy if exists "notif_select_propias" on public.notificaciones;
create policy "notif_select_propias" on public.notificaciones
  for select to authenticated using (user_id = auth.uid());

drop policy if exists "notif_update_propias" on public.notificaciones;
create policy "notif_update_propias" on public.notificaciones
  for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "notif_delete_propias" on public.notificaciones;
create policy "notif_delete_propias" on public.notificaciones
  for delete to authenticated using (user_id = auth.uid());

-- 3) Función que crea las notificaciones.
--    Destinatarios: todos los perfiles con rol 'cedis' o 'admin'
--    + (si se indica) el dueño de la solicitud. Se excluye a quien hizo la acción.
create or replace function public.crear_notificaciones(
  p_tipo text, p_nro text, p_mensaje text, p_incluir_dueno uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Evita duplicados: la solicitud tiene varias filas y cada una dispara el trigger.
  if exists (
    select 1 from public.notificaciones
    where tipo = p_tipo
      and nro_solicitud is not distinct from p_nro
      and created_at > now() - interval '1 minute'
  ) then
    return;
  end if;

  insert into public.notificaciones (user_id, tipo, nro_solicitud, mensaje)
  select distinct d.uid, p_tipo, p_nro, p_mensaje
  from (
    select u.id as uid
    from public.perfiles p
    join auth.users u
      on u.id = p.id or lower(u.email) = lower(p.email)
    where lower(p.rol) in ('cedis', 'admin')
    union
    select p_incluir_dueno where p_incluir_dueno is not null
  ) d
  where d.uid is distinct from auth.uid();   -- quitar esta línea si quieres notificar también a quien ejecuta la acción
end;
$$;

-- 4) Trigger: solicitud nueva (rol cedis/admin)
create or replace function public.trg_notif_solicitud_nueva()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.crear_notificaciones(
    'nueva',
    new.nro_solicitud::text,
    'Nueva solicitud N.º ' || coalesce(new.nro_solicitud::text, 's/n')
      || ' de ' || coalesce(new.solicitante, 'un usuario')
      || ' (' || coalesce(new.area_origen, 'sin área') || ')',
    null
  );
  return new;
end;
$$;

drop trigger if exists notif_solicitud_nueva on public.solicitudes;
create trigger notif_solicitud_nueva
  after insert on public.solicitudes
  for each row execute function public.trg_notif_solicitud_nueva();

-- 5) Trigger: cambios de estado
--    aprobada / cargada / rechazada -> cedis/admin + quien la registró
--    eliminada -> solo cedis/admin
create or replace function public.trg_notif_solicitud_estado()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.estado = 'RECHAZADO' then
    perform public.crear_notificaciones(
      'rechazada',
      new.nro_solicitud::text,
      'La solicitud N.º ' || coalesce(new.nro_solicitud::text, 's/n') || ' fue RECHAZADA',
      new.user_id
    );
  elsif new.estado = 'ELIMINADO' then
    perform public.crear_notificaciones(
      'eliminada',
      new.nro_solicitud::text,
      'La solicitud N.º ' || coalesce(new.nro_solicitud::text, 's/n')
        || ' de ' || coalesce(new.solicitante, 'un usuario') || ' fue ELIMINADA',
      null
    );
  elsif new.estado = 'APROBADO' then
    perform public.crear_notificaciones(
      'aprobada',
      new.nro_solicitud::text,
      'La solicitud N.º ' || coalesce(new.nro_solicitud::text, 's/n') || ' fue APROBADA',
      new.user_id
    );
  elsif new.estado in ('CARGADO', 'CARGADO CON OBS') then
    perform public.crear_notificaciones(
      'cargada',
      new.nro_solicitud::text,
      'La solicitud N.º ' || coalesce(new.nro_solicitud::text, 's/n')
        || ' fue ' || new.estado,
      new.user_id
    );
  end if;
  return new;
end;
$$;

drop trigger if exists notif_solicitud_estado on public.solicitudes;
create trigger notif_solicitud_estado
  after update of estado on public.solicitudes
  for each row
  when (old.estado is distinct from new.estado)
  execute function public.trg_notif_solicitud_estado();

-- 6) Tiempo real: permite que la campana se actualice al instante
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public' and tablename = 'notificaciones'
  ) then
    alter publication supabase_realtime add table public.notificaciones;
  end if;
end $$;
