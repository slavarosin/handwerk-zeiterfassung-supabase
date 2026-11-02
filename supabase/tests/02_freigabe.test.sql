-- Wochenfreigabe: Berechtigung, Zeitfenster, Idempotenz, Rücknahme.
--
-- Der interessante Teil ist nicht "es funktioniert", sondern "es funktioniert nicht
-- zweimal": ein zweiter Klick darf keine zweite Protokollzeile und keine zweite Freigabe
-- erzeugen.
begin;

create extension if not exists pgtap;

select plan(15);

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

\set gf       '\'00000000-0000-0000-0000-0000000000f1\'::uuid'
\set buero    '\'00000000-0000-0000-0000-0000000000b1\'::uuid'
\set va_nord  '\'00000000-0000-0000-0000-00000000a001\'::uuid'
\set mo_nord1 '\'00000000-0000-0000-0000-00000000a002\'::uuid'
\set va_sued  '\'00000000-0000-0000-0000-00000000b001\'::uuid'
\set trupp_nord '\'00000000-0000-0000-0000-00000000000a\'::uuid'

-- Vorwoche: Montag der abgeschlossenen Woche.
\set vorwoche '(date_trunc(\'week\', current_date)::date - 7)::text'

-- Wer nicht darf ------------------------------------------------------------------------
select public.tests_als(:mo_nord1);

select throws_ok(
  format($$select public.zeiten_freigeben(%L, %L)$$, :trupp_nord, :vorwoche),
  '42501', null,
  'Monteur gibt keine Wochen frei'
);

select public.tests_als_eigentuemer();
select public.tests_als(:va_sued);

select throws_ok(
  format($$select public.zeiten_freigeben(%L, %L)$$, :trupp_nord, :vorwoche),
  '42501', null,
  'Vorarbeiter gibt nur seinen eigenen Trupp frei'
);

-- Freigabe durch den zuständigen Vorarbeiter --------------------------------------------
select public.tests_als_eigentuemer();
select public.tests_als(:va_nord);

select throws_ok(
  format($$select public.zeiten_freigeben(%L, current_date)$$, :trupp_nord),
  '22023', null,
  'Die laufende Woche wird nicht freigegeben'
);

select is(
  (select (public.zeiten_freigeben(:trupp_nord, (date_trunc('week', current_date)::date - 7)) ->> 'anzahl')::int),
  3,
  'Freigabe erfasst die drei Einträge der Vorwoche'
);

select is(
  (select summe_stunden from public.freigabe_protokoll order by id desc limit 1),
  23.50::numeric(8, 2),
  'Das Protokoll hält die Summe der freigegebenen Stunden'
);

select is(
  (select count(*) from public.zeiteintrag
    where status = 'freigegeben' and freigegeben_von = :va_nord)::int,
  3,
  'Die freigegebenen Stunden tragen den Namen des Vorarbeiters'
);

select is(
  (select status::text from public.zeiteintrag where datum = current_date),
  'erfasst',
  'Die laufende Woche bleibt unberührt'
);

select is(
  (select count(*) from public.zeiteintrag z
     join public.trupp_mitglied tm on tm.profile_id = z.profile_id
    where tm.trupp_id = '00000000-0000-0000-0000-00000000000b' and z.status = 'freigegeben')::int,
  0,
  'Der andere Trupp ist nicht mitgelaufen'
);

-- Zweiter Klick -------------------------------------------------------------------------
select is(
  (select (public.zeiten_freigeben(:trupp_nord, (date_trunc('week', current_date)::date - 7)) ->> 'anzahl')::int),
  0,
  'Der zweite Aufruf gibt nichts mehr frei'
);

select is(
  (select count(*) from public.freigabe_protokoll)::int,
  1,
  'Und schreibt keine zweite Protokollzeile'
);

-- Rücknahme ----------------------------------------------------------------------------
select throws_ok(
  $$select public.zeiten_freigabe_aufheben(
      array(select id from public.zeiteintrag where status = 'freigegeben'),
      'Krankmeldung kam nach')$$,
  '42501', null,
  'Der Vorarbeiter nimmt eine Freigabe nicht zurück'
);

select public.tests_als_eigentuemer();
select public.tests_als(:buero);

select throws_ok(
  $$select public.zeiten_freigabe_aufheben(
      array(select id from public.zeiteintrag where status = 'freigegeben'), '')$$,
  '22023', null,
  'Rücknahme ohne Begründung wird abgewiesen'
);

select is(
  (select public.zeiten_freigabe_aufheben(
     array(select id from public.zeiteintrag where status = 'freigegeben'),
     'Krankmeldung kam nach')),
  3,
  'Das Büro nimmt die Freigabe mit Begründung zurück'
);

select is(
  (select count(*) from public.zeiteintrag z
     join public.trupp_mitglied tm on tm.profile_id = z.profile_id
    where tm.trupp_id = :trupp_nord
      and z.status = 'erfasst'
      and z.freigegeben_von is null)::int,
  4,
  'Danach sind alle Stunden des Trupps wieder offen'
);

-- Der direkte Weg bleibt zu, auch für das Büro -----------------------------------------
select throws_ok(
  $$update public.zeiteintrag set status = 'abgerechnet' where datum = current_date$$,
  '42501', null,
  'Auch das Büro ändert den Status nicht an der Tabelle vorbei'
);

select public.tests_als_eigentuemer();
select * from finish();

rollback;
