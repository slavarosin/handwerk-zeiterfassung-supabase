-- Wochenfreigabe.
--
-- Warum als Datenbankfunktion und nicht in der Edge Function: die Regel "nur eigener Trupp,
-- nur abgeschlossene Woche, nur erfasste Stunden" muss auch dann halten, wenn jemand die
-- API direkt anspricht. In der Datenbank gilt sie für jeden Weg, im Frontend oder in einer
-- Edge Function gilt sie nur für den, der sie benutzt.
--
-- Die Funktion ist idempotent: der zweite Aufruf findet nichts mehr und gibt anzahl 0
-- zurück. Ein Doppelklick im schlechten Netz darf keine zweite Protokollzeile schreiben.

create or replace function public.zeiten_freigeben(p_trupp uuid, p_woche date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_rolle  public.app_rolle;
  v_montag date := date_trunc('week', p_woche)::date;
  v_anzahl integer;
  v_summe  numeric(8, 2);
begin
  if v_uid is null then
    raise exception 'Nicht angemeldet' using errcode = '28000';
  end if;

  v_rolle := app.rolle();
  if v_rolle is null then
    raise exception 'Kein aktives Profil zu diesem Login' using errcode = '28000';
  end if;

  if v_rolle = 'vorarbeiter' then
    if not app.ist_vorarbeiter_von(p_trupp) then
      raise exception 'Kein Zugriff auf diesen Trupp' using errcode = '42501';
    end if;
  elsif v_rolle not in ('buero', 'geschaeftsfuehrung') then
    raise exception 'Keine Freigabeberechtigung' using errcode = '42501';
  end if;

  -- Eine laufende Woche wird nicht freigegeben: sonst fehlen Donnerstag und Freitag.
  if v_montag + 6 >= current_date then
    raise exception 'Die Woche ab % ist noch nicht abgeschlossen', v_montag
      using errcode = '22023';
  end if;

  perform set_config('app.freigabe', 'laeuft', true);

  with aktualisiert as (
    update public.zeiteintrag z
       set status          = 'freigegeben',
           freigegeben_von = v_uid,
           freigegeben_am  = now()
     where z.status = 'erfasst'
       and z.datum between v_montag and v_montag + 6
       and exists (
         select 1
           from public.trupp_mitglied tm
          where tm.profile_id = z.profile_id
            and tm.trupp_id = p_trupp
       )
    returning z.stunden
  )
  select count(*)::integer, coalesce(sum(stunden), 0)::numeric(8, 2)
    into v_anzahl, v_summe
    from aktualisiert;

  perform set_config('app.freigabe', '', true);

  if v_anzahl > 0 then
    insert into public.freigabe_protokoll (trupp_id, woche, anzahl_eintraege, summe_stunden, durch)
    values (p_trupp, v_montag, v_anzahl, v_summe, v_uid);
  end if;

  return jsonb_build_object(
    'trupp', p_trupp,
    'woche', v_montag,
    'anzahl', v_anzahl,
    'summe_stunden', v_summe
  );
end
$$;

comment on function public.zeiten_freigeben(uuid, date) is
  'Gibt die erfassten Stunden eines Trupps für die Woche von p_woche frei. Idempotent.';

-- Rücknahme: das Büro korrigiert, die Abrechnung bleibt unantastbar.
create or replace function public.zeiten_freigabe_aufheben(p_ids uuid[], p_grund text)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_anzahl integer;
begin
  if v_uid is null then
    raise exception 'Nicht angemeldet' using errcode = '28000';
  end if;

  if not app.ist_buero() then
    raise exception 'Nur das Büro nimmt Freigaben zurück' using errcode = '42501';
  end if;

  if p_grund is null or char_length(btrim(p_grund)) < 5 then
    raise exception 'Begründung fehlt' using errcode = '22023';
  end if;

  perform set_config('app.freigabe', 'laeuft', true);

  with zurueck as (
    update public.zeiteintrag z
       set status          = 'erfasst',
           freigegeben_von = null,
           freigegeben_am  = null
     where z.id = any (p_ids)
       and z.status = 'freigegeben'
    returning z.id
  )
  select count(*)::integer into v_anzahl from zurueck;

  perform set_config('app.freigabe', '', true);

  return v_anzahl;
end
$$;

-- Rollenwechsel: nicht über die Tabelle, weil Spaltenrechte für alle angemeldeten Nutzer
-- gleich gelten und "Büro darf, Monteur nicht" sich darin nicht ausdrücken lässt.
create or replace function public.rolle_setzen(p_profile uuid, p_rolle public.app_rolle)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.rolle() <> 'geschaeftsfuehrung' then
    raise exception 'Rollen ändert nur die Geschäftsführung' using errcode = '42501';
  end if;

  update public.profile p set rolle = p_rolle where p.id = p_profile;

  if not found then
    raise exception 'Profil % existiert nicht', p_profile using errcode = 'P0002';
  end if;
end
$$;

revoke all on function public.zeiten_freigeben(uuid, date) from public;
revoke all on function public.zeiten_freigabe_aufheben(uuid[], text) from public;
revoke all on function public.rolle_setzen(uuid, public.app_rolle) from public;

grant execute on function public.zeiten_freigeben(uuid, date) to authenticated;
grant execute on function public.zeiten_freigabe_aufheben(uuid[], text) to authenticated;
grant execute on function public.rolle_setzen(uuid, public.app_rolle) to authenticated;
