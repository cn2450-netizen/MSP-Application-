import { fluxRows } from "./influx";

// Automatic-start Windows services for ONE computer, from the win_services measurement. The caller has already checked
// canSee() on the slug; slug and host are validated again here because they go into a query.

export type Service = { name: string; display: string; running: boolean; state: number };
export type Services = { rows: Service[]; running: number; total: number; error: string | null };

const SLUG = /^[a-z0-9][a-z0-9-]{1,30}$/;
const HOST = /^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$/;
const EMPTY = (error: string | null): Services => ({ rows: [], running: 0, total: 0, error });

export async function loadServices(slug: string, host: string): Promise<Services> {
  if (!SLUG.test(slug) || !HOST.test(host)) return EMPTY("invalid computer");
  try {
    // state 4 = running; startup_mode 2 = automatic
    const rows = await fluxRows(`import "strings"
from(bucket: "cust_${slug}") |> range(start: -15m)
  |> filter(fn: (r) => r._measurement == "win_services" and strings.toLower(v: r.host) == "${host}" and (r._field == "state" or r._field == "startup_mode"))
  |> last() |> group()
  |> pivot(rowKey: ["service_name", "display_name"], columnKey: ["_field"], valueColumn: "_value")
  |> filter(fn: (r) => r.startup_mode == 2)
  |> keep(columns: ["service_name", "display_name", "state"])`);
    const list: Service[] = rows.map((r) => ({ name: r.service_name || "?", display: r.display_name || r.service_name || "?", state: Number(r.state), running: Number(r.state) === 4 }));
    // stopped ones first, then by name
    list.sort((a, b) => Number(a.running) - Number(b.running) || a.display.localeCompare(b.display));
    return { rows: list, running: list.filter((s) => s.running).length, total: list.length, error: null };
  } catch {
    return EMPTY("Services could not be read right now.");
  }
}
