-- Stauklar Push: Geräte, bereits gesendete Meldungen, Geheimnisse, Zeitplan

create table if not exists public.devices (
  token text primary key,
  platform text not null default 'ios',
  env text not null default 'production',     -- 'sandbox' für Debug-Builds
  roads text[] not null default '{}',          -- Lieblingsstrecken, z. B. {A7,A1}
  tz text not null default 'Europe/Berlin',
  digest_time text not null default '06:30',       -- Wunschzeit der Morgenlage
  updated_at timestamptz not null default now()
);

create table if not exists public.sent (
  token text not null references public.devices(token) on delete cascade,
  key text not null,                            -- z. B. A7/m12/2026-10-12T20:00:00+02:00 oder digest/2026-10-12
  sent_at timestamptz not null default now(),
  primary key (token, key)
);

alter table public.devices enable row level security;
alter table public.sent enable row level security;

-- Die App registriert sich nur über die Funktion register_device (kein direkter Tabellenzugriff, kein Lesen)
create or replace function public.register_device(p_token text, p_platform text, p_env text, p_roads text[], p_tz text, p_digest_time text)
returns void language sql security definer set search_path = '' as $$
  insert into public.devices (token, platform, env, roads, tz, digest_time, updated_at)
  values (p_token, coalesce(p_platform, 'ios'), coalesce(p_env, 'production'), coalesce(p_roads, '{}'), coalesce(p_tz, 'Europe/Berlin'), coalesce(p_digest_time, '06:30'), now())
  on conflict (token) do update
    set platform = excluded.platform, env = excluded.env, roads = excluded.roads, tz = excluded.tz, digest_time = excluded.digest_time, updated_at = now();
$$;
revoke all on function public.register_device(text, text, text, text[], text, text) from public;
grant execute on function public.register_device(text, text, text, text[], text, text) to anon, authenticated, service_role;

-- Geheimnisse aus dem Vault, nur für den Server (Service-Role)
create or replace function public.get_secret(name text)
returns text language sql security definer set search_path = '' as $$
  select decrypted_secret from vault.decrypted_secrets where vault.decrypted_secrets.name = get_secret.name limit 1;
$$;
revoke all on function public.get_secret(text) from public, anon, authenticated;
grant execute on function public.get_secret(text) to service_role;

create extension if not exists pg_cron;
create extension if not exists pg_net;
