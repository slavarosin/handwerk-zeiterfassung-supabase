-- Auftragsabwicklung und Zeiterfassung: fachlicher Kern.
--
-- Zuschnitt: ein Betrieb, vier Rollen, Arbeit in Truppen. Monteure erfassen Stunden auf
-- Baustellen, der Vorarbeiter gibt die Woche frei, das Büro rechnet ab. Mehr Module hängen
-- an diesem Kern, deshalb liegen hier nur Tabellen, die alle anderen brauchen.
--
-- Alles, was nicht zur API gehört, liegt im Schema "app": PostgREST veröffentlicht nur
-- "public", und Hilfsfunktionen der Policies haben in der API nichts zu suchen.

create schema if not exists app;

create type public.app_rolle as enum (
  'geschaeftsfuehrung',
  'buero',
  'vorarbeiter',
  'monteur'
);

create type public.projekt_status as enum (
  'geplant',
  'laufend',
  'abgeschlossen',
  'abgerechnet'
);

-- Zeiteinträge wandern nur vorwärts: erfasst -> freigegeben -> abgerechnet.
create type public.zeit_status as enum (
  'erfasst',
  'freigegeben',
  'abgerechnet'
);

create table public.profile (
  id          uuid primary key references auth.users (id) on delete cascade,
  name        text not null check (char_length(btrim(name)) between 2 and 120),
  rolle       public.app_rolle not null default 'monteur',
  aktiv       boolean not null default true,
  erstellt_am timestamptz not null default now()
);

comment on table public.profile is
  'Fachliche Daten zum Login. Die Rolle wird nur über public.rolle_setzen() geändert.';

create table public.trupp (
  id             uuid primary key default gen_random_uuid(),
  name           text not null unique check (char_length(btrim(name)) between 2 and 60),
  vorarbeiter_id uuid references public.profile (id) on delete set null,
  aktiv          boolean not null default true
);

create table public.trupp_mitglied (
  trupp_id   uuid not null references public.trupp (id) on delete cascade,
  profile_id uuid not null references public.profile (id) on delete cascade,
  seit       date not null default current_date,
  primary key (trupp_id, profile_id)
);

create table public.projekt (
  id          uuid primary key default gen_random_uuid(),
  nummer      text not null unique,
  bezeichnung text not null check (char_length(btrim(bezeichnung)) between 3 and 200),
  kunde       text not null,
  trupp_id    uuid references public.trupp (id) on delete set null,
  status      public.projekt_status not null default 'geplant',
  start_datum date,
  end_datum   date,
  erstellt_am timestamptz not null default now(),
  constraint projekt_zeitraum check (end_datum is null or start_datum is null or end_datum >= start_datum)
);

create table public.zeiteintrag (
  id              uuid primary key default gen_random_uuid(),
  projekt_id      uuid not null references public.projekt (id) on delete restrict,
  profile_id      uuid not null references public.profile (id) on delete restrict,
  datum           date not null,
  stunden         numeric(4, 2) not null check (stunden > 0 and stunden <= 14),
  taetigkeit      text not null check (char_length(btrim(taetigkeit)) between 3 and 500),
  status          public.zeit_status not null default 'erfasst',
  freigegeben_von uuid references public.profile (id),
  freigegeben_am  timestamptz,
  erstellt_am     timestamptz not null default now(),
  -- Zwei Monteure buchen dieselbe Tätigkeit am selben Tag auf dieselbe Baustelle: erlaubt.
  -- Derselbe Monteur zweimal: fast immer ein Doppelklick, deshalb hier verboten.
  constraint zeiteintrag_eindeutig unique (projekt_id, profile_id, datum, taetigkeit),
  -- Freigabe ist nur mit Spur gültig: wer und wann, oder gar nicht.
  constraint zeiteintrag_freigabe_vollstaendig check (
    (status = 'erfasst' and freigegeben_von is null and freigegeben_am is null)
    or (status <> 'erfasst' and freigegeben_von is not null and freigegeben_am is not null)
  )
);

-- Freigaben werden protokolliert: die Lohnabrechnung fragt später, wer die Woche gezeichnet hat.
create table public.freigabe_protokoll (
  id               bigint generated always as identity primary key,
  trupp_id         uuid not null references public.trupp (id) on delete restrict,
  woche            date not null,
  anzahl_eintraege integer not null check (anzahl_eintraege > 0),
  summe_stunden    numeric(8, 2) not null check (summe_stunden > 0),
  durch            uuid not null references public.profile (id) on delete restrict,
  am               timestamptz not null default now()
);

-- Indizes nach den drei Abfragen, die die Oberfläche wirklich stellt: meine Woche,
-- die Woche eines Trupps, die Stunden einer Baustelle.
create index zeiteintrag_profile_datum_idx on public.zeiteintrag (profile_id, datum desc);
create index zeiteintrag_projekt_idx on public.zeiteintrag (projekt_id, datum desc);
create index zeiteintrag_offen_idx on public.zeiteintrag (datum) where status = 'erfasst';
create index trupp_mitglied_profile_idx on public.trupp_mitglied (profile_id);
create index projekt_trupp_idx on public.projekt (trupp_id) where status <> 'abgerechnet';

-- Rechte und RLS sind zwei Schlösser an derselben Tür: ohne GRANT sieht niemand etwas,
-- ohne Policy sehen alle alles. Beides steht hier bewusst nebeneinander.
grant usage on schema app to authenticated, service_role;

grant select on public.profile, public.trupp, public.trupp_mitglied, public.projekt,
               public.zeiteintrag, public.freigabe_protokoll to authenticated;
grant insert, update, delete on public.zeiteintrag to authenticated;
grant insert, update, delete on public.projekt to authenticated;
grant insert, update, delete on public.trupp, public.trupp_mitglied to authenticated;
-- Den Namen darf jeder an sich selbst ändern, die Rolle niemand über die Tabelle.
grant update (name) on public.profile to authenticated;
grant insert, delete on public.profile to authenticated;
