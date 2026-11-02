-- Zugriffsregeln.
--
-- Drei Entscheidungen, die den Rest erklären:
--
-- 1. Jede Policy fragt eine Hilfsfunktion, keine Unterabfrage auf dieselbe Tabelle.
--    Eine Policy auf "profile", die "profile" liest, läuft in die Rekursion (42P17) - der
--    häufigste Fehler in Supabase-Projekten. SECURITY DEFINER bricht den Kreis, weil die
--    Funktion dem Tabelleneigentümer gehört und RLS für ihn nicht gilt.
-- 2. "set search_path = ''" bei jeder SECURITY DEFINER-Funktion, alles voll qualifiziert.
--    Ohne das kann ein Aufrufer mit eigenem search_path unterschieben, was ausgeführt wird.
-- 3. Statuswechsel laufen nie über die Tabelle, sondern über Funktionen. Eine Policy kann
--    "nur vorwärts" nicht ausdrücken, ein Trigger schon.

create or replace function app.rolle()
returns public.app_rolle
language sql
stable
security definer
set search_path = ''
as $$
  select p.rolle
    from public.profile p
   where p.id = auth.uid()
     and p.aktiv
$$;

create or replace function app.ist_buero()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(app.rolle() in ('buero', 'geschaeftsfuehrung'), false)
$$;

-- Trupps, in denen ich stehe - als Mitglied oder als Vorarbeiter.
create or replace function app.meine_truppen()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select tm.trupp_id
    from public.trupp_mitglied tm
   where tm.profile_id = auth.uid()
  union
  select t.id
    from public.trupp t
   where t.vorarbeiter_id = auth.uid()
$$;

create or replace function app.ist_vorarbeiter_von(p_trupp uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.trupp t
     where t.id = p_trupp
       and t.vorarbeiter_id = auth.uid()
  )
$$;

-- Kollege im selben Trupp: reicht für Namen, nicht für Stunden.
create or replace function app.ist_kollege(p_profile uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.trupp_mitglied tm
     where tm.profile_id = p_profile
       and tm.trupp_id in (select app.meine_truppen())
  )
$$;

-- Fremde Stunden sieht nur, wer für sie verantwortlich ist: der Vorarbeiter seines Trupps.
create or replace function app.ist_mein_monteur(p_profile uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.trupp t
      join public.trupp_mitglied tm on tm.trupp_id = t.id
     where t.vorarbeiter_id = auth.uid()
       and tm.profile_id = p_profile
  )
$$;

