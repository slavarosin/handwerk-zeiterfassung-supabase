# Zeiterfassung mit Wochenfreigabe (Arbeitsprobe, React + Supabase)

Ein lauffähiger Ausschnitt aus einer internen Betriebsplattform: Monteure erfassen Stunden
auf Baustellen, der Vorarbeiter gibt die Woche frei, das Büro rechnet ab. Enthalten ist die
Schicht, auf der so eine Plattform steht oder fällt: Datenmodell, Zugriffsregeln (RLS),
Freigabelogik und eine Edge Function, mit Tests für jede Zusage.

Der Code ist für diese Anfrage geschrieben, nach demselben Muster, das wir in Projekten
verwenden. Er enthält keine Kunden-, Personen- oder Projektdaten: Namen, Nummern und
Baustellen sind erfunden.

## Ausprobieren (eine Minute)

Voraussetzung ist Docker und [Deno](https://deno.com). Ein Supabase-Konto wird nicht
gebraucht, Postgres läuft als Wegwerf-Container:

```bash
bash local/test.sh
```

Das Skript startet Postgres, spielt Migrationen und Beispieldaten ein, prüft 29 Zusagen an
der Datenbank mit pgTAP und 8 an der Edge Function mit `deno test`, und räumt den Container
wieder weg.

Im echten Projekt laufen dieselben Dateien mit `supabase db reset` und `supabase test db`
gegen den lokalen Stack. `local/00-supabase-stub.sql` bildet nur für den Lauf ohne Stack
die Objekte nach, die Supabase sonst mitbringt (`auth.users`, `auth.uid()`, die Rollen
`anon` / `authenticated`).

## Aufbau

```
supabase/migrations/
  20261102120000_schema.sql     Tabellen, Enums, Indizes, Rechte
  20261102120100_rls.sql        Hilfsfunktionen, Policies, Wächter-Trigger
  20261102120200_freigabe.sql   Wochenfreigabe, Rücknahme, Rollenwechsel
supabase/tests/
  01_rls.test.sql               wer sieht was, wer darf was schreiben
  02_freigabe.test.sql          Berechtigung, Zeitfenster, Idempotenz, Rücknahme
supabase/functions/zeiterfassung-freigabe/
  index.ts                      HTTP-Rand: Eingabe prüfen, aufrufen, Fehler übersetzen
  index.test.ts                 Tests ohne Netz und ohne Datenbank
supabase/seed.sql               zwei Trupps, zwei Baustellen, eine abgeschlossene Woche
```

## Worauf es in diesem Ausschnitt ankommt

**Policies fragen Funktionen, keine Unterabfragen.** Eine Policy auf `profile`, die `profile`
liest, läuft in die Rekursion (`42P17`). Jede Regel geht deshalb über eine
`security definer`-Funktion im Schema `app`, das PostgREST nicht veröffentlicht. Das ist
zugleich die schnellere Variante: die Funktionen sind `stable`, der Planer ruft sie je
Anfrage einmal statt je Zeile.

**`set search_path = ''` bei jeder `security definer`-Funktion**, alles voll qualifiziert.
Ohne das entscheidet der `search_path` des Aufrufers, welcher Code mit erhöhten Rechten
läuft.

**GRANT und RLS sind zwei Schlösser an derselben Tür.** Ohne GRANT sieht niemand etwas, ohne
Policy sehen alle alles. Beides steht in der Migration nebeneinander. Was ein Monteur an
sich selbst ändern darf, hängt zusätzlich am Spaltenrecht (`grant update (name)`), und weil
Spaltenrechte für alle angemeldeten Nutzer gleich gelten, läuft der Rollenwechsel über
`public.rolle_setzen()` statt über die Tabelle.

**Statuswechsel laufen nie an der Tabelle.** "Nur vorwärts" lässt sich in einer Policy nicht
ausdrücken, in einem Trigger schon. Der Wächter auf `zeiteintrag` lässt den Statuswechsel
nur zu, wenn eine Freigabefunktion läuft (`set_config('app.freigabe', ...)` für die Dauer
der Transaktion). Auch das Büro kommt nicht daran vorbei, und jede Rücknahme braucht eine
Begründung.

**Die Freigabe ist idempotent.** Der zweite Klick im schlechten Netz auf der Baustelle gibt
`anzahl: 0` zurück und schreibt keine zweite Protokollzeile. Die Entscheidung, was zur Woche
gehört, trifft ein `update ... where status = 'erfasst'` in einer Anweisung, nicht ein
Lesen-dann-Schreiben in zwei.

**Die Edge Function entscheidet nichts und kennt keinen Service-Role-Key.** Sie reicht das
JWT des Anrufers an `public.zeiten_freigeben()` weiter, dadurch gelten RLS und die Prüfungen
der Datenbank unverändert, auch wenn jemand die REST-API direkt anspricht. Ein
Service-Role-Key in einer Funktion, die Client-Anfragen bedient, hebt die Zugriffsschicht
auf. Die Benachrichtigung an den Betrieb läuft erst nach der Freigabe, und ihr Fehler wird
protokolliert statt geworfen: die Stunden sind frei, auch wenn der Webhook schläft.

**Fachsprache im Code.** Tabellen und Tests heißen wie im Betrieb (`trupp`, `vorarbeiter`,
`zeiteintrag`, `freigabe_protokoll`). Ein Test, der "Monteur sieht die Stunden seines
Kollegen nicht" heißt, sagt beim Bruch, welche Zusage verletzt ist, nicht welche Zeile
gefehlt hat.

## Was bewusst fehlt

Materialwirtschaft, Fotos und Dokumente (Storage), Offline-Erfassung auf der Baustelle,
Lohnexport, Benachrichtigungen und das Frontend. Der Ausschnitt soll in zehn Minuten
lesbar sein und zeigen, wie die Grundlage gebaut ist, auf der diese Module dann liegen.

## Zahlen

29 Zusagen an der Datenbank, 8 an der Edge Function, Laufzeit unter einer Minute inklusive
Containerstart.
