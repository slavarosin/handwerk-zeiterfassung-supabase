// Tests der Edge Function ohne Netz und ohne Datenbank: fetch wird eingesetzt, nicht
// gemockt im Nachhinein. Dadurch prüfen die Tests auch das, was man sonst erst in
// Produktion merkt - welche Kopfzeilen die Funktion weitergibt und welche nicht.
import { assert, assertEquals, assertFalse } from "@std/assert";
import { erzeugeHandler, pruefeEingabe } from "./index.ts";

const URL_BASIS = "https://beispiel.supabase.co";
const ANON = "anon-key-nur-fuer-den-test";
const TRUPP = "11111111-1111-1111-1111-111111111111";
const JWT = "Bearer jwt-des-vorarbeiters";

type Aufruf = { url: string; headers: Record<string, string>; body: unknown };

/** fetch-Ersatz, der die Antwort der Datenbank vorgibt und den Aufruf mitschreibt. */
function fetchMit(
  antwort: { status: number; body: unknown },
  aufrufe: Aufruf[] = [],
): typeof globalThis.fetch {
  return ((url: string | URL | Request, init?: RequestInit) => {
    const headers = Object.fromEntries(new Headers(init?.headers).entries());
    aufrufe.push({ url: String(url), headers, body: JSON.parse(String(init?.body ?? "null")) });
    return Promise.resolve(
      new Response(JSON.stringify(antwort.body), {
        status: antwort.status,
        headers: { "content-type": "application/json" },
      }),
    );
  }) as typeof globalThis.fetch;
}

function anfrage(body: unknown, auth: string | null = JWT, method = "POST"): Request {
  const headers = new Headers({ "content-type": "application/json" });
  if (auth) headers.set("authorization", auth);
  return new Request("https://edge.test/zeiterfassung-freigabe", {
    method,
    headers,
    body: method === "POST" ? JSON.stringify(body) : undefined,
  });
}

const ERFOLG = { trupp: TRUPP, woche: "2026-10-26", anzahl: 3, summe_stunden: 23.5 };

function handler(
  antwort: { status: number; body: unknown } = { status: 200, body: ERFOLG },
  extra: Partial<Parameters<typeof erzeugeHandler>[0]> = {},
  aufrufe: Aufruf[] = [],
) {
  return erzeugeHandler({
    supabaseUrl: URL_BASIS,
    anonKey: ANON,
    fetch: fetchMit(antwort, aufrufe),
    protokoll: () => {},
    ...extra,
  });
}

Deno.test("Eingabeprüfung erkennt fehlende und unmögliche Werte", () => {
  assertEquals(pruefeEingabe({ trupp: TRUPP, woche: "2026-10-26" }), {
    trupp: TRUPP,
    woche: "2026-10-26",
  });
  assert(Array.isArray(pruefeEingabe({ woche: "2026-10-26" })), "Trupp fehlt");
  assert(Array.isArray(pruefeEingabe({ trupp: "kein-uuid", woche: "2026-10-26" })));
  assert(Array.isArray(pruefeEingabe({ trupp: TRUPP, woche: "26.10.2026" })));
  // Muster passt, Tag existiert nicht.
  assert(Array.isArray(pruefeEingabe({ trupp: TRUPP, woche: "2026-02-31" })));
});

Deno.test("GET wird abgewiesen, OPTIONS beantwortet den Preflight", async () => {
  const h = handler();
  assertEquals((await h(anfrage(null, JWT, "GET"))).status, 405);

  const pre = await h(anfrage(null, null, "OPTIONS"));
  assertEquals(pre.status, 204);
  assertEquals(pre.headers.get("Access-Control-Allow-Methods"), "POST, OPTIONS");
});

