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

-- Die App darf ihr Gerät anlegen und aktualisieren, aber nichts lesen
create policy "app registriert gerät" on public.devices for insert to anon with check (true);
create policy "app aktualisiert gerät" on public.devices for update to anon using (true) with check (true);

-- Geheimnisse aus dem Vault, nur für den Server (Service-Role)
create or replace function public.get_secret(name text)
returns text language sql security definer set search_path = '' as $$
  select decrypted_secret from vault.decrypted_secrets where vault.decrypted_secrets.name = get_secret.name limit 1;
$$;
revoke all on function public.get_secret(text) from public, anon, authenticated;
grant execute on function public.get_secret(text) to service_role;

create extension if not exists pg_cron;
create extension if not exists pg_net;
