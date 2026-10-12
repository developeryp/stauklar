# Stauklar Push-Server

Supabase-Projekt „Stauklar“ (`lcpfcgbfsibmankfwsqn`, Region Frankfurt, kostenloser Tarif).

- `migrations/002_push_switches.sql`: Morgenlage (`digest_on`) und Sofortmeldung (`alerts_on`) je Gerät abschaltbar.
- `migrations/001_push.sql`: Tabellen `devices` (Token + Lieblingsstrecken) und `sent` (schon verschickte Meldungen),
  Funktion `get_secret()` für den Vault, Erweiterungen pg_cron und pg_net.
- `functions/notify/index.ts`: Edge Function. Läuft jede Minute (pg_cron-Job `stauklar-notify`):
  - ein Push bei jeder neuen Vollsperrung heute auf einer Lieblingsstrecke, sobald sie in den Daten auftaucht (die Daten selbst werden alle 15 Minuten neu geholt)
  - die Morgenlage genau zur Wunschzeit des Geräts (`digest_time`, Standard 06:30 Ortszeit) mit allen Sperrungen heute auf den eigenen Strecken
- Die App meldet Push-Token, Favoriten und Wunschzeit über die Funktion `register_device` (anon-Schlüssel; kein Lesen, kein direkter Tabellenzugriff).

## Geheimnisse (Supabase Vault)

| Name | Inhalt |
|---|---|
| `cron_secret` | Zufallswert, schützt den Aufruf der Funktion (schon angelegt) |
| `apns_key_id` | Key ID des APNs-Schlüssels aus dem Apple-Developer-Konto, z. B. `AB12CD34EF` |
| `apns_key` | Inhalt der `.p8`-Datei (inkl. BEGIN/END-Zeilen) |

APNs-Schlüssel anlegen: developer.apple.com → Certificates, Identifiers & Profiles → Keys → „+“ →
Name „Stauklar Push“, „Apple Push Notifications service (APNs)“ anhaken → Continue → Register → Download.
Die .p8-Datei lässt sich nur einmal herunterladen.

Eintragen im Supabase SQL-Editor:

```sql
select vault.create_secret('AB12CD34EF', 'apns_key_id');
select vault.create_secret('-----BEGIN PRIVATE KEY-----
…
-----END PRIVATE KEY-----', 'apns_key');
```

## Testen

Morgenlage sofort auslösen (im SQL-Editor):

```sql
select net.http_post(
  url := 'https://lcpfcgbfsibmankfwsqn.supabase.co/functions/v1/notify?force=digest',
  headers := jsonb_build_object('Content-Type','application/json','x-cron-secret',(select decrypted_secret from vault.decrypted_secrets where name='cron_secret')),
  body := '{}'::jsonb);
select status_code, content::text from net._http_response order by id desc limit 1;
```