Deno.test("ohne Anmeldung kein Aufruf der Datenbank", async () => {
  const aufrufe: Aufruf[] = [];
  const res = await handler({ status: 200, body: ERFOLG }, {}, aufrufe)(
    anfrage({ trupp: TRUPP, woche: "2026-10-26" }, null),
  );
  assertEquals(res.status, 401);
  assertEquals(aufrufe.length, 0, "Die Datenbank wird erst nach der Anmeldung gefragt");
});

Deno.test("unvollständige Eingabe nennt das Feld", async () => {
  const res = await handler()(anfrage({ woche: "2026-10-26" }));
  assertEquals(res.status, 400);
  const body = await res.json();
  assert(body.felder.some((f: string) => f.startsWith("trupp:")), JSON.stringify(body));
});

Deno.test("das JWT des Anrufers geht weiter, der Service-Role-Key nicht", async () => {
  const aufrufe: Aufruf[] = [];
  const res = await handler({ status: 200, body: ERFOLG }, {}, aufrufe)(
    anfrage({ trupp: TRUPP, woche: "2026-10-26" }),
  );
  assertEquals(res.status, 200);
  assertEquals(await res.json(), ERFOLG);
  assertEquals(aufrufe.length, 1);
  assertEquals(aufrufe[0].url, `${URL_BASIS}/rest/v1/rpc/zeiten_freigeben`);
  assertEquals(aufrufe[0].headers["authorization"], JWT);
  assertEquals(aufrufe[0].headers["apikey"], ANON);
  assertEquals(aufrufe[0].body, { p_trupp: TRUPP, p_woche: "2026-10-26" });
  assertFalse(
    JSON.stringify(aufrufe[0].headers).includes("service_role"),
    "Eine Client-Anfrage darf nie mit Service-Role-Rechten laufen",
  );
});

Deno.test("Datenbankfehler werden zu sprechenden HTTP-Codes", async () => {
  const faelle: Array<[string, number]> = [
    ["42501", 403], // Vorarbeiter eines anderen Trupps
    ["28000", 401], // Token abgelaufen
    ["22023", 409], // Woche läuft noch
    ["XX000", 500], // unbekannt: 500 und ins Protokoll
  ];
  for (const [code, erwartet] of faelle) {
    const res = await handler({ status: 400, body: { code, message: `Fehler ${code}` } })(
      anfrage({ trupp: TRUPP, woche: "2026-10-26" }),
    );
    assertEquals(res.status, erwartet, `SQLSTATE ${code}`);
    assertEquals((await res.json()).code, code);
  }
});

Deno.test("Benachrichtigung läuft nach der Freigabe und kann sie nicht umwerfen", async () => {
  const gesendet: string[] = [];
  const ok = await handler({ status: 200, body: ERFOLG }, {
    benachrichtigen: (t: string) => {
      gesendet.push(t);
      return Promise.resolve();
    },
  })(anfrage({ trupp: TRUPP, woche: "2026-10-26" }));
  assertEquals(ok.status, 200);
  assertEquals(gesendet.length, 1);
  assert(gesendet[0].includes("23.5"), gesendet[0]);

  // Webhook tot: die Freigabe bleibt trotzdem erfolgreich.
  const trotzdem = await handler({ status: 200, body: ERFOLG }, {
    benachrichtigen: () => Promise.reject(new Error("Webhook 500")),
  })(anfrage({ trupp: TRUPP, woche: "2026-10-26" }));
  assertEquals(trotzdem.status, 200);
  assertEquals(await trotzdem.json(), ERFOLG);
});

Deno.test("nichts freigegeben, nichts gemeldet", async () => {
  const gesendet: string[] = [];
  const res = await handler({ status: 200, body: { ...ERFOLG, anzahl: 0, summe_stunden: 0 } }, {
    benachrichtigen: (t: string) => {
      gesendet.push(t);
      return Promise.resolve();
    },
  })(anfrage({ trupp: TRUPP, woche: "2026-10-26" }));
  assertEquals(res.status, 200);
  assertEquals(gesendet.length, 0, "Der zweite Klick meldet nicht noch einmal");
});
