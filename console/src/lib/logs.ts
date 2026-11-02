// Windows event log warnings and errors for ONE computer, read from Loki. Loki keeps each company as its own tenant, and the
// tenant is set here from the slug the caller already checked with canSee(), never from anything the browser sent.

export type LogEntry = { t: number; level: "Critical" | "Error" | "Warning" | "Other"; channel: string; source: string; eventId: string; message: string };
export type Logs = { rows: LogEntry[]; truncated: boolean; error: string | null };

const URL = process.env.LOKI_URL || "http://loki:3100";
const SLUG = /^[a-z0-9][a-z0-9-]{1,30}$/;
const HOST = /^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$/;
export const LOG_DAYS = 14;
const LIMIT = 2000;

const LEVELS: Record<string, LogEntry["level"]> = { "1": "Critical", "2": "Error", "3": "Warning" };

/** The readable text out of the key="value" line the agent sends. */
function messageOf(line: string): string {
  const m = line.match(/(?:^|\s)Message="((?:[^"\\]|\\.)*)"/);
  const text = m ? m[1].replace(/\\(["\\])/g, "$1").replace(/\\r\\n|\\n|\\r|\\t/g, " ") : line;
  return text.replace(/\s+/g, " ").trim();
}

export async function loadLogs(slug: string, host: string): Promise<Logs> {
  return load(slug, host, `Channel!="Security"`);
}

async function load(slug: string, host: string, extra: string): Promise<Logs> {
  if (!SLUG.test(slug) || !HOST.test(host)) return { rows: [], truncated: false, error: "invalid computer" };
  try {
    const q = new URLSearchParams({ query: `{host=~"(?i)^${host}$",${extra}}`, limit: String(LIMIT), direction: "backward", since: `${LOG_DAYS}d` });
    const res = await fetch(`${URL}/loki/api/v1/query_range?${q}`, { headers: { "X-Scope-OrgID": slug }, cache: "no-store", signal: AbortSignal.timeout(8000) });
    if (!res.ok) throw new Error(`Loki answered ${res.status}`);
    const body = await res.json() as { data?: { result?: { stream: Record<string, string>; values: [string, string][] }[] } };
    const rows: LogEntry[] = [];
    for (const s of body.data?.result ?? []) for (const [ns, line] of s.values) {
      rows.push({ t: Number(BigInt(ns) / 1_000_000n), level: LEVELS[s.stream.Level] ?? "Other", channel: s.stream.Channel || "", source: (s.stream.Source || "").replace(/^Microsoft-Windows-/, ""), eventId: s.stream.EventID || "", message: messageOf(line) });
    }
    rows.sort((a, b) => b.t - a.t);
    return { rows, truncated: rows.length >= LIMIT, error: null };
  } catch {
    return { rows: [], truncated: false, error: "Event logs could not be read right now." };
  }
}
