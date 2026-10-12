-- Sofortmeldung je Art wählbar: voll, sperr, kurz, dauer, live. NULL = altes Verhalten (alerts_on/alerts_all).
alter table public.devices add column if not exists alert_kinds text[];

drop function if exists public.register_device(text, text, text, text[], text, text, boolean, boolean, boolean);

create or replace function public.register_device(
  p_token text, p_platform text, p_env text, p_roads text[], p_tz text, p_digest_time text,
  p_digest_on boolean default true, p_alerts_on boolean default true, p_alerts_all boolean default false,
  p_alert_kinds text[] default null)
returns void language sql security definer set search_path = '' as $$
  insert into public.devices (token, platform, env, roads, tz, digest_time, digest_on, alerts_on, alerts_all, alert_kinds, updated_at)
  values (p_token, coalesce(p_platform, 'ios'), coalesce(p_env, 'production'), coalesce(p_roads, '{}'), coalesce(p_tz, 'Europe/Berlin'),
          coalesce(p_digest_time, '06:30'), coalesce(p_digest_on, true), coalesce(p_alerts_on, true), coalesce(p_alerts_all, false), p_alert_kinds, now())
  on conflict (token) do update
    set platform = excluded.platform, env = excluded.env, roads = excluded.roads, tz = excluded.tz, digest_time = excluded.digest_time,
        digest_on = excluded.digest_on, alerts_on = excluded.alerts_on, alerts_all = excluded.alerts_all, alert_kinds = excluded.alert_kinds, updated_at = now();
$$;
revoke all on function public.register_device(text, text, text, text[], text, text, boolean, boolean, boolean, text[]) from public;
grant execute on function public.register_device(text, text, text, text[], text, text, boolean, boolean, boolean, text[]) to anon, authenticated, service_role;