create or replace function app.projekt_erlaubt(p_projekt uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select app.ist_buero() or exists (
    select 1
      from public.projekt pr
     where pr.id = p_projekt
       and pr.trupp_id in (select app.meine_truppen())
  )
$$;

-- Die Nachbuchungsfrist steht an einer Stelle, weil Policy, Trigger und Oberfläche
-- dieselbe Zahl brauchen.
create or replace function app.nachbuchungsfrist()
returns integer
language sql
immutable
set search_path = ''
as $$
  select 14
$$;

grant execute on function app.rolle(), app.ist_buero(), app.meine_truppen(),
                         app.ist_vorarbeiter_von(uuid), app.ist_kollege(uuid),
                         app.ist_mein_monteur(uuid), app.projekt_erlaubt(uuid),
                         app.nachbuchungsfrist()
  to authenticated;

alter table public.profile enable row level security;
alter table public.trupp enable row level security;
alter table public.trupp_mitglied enable row level security;
alter table public.projekt enable row level security;
alter table public.zeiteintrag enable row level security;
alter table public.freigabe_protokoll enable row level security;

-- profile ------------------------------------------------------------------------------
create policy profile_select on public.profile
  for select to authenticated
  using (id = auth.uid() or app.ist_buero() or app.ist_kollege(id));

create policy profile_update_eigenes on public.profile
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

create policy profile_schreiben_buero on public.profile
  for all to authenticated
  using (app.ist_buero())
  with check (app.ist_buero());

-- trupp --------------------------------------------------------------------------------
create policy trupp_select on public.trupp
  for select to authenticated
  using (app.ist_buero() or id in (select app.meine_truppen()));

create policy trupp_schreiben_buero on public.trupp
  for all to authenticated
  using (app.ist_buero())
  with check (app.ist_buero());

create policy trupp_mitglied_select on public.trupp_mitglied
  for select to authenticated
  using (app.ist_buero() or trupp_id in (select app.meine_truppen()));

create policy trupp_mitglied_schreiben_buero on public.trupp_mitglied
  for all to authenticated
  using (app.ist_buero())
  with check (app.ist_buero());

-- projekt ------------------------------------------------------------------------------
create policy projekt_select on public.projekt
  for select to authenticated
  using (app.ist_buero() or trupp_id in (select app.meine_truppen()));

create policy projekt_schreiben_buero on public.projekt
  for all to authenticated
  using (app.ist_buero())
  with check (app.ist_buero());

-- zeiteintrag --------------------------------------------------------------------------
create policy zeiteintrag_select on public.zeiteintrag
  for select to authenticated
  using (
    profile_id = auth.uid()
    or app.ist_buero()
    or app.ist_mein_monteur(profile_id)
  );

-- Erfassen: nur für sich, nur auf eigenen Baustellen, nur innerhalb der Frist und nie
-- gleich freigegeben.
create policy zeiteintrag_insert_eigener on public.zeiteintrag
  for insert to authenticated
  with check (
    profile_id = auth.uid()
    and status = 'erfasst'
    and freigegeben_von is null
    and freigegeben_am is null
    and datum <= current_date
    and datum >= current_date - app.nachbuchungsfrist()
    and app.projekt_erlaubt(projekt_id)
  );

-- Korrigieren: nur solange nichts freigegeben ist.
create policy zeiteintrag_update_eigener on public.zeiteintrag
  for update to authenticated
  using (profile_id = auth.uid() and status = 'erfasst')
  with check (
    profile_id = auth.uid()
    and status = 'erfasst'
    and datum <= current_date
    and datum >= current_date - app.nachbuchungsfrist()
    and app.projekt_erlaubt(projekt_id)
  );

create policy zeiteintrag_delete_eigener on public.zeiteintrag
  for delete to authenticated
  using (profile_id = auth.uid() and status = 'erfasst');

create policy zeiteintrag_schreiben_buero on public.zeiteintrag
  for all to authenticated
  using (app.ist_buero())
  with check (app.ist_buero());

-- freigabe_protokoll -------------------------------------------------------------------
-- Nur lesen: geschrieben wird ausschließlich in public.zeiten_freigeben().
create policy freigabe_protokoll_select on public.freigabe_protokoll
  for select to authenticated
  using (app.ist_buero() or app.ist_vorarbeiter_von(trupp_id));

-- Wächter gegen den direkten Weg -------------------------------------------------------
-- Die Policy oben erlaubt dem Büro "for all". Ohne Trigger könnte das Büro damit einen
-- Eintrag von "abgerechnet" zurück auf "erfasst" setzen oder einen Zeiteintrag einem
-- anderen Monteur unterschieben. Beides gehört in eine Funktion mit Protokoll.
create or replace function app.zeiteintrag_wacht()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Die Freigabefunktionen setzen diese Variable für die Dauer ihrer Transaktion.
  if coalesce(current_setting('app.freigabe', true), '') = 'laeuft' then
    return new;
  end if;

  if new.status is distinct from old.status then
    raise exception 'Status wird nur über public.zeiten_freigeben() oder public.zeiten_freigabe_aufheben() geändert'
      using errcode = '42501';
  end if;

  if new.profile_id is distinct from old.profile_id then
    raise exception 'Ein Zeiteintrag kann nicht auf einen anderen Monteur umgehängt werden'
      using errcode = '42501';
  end if;

  if old.status <> 'erfasst' then
    raise exception 'Freigegebene Stunden werden nicht mehr bearbeitet'
      using errcode = '42501';
  end if;

  return new;
end
$$;

create trigger zeiteintrag_wacht
  before update on public.zeiteintrag
  for each row
  execute function app.zeiteintrag_wacht();
