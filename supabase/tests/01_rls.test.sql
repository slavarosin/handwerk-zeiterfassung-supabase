-- Wer sieht was, und wer darf was schreiben.
--
-- Die Tests beschreiben die Regel in der Sprache des Betriebs: "ein Monteur sieht die
-- Stunden seines Kollegen nicht", "nachbuchen geht 14 Tage". Bricht eine Policy, sagt der
-- Testname, welche Zusage verletzt ist.
begin;

create extension if not exists pgtap;

select plan(14);

-- Rollenwechsel für die Tests: genau das, was PostgREST pro Anfrage tut - Rolle auf
-- "authenticated" setzen und die JWT-Claims in die Sitzung legen. Danach gilt RLS wie in
-- der echten API, weil current_user nicht mehr der Tabelleneigentümer ist.
create or replace function public.tests_als(p_id uuid)
returns void
language plpgsql
as $$
begin
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', p_id, 'role', 'authenticated')::text,
    true
  );
  perform set_config('role', 'authenticated', true);
end
$$;

-- Nicht angemeldeter Besucher.
create or replace function public.tests_als_anon()
returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('role', 'anon', true);
end
$$;

create or replace function public.tests_als_eigentuemer()
returns void
language plpgsql
as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
end
$$;

-- Feste IDs aus seed.sql
\set gf       '\'00000000-0000-0000-0000-0000000000f1\'::uuid'
\set buero    '\'00000000-0000-0000-0000-0000000000b1\'::uuid'
\set va_nord  '\'00000000-0000-0000-0000-00000000a001\'::uuid'
\set mo_nord1 '\'00000000-0000-0000-0000-00000000a002\'::uuid'
\set mo_nord2 '\'00000000-0000-0000-0000-00000000a003\'::uuid'
\set va_sued  '\'00000000-0000-0000-0000-00000000b001\'::uuid'
\set projekt_nord '\'00000000-0000-0000-0000-0000000000a9\'::uuid'
\set projekt_sued '\'00000000-0000-0000-0000-0000000000b9\'::uuid'

-- Monteur ------------------------------------------------------------------------------
select public.tests_als(:mo_nord1);

select is(
  (select count(*) from public.zeiteintrag)::int, 3,
  'Monteur sieht genau seine drei eigenen Zeiteinträge'
);

select is(
  (select count(*) from public.zeiteintrag where profile_id = :mo_nord2)::int, 0,
  'Monteur sieht die Stunden seines Kollegen nicht'
);

select is(
  (select count(*) from public.profile)::int, 3,
  'Monteur sieht die Namen seines Trupps, nicht den ganzen Betrieb'
);

select is(
  (select count(*) from public.projekt)::int, 1,
  'Monteur sieht nur die Baustelle seines Trupps'
);

select throws_ok(
  format($$insert into public.zeiteintrag (projekt_id, profile_id, datum, stunden, taetigkeit)
           values (%L, %L, current_date, 5, 'Fremdbuchung')$$, :projekt_nord, :mo_nord2),
  '42501', null,
  'Monteur kann keine Stunden für einen Kollegen buchen'
);

select throws_ok(
  format($$insert into public.zeiteintrag (projekt_id, profile_id, datum, stunden, taetigkeit)
           values (%L, %L, current_date - 20, 5, 'Zu alt')$$, :projekt_nord, :mo_nord1),
  '42501', null,
  'Nachbuchen endet nach 14 Tagen'
);

select throws_ok(
  format($$insert into public.zeiteintrag (projekt_id, profile_id, datum, stunden, taetigkeit)
           values (%L, %L, current_date, 5, 'Fremde Baustelle')$$, :projekt_sued, :mo_nord1),
  '42501', null,
  'Monteur kann nicht auf die Baustelle eines anderen Trupps buchen'
);

select lives_ok(
  $$update public.zeiteintrag set taetigkeit = 'Attika, korrigiert'
     where datum = current_date$$,
  'Eigene erfasste Stunden darf der Monteur korrigieren'
);

select throws_ok(
  $$update public.zeiteintrag set status = 'freigegeben' where datum = current_date$$,
  '42501', null,
  'Monteur kann sich die Stunden nicht selbst freigeben'
);

select throws_ok(
  format($$update public.profile set rolle = 'buero' where id = %L$$, :mo_nord1),
  '42501', null,
  'Monteur kann sich keine andere Rolle geben'
);

-- Vorarbeiter --------------------------------------------------------------------------
select public.tests_als_eigentuemer();
select public.tests_als(:va_nord);

select is(
  (select count(*) from public.zeiteintrag)::int, 4,
  'Vorarbeiter sieht die Stunden seines Trupps'
);

select is(
  (select count(*) from public.zeiteintrag z join public.projekt p on p.id = z.projekt_id
    where p.trupp_id = '00000000-0000-0000-0000-00000000000b')::int, 0,
  'Vorarbeiter sieht den anderen Trupp nicht'
);

-- Büro und anonym ----------------------------------------------------------------------
select public.tests_als_eigentuemer();
select public.tests_als(:buero);

select is(
  (select count(*) from public.zeiteintrag)::int, 5,
  'Büro sieht alle Stunden'
);

select public.tests_als_eigentuemer();
select public.tests_als_anon();

-- Für anon gibt es kein GRANT, deshalb kommt hier nicht "0 Zeilen", sondern eine
-- Zurückweisung. Das ist die stärkere Zusage: ohne Anmeldung ist die Tabelle nicht
-- einmal lesbar, und ein Fehler in einer Policy kann daran nichts ändern.
select throws_ok(
  $$select count(*) from public.zeiteintrag$$,
  '42501', null,
  'Ohne Anmeldung ist die Tabelle nicht lesbar'
);

select public.tests_als_eigentuemer();
select * from finish();

rollback;
