-- Sofortmeldung wahlweise für alle neuen Meldungen (Baustellen, Sperrungen, Staus), nicht nur Vollsperrungen.
alter table public.devices add column if not exists alerts_all boolean not null default false;

drop function if exists public.register_device(text, text, text, text[], text, text, boolean, boolean);

create or replace function public.register_device(
  p_token text, p_platform text, p_env text, p_roads text[], p_tz text, p_digest_time text,
  p_digest_on boolean default true, p_alerts_on boolean default true, p_alerts_all boolean default false)
returns void language sql security definer set search_path = '' as $$
  insert into public.devices (token, platform, env, roads, tz, digest_time, digest_on, alerts_on, alerts_all, updated_at)
  values (p_token, coalesce(p_platform, 'ios'), coalesce(p_env, 'production'), coalesce(p_roads, '{}'), coalesce(p_tz, 'Europe/Berlin'),
          coalesce(p_digest_time, '06:30'), coalesce(p_digest_on, true), coalesce(p_alerts_on, true), coalesce(p_alerts_all, false), now())
  on conflict (token) do update
    set platform = excluded.platform, env = excluded.env, roads = excluded.roads, tz = excluded.tz, digest_time = excluded.digest_time,
        digest_on = excluded.digest_on, alerts_on = excluded.alerts_on, alerts_all = excluded.alerts_all, updated_at = now();
$$;
revoke all on function public.register_device(text, text, text, text[], text, text, boolean, boolean, boolean) from public;
grant execute on function public.register_device(text, text, text, text[], text, text, boolean, boolean, boolean) to anon, authenticated, service_role;
