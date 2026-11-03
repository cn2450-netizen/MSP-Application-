import { fluxRows } from "./influx";

// Automatic-start Windows services for ONE computer, from the win_services measurement. The caller has already checked
// canSee() on the slug; slug and host are validated again here because they go into a query.

export type Service = { name: string; display: string; running: boolean; state: number; ignored: boolean };
export type Services = { rows: Service[]; running: number; total: number; error: string | null };

const SLUG = /^[a-z0-9][a-z0-9-]{1,30}$/;
const HOST = /^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$/;
const EMPTY = (error: string | null): Services => ({ rows: [], running: 0, total: 0, error });

/** The company's ignore list (lower-case service names): services that are not expected to keep running. */
export async function loadIgnored(slug: string): Promise<Set<string>> {
  const out = new Set<string>();
  if (!SLUG.test(slug)) return out;
  try {
    const { q } = await import("./db");
    for (const r of await q<{ service_name: string }>(`SELECT service_name FROM service_ignore WHERE customer_slug = $1`, [slug])) out.add(r.service_name.toLowerCase());
  } catch { /* the table arrives with the next portal start */ }
  return out;
}

export async function loadServices(slug: string, host: string): Promise<Services> {
  if (!SLUG.test(slug) || !HOST.test(host)) return EMPTY("invalid computer");
  try {
    const ignored = await loadIgnored(slug);
    // state 4 = running; startup_mode 2 = automatic
    const rows = await fluxRows(`import "strings"
from(bucket: "cust_${slug}") |> range(start: -15m)
  |> filter(fn: (r) => r._measurement == "win_services" and strings.toLower(v: r.host) == "${host}" and (r._field == "state" or r._field == "startup_mode"))
  |> last() |> group()
  |> pivot(rowKey: ["service_name", "display_name"], columnKey: ["_field"], valueColumn: "_value")
  |> filter(fn: (r) => r.startup_mode == 2)
  |> keep(columns: ["service_name", "display_name", "state"])`);
    const list: Service[] = rows.map((r) => ({ name: r.service_name || "?", display: r.display_name || r.service_name || "?", state: Number(r.state), running: Number(r.state) === 4, ignored: ignored.has((r.service_name || "").toLowerCase()) }));
    // stopped ones first, then by name; ignored ones last (shown, but not counted)
    list.sort((a, b) => Number(a.ignored) - Number(b.ignored) || Number(a.running) - Number(b.running) || a.display.localeCompare(b.display));
    const counted = list.filter((s) => !s.ignored);
    return { rows: list, running: counted.filter((s) => s.running).length, total: counted.length, error: null };
  } catch {
    return EMPTY("Services could not be read right now.");
  }
}

/** Services that are never restarted from the console: the monitoring agent's own service. Everything else can be. */
const NEVER_RESTART = new Set(["mspagent", "msp monitoring agent"]);       // its service name and its display name
/** Names the restart can carry safely onto a command line; anything stranger simply gets no button. */
const RESTARTABLE = /^[A-Za-z0-9 ._()$#+/:@-]{1,120}$/;
export const canRestart = (name: string) => RESTARTABLE.test(name) && !NEVER_RESTART.has(name.toLowerCase());

export type Restart = { status: "pending" | "running" | "done" | "failed" | "cancelled"; message: string; at: string };

/** The newest restart request for each service on this computer in the last day, keyed by service name. */
export async function loadRestarts(slug: string, host: string): Promise<Map<string, Restart>> {
  const out = new Map<string, Restart>();
  if (!SLUG.test(slug) || !HOST.test(host)) return out;
  try {
    const { q } = await import("./db");
    const rows = await q<{ service_name: string; status: Restart["status"]; message: string | null; at: string }>(
      `SELECT DISTINCT ON (service_name) service_name, status, message, COALESCE(finished_at, requested_at) AS at FROM service_restart
        WHERE customer_slug = $1 AND host = $2 AND requested_at > now() - interval '1 day' ORDER BY service_name, requested_at DESC`, [slug, host]);
    for (const r of rows) out.set(r.service_name, { status: r.status, message: r.message ?? "", at: r.at });
  } catch { /* the table arrives with the next portal start */ }
  return out;
}
