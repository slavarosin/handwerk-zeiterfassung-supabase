#!/usr/bin/env bash
# Ein Befehl, der alles prüft: Schema, Policies, Freigabefunktion, Edge Function.
#
# Gegen ein Wegwerf-Postgres im Container, damit nichts installiert werden muss außer
# Docker und Deno. Im Projekt selbst läuft dasselbe mit "supabase db reset" und
# "supabase test db" gegen den lokalen Stack; die Testdateien sind identisch.
set -euo pipefail

IMAGE=${IMAGE:-supabase/postgres:15.8.1.060}
NAME=${NAME:-handwerk-test-db}
PORT=${PORT:-55433}
DB=handwerk
export PGPASSWORD=postgres

cd "$(dirname "$0")/.."

aufraeumen() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap aufraeumen EXIT
aufraeumen

echo "== Postgres starten ($IMAGE)"
docker run -d --name "$NAME" -e POSTGRES_PASSWORD=postgres -p "$PORT":5432 "$IMAGE" >/dev/null

for _ in $(seq 1 60); do
  if psql -h 127.0.0.1 -p "$PORT" -U postgres -c 'select 1' >/dev/null 2>&1; then break; fi
  sleep 1
done

psql -h 127.0.0.1 -p "$PORT" -U postgres -q \
  -c "drop database if exists $DB" -c "create database $DB"

lauf() {
  psql -h 127.0.0.1 -p "$PORT" -U postgres -d "$DB" -v ON_ERROR_STOP=1 -q -f "$1"
}

echo "== Supabase-Nachbildung, Migrationen, Beispieldaten"
lauf local/00-supabase-stub.sql
for f in supabase/migrations/*.sql; do printf '   %s\n' "$(basename "$f")"; lauf "$f"; done
lauf supabase/seed.sql

echo "== Datenbanktests (pgTAP)"
fehler=0
for f in supabase/tests/*.test.sql; do
  echo "   $(basename "$f")"
  ausgabe=$(psql -h 127.0.0.1 -p "$PORT" -U postgres -d "$DB" -f "$f" 2>&1)
  echo "$ausgabe" | grep -E '^ ?(ok|not ok|# Looks)' | sed 's/^ /     /'
  if echo "$ausgabe" | grep -qE '^ *not ok|ERROR:'; then fehler=1; fi
done

echo "== Edge Function (deno test)"
(cd supabase/functions/zeiterfassung-freigabe && deno test --quiet index.test.ts) || fehler=1

if [ "$fehler" -ne 0 ]; then
  echo "FEHLGESCHLAGEN"
  exit 1
fi
echo "ALLES GRÜN"
