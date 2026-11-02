-- Beispieldaten für den lokalen Lauf und die Tests.
--
-- Zwei Trupps, damit sichtbar wird, was der Vorarbeiter von Trupp Nord über Trupp Süd NICHT
-- sieht. Alle Daten sind relativ zu current_date, deshalb laufen die Tests an jedem Tag.
-- Feste UUIDs, damit die Tests ohne Suchlauf wissen, wer wer ist.

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000f1', 'gf@beispielbetrieb.test'),
  ('00000000-0000-0000-0000-0000000000b1', 'buero@beispielbetrieb.test'),
  ('00000000-0000-0000-0000-00000000a001', 'vorarbeiter.nord@beispielbetrieb.test'),
  ('00000000-0000-0000-0000-00000000a002', 'monteur.nord1@beispielbetrieb.test'),
  ('00000000-0000-0000-0000-00000000a003', 'monteur.nord2@beispielbetrieb.test'),
  ('00000000-0000-0000-0000-00000000b001', 'vorarbeiter.sued@beispielbetrieb.test'),
  ('00000000-0000-0000-0000-00000000b002', 'monteur.sued1@beispielbetrieb.test');

insert into public.profile (id, name, rolle) values
  ('00000000-0000-0000-0000-0000000000f1', 'G. Fuehrung', 'geschaeftsfuehrung'),
  ('00000000-0000-0000-0000-0000000000b1', 'B. Buero', 'buero'),
  ('00000000-0000-0000-0000-00000000a001', 'V. Nord', 'vorarbeiter'),
  ('00000000-0000-0000-0000-00000000a002', 'M. Nord eins', 'monteur'),
  ('00000000-0000-0000-0000-00000000a003', 'M. Nord zwei', 'monteur'),
  ('00000000-0000-0000-0000-00000000b001', 'V. Sued', 'vorarbeiter'),
  ('00000000-0000-0000-0000-00000000b002', 'M. Sued eins', 'monteur');

insert into public.trupp (id, name, vorarbeiter_id) values
  ('00000000-0000-0000-0000-00000000000a', 'Trupp Nord', '00000000-0000-0000-0000-00000000a001'),
  ('00000000-0000-0000-0000-00000000000b', 'Trupp Sued', '00000000-0000-0000-0000-00000000b001');

insert into public.trupp_mitglied (trupp_id, profile_id) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000a001'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000a002'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000a003'),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-00000000b001'),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-00000000b002');

insert into public.projekt (id, nummer, bezeichnung, kunde, trupp_id, status, start_datum) values
  ('00000000-0000-0000-0000-0000000000a9', 'P-2026-014', 'Flachdachsanierung Halle 2', 'Kunde Nord GmbH',
   '00000000-0000-0000-0000-00000000000a', 'laufend', current_date - 21),
  ('00000000-0000-0000-0000-0000000000b9', 'P-2026-015', 'Dachstuhl Neubau Reihenhaus', 'Kunde Sued KG',
   '00000000-0000-0000-0000-00000000000b', 'laufend', current_date - 14);

-- Abgeschlossene Vorwoche: die ist freigabefähig.
insert into public.zeiteintrag (projekt_id, profile_id, datum, stunden, taetigkeit) values
  ('00000000-0000-0000-0000-0000000000a9', '00000000-0000-0000-0000-00000000a002',
   date_trunc('week', current_date)::date - 7, 8.00, 'Abdichtung Bahn 1'),
  ('00000000-0000-0000-0000-0000000000a9', '00000000-0000-0000-0000-00000000a002',
   date_trunc('week', current_date)::date - 6, 7.50, 'Abdichtung Bahn 2'),
  ('00000000-0000-0000-0000-0000000000a9', '00000000-0000-0000-0000-00000000a003',
   date_trunc('week', current_date)::date - 7, 8.00, 'Dampfsperre'),
  ('00000000-0000-0000-0000-0000000000b9', '00000000-0000-0000-0000-00000000b002',
   date_trunc('week', current_date)::date - 7, 6.00, 'Lattung');

-- Laufende Woche: die darf keine Freigabe anfassen.
insert into public.zeiteintrag (projekt_id, profile_id, datum, stunden, taetigkeit) values
  ('00000000-0000-0000-0000-0000000000a9', '00000000-0000-0000-0000-00000000a002',
   current_date, 4.00, 'Attika');
