-- NUR für den Lauf gegen ein nacktes Postgres (docker, CI ohne Supabase-Stack).
--
-- Im Projekt kommen diese Objekte von Supabase selbst: die Rollen anon / authenticated /
-- service_role, das Schema auth mit auth.users und auth.uid(). auth.uid() liest die Claims
-- des JWT, die PostgREST als "request.jwt.claims" in die Sitzung legt - genau das macht die
-- Nachbildung hier, damit die Tests dieselbe Funktion benutzen wie die echte Datenbank.

-- Idempotent, weil das Supabase-Docker-Image diese Rollen schon mitbringt und ein nacktes
-- Postgres nicht. Mitgliedschaft wird nur für selbst angelegte Rollen vergeben:
-- "grant authenticated to current_user" bringt im Image supabase/postgres den Backend-Prozess
-- zum Absturz (Signal 11, supautils bewacht die reservierten Rollen), und dort ist postgres
-- ohnehin schon Mitglied.
do $$
declare
  r text;
begin
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if not exists (select 1 from pg_roles where rolname = r) then
      execute format('create role %I nologin', r);
      execute format('grant %I to current_user', r);
    end if;
  end loop;
end
$$;

create schema if not exists auth;

create table if not exists auth.users (
  id    uuid primary key,
  email text unique
);

create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(
    coalesce(
      current_setting('request.jwt.claim.sub', true),
      (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
    ),
    ''
  )::uuid
$$;

create or replace function auth.role()
returns text
language sql
stable
as $$
  select coalesce(
    current_setting('request.jwt.claim.role', true),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )
$$;

grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.role() to anon, authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;
