// Edge Function "zeiterfassung-freigabe".
//
// Die Funktion entscheidet nichts. Sie nimmt die Anfrage an, prüft die Form der Eingabe,
// ruft public.zeiten_freigeben() auf und übersetzt Datenbankfehler in HTTP-Codes. Die
// fachlichen Regeln (eigener Trupp, abgeschlossene Woche, nur erfasste Stunden) stehen in
// der Datenbank, weil sie auch dann gelten müssen, wenn jemand die REST-API direkt anspricht.
//
// Zwei Entscheidungen, die hier wichtig sind:
//
// 1. KEIN Service-Role-Key. Die Funktion reicht das JWT des Anrufers weiter, dadurch gelten
//    RLS und die Prüfungen der Datenbankfunktion unverändert. Ein Service-Role-Key in einer
//    Edge Function, die eine Client-Anfrage bedient, hebt die ganze Zugriffsschicht auf.
// 2. Die Benachrichtigung ins Baustellen-Chat darf die Freigabe nicht gefährden: sie läuft
//    NACH dem erfolgreichen Aufruf, und ihr Fehler wird protokolliert, nicht geworfen. Die
//    Stunden sind freigegeben, auch wenn der Webhook schläft.

export type Abhaengigkeiten = {
  supabaseUrl: string;
  anonKey: string;
  fetch: typeof globalThis.fetch;
  /** Optionaler Hinweis an den Betrieb, z. B. Teams oder Slack. */
  benachrichtigen?: (text: string) => Promise<void>;
  protokoll?: (nachricht: string, daten?: unknown) => void;
};

export type Freigabe = {
  trupp: string;
  woche: string;
  anzahl: number;
  summe_stunden: number;
};

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATUM = /^\d{4}-\d{2}-\d{2}$/;

// PostgREST gibt den SQLSTATE der Datenbank weiter. Die Zuordnung steht hier an einer
// Stelle, damit eine neue Regel in der Datenbank nur eine Zeile hier braucht.
const STATUS_ZU_SQLSTATE: Record<string, number> = {
  "28000": 401, // nicht angemeldet
  "42501": 403, // angemeldet, aber nicht berechtigt
  "22023": 409, // Woche noch nicht abgeschlossen
  "23505": 409, // Freigabe lief parallel schon durch
};

function antwort(daten: unknown, status: number): Response {
  return new Response(JSON.stringify(daten), {
    status,
    headers: { ...CORS, "content-type": "application/json; charset=utf-8" },
  });
}

export function pruefeEingabe(roh: unknown): { trupp: string; woche: string } | string[] {
  const fehler: string[] = [];
  const body = (roh ?? {}) as Record<string, unknown>;

  const trupp = typeof body.trupp === "string" ? body.trupp.trim() : "";
  if (!UUID.test(trupp)) fehler.push("trupp: UUID des Trupps fehlt oder ist ungültig");

  const woche = typeof body.woche === "string" ? body.woche.trim() : "";
  if (!DATUM.test(woche)) {
    fehler.push("woche: Datum im Format JJJJ-MM-TT erwartet");
  } else {
    // "2026-02-31" passt auf das Muster, ist aber kein Tag.
    const d = new Date(`${woche}T00:00:00Z`);
    if (Number.isNaN(d.getTime()) || d.toISOString().slice(0, 10) !== woche) {
      fehler.push("woche: kein gültiger Tag");
    }
  }

  return fehler.length > 0 ? fehler : { trupp, woche };
}

export function erzeugeHandler(deps: Abhaengigkeiten): (req: Request) => Promise<Response> {
  const protokoll = deps.protokoll ?? ((m: string, d?: unknown) => console.error(m, d ?? ""));

  return async function handler(req: Request): Promise<Response> {
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
    if (req.method !== "POST") return antwort({ fehler: "Nur POST" }, 405);

    const auth = req.headers.get("authorization") ?? "";
    if (!auth.toLowerCase().startsWith("bearer ")) {
      return antwort({ fehler: "Anmeldung fehlt" }, 401);
    }

    let roh: unknown;
    try {
      roh = await req.json();
    } catch {
      return antwort({ fehler: "Ungültiges JSON" }, 400);
    }

    const geprueft = pruefeEingabe(roh);
    if (Array.isArray(geprueft)) return antwort({ fehler: "Eingabe unvollständig", felder: geprueft }, 400);

    const res = await deps.fetch(`${deps.supabaseUrl}/rest/v1/rpc/zeiten_freigeben`, {
      method: "POST",
      headers: {
        apikey: deps.anonKey,
        authorization: auth,
        "content-type": "application/json",
      },
      body: JSON.stringify({ p_trupp: geprueft.trupp, p_woche: geprueft.woche }),
    });

    if (!res.ok) {
      const fehler = await res.json().catch(() => ({}));
      const status = STATUS_ZU_SQLSTATE[fehler?.code] ?? (res.status === 401 ? 401 : 500);
      if (status === 500) protokoll("Freigabe fehlgeschlagen", fehler);
      return antwort(
        { fehler: fehler?.message ?? "Freigabe fehlgeschlagen", code: fehler?.code ?? null },
        status,
      );
    }

    const freigabe = (await res.json()) as Freigabe;

    if (freigabe.anzahl > 0 && deps.benachrichtigen) {
      try {
        await deps.benachrichtigen(
          `Woche ${freigabe.woche}: ${freigabe.anzahl} Einträge, ` +
            `${freigabe.summe_stunden} Stunden freigegeben.`,
        );
      } catch (e) {
        // Die Stunden sind freigegeben. Ein stummer Webhook ist ein Betriebsproblem,
        // kein Grund, dem Vorarbeiter einen Fehler zu zeigen.
        protokoll("Benachrichtigung nicht zugestellt", e);
      }
    }

    return antwort(freigabe, 200);
  };
}

// Nur beim echten Start, nicht im Test.
if (import.meta.main) {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!supabaseUrl || !anonKey) throw new Error("SUPABASE_URL und SUPABASE_ANON_KEY fehlen");

  const webhook = Deno.env.get("FREIGABE_WEBHOOK_URL");
  Deno.serve(erzeugeHandler({
    supabaseUrl,
    anonKey,
    fetch: globalThis.fetch,
    benachrichtigen: webhook
      ? async (text: string) => {
        const r = await fetch(webhook, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ text }),
        });
        if (!r.ok) throw new Error(`Webhook ${r.status}`);
      }
      : undefined,
  }));
}
