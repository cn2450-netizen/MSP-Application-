import { fluxRows } from "./influx";

// Performance history for ONE computer, read straight from the customer's InfluxDB bucket. The caller has already
// checked canSee() on the slug and validated the host name; both are re-checked here because they are put in a query.

export const RANGES = {
  "1h": { label: "1 hour", start: "-1h", every: "1m", ms: 3_600_000 },
  "6h": { label: "6 hours", start: "-6h", every: "5m", ms: 6 * 3_600_000 },
  "24h": { label: "24 hours", start: "-24h", every: "15m", ms: 24 * 3_600_000 },
  "7d": { label: "7 days", start: "-7d", every: "1h", ms: 7 * 86_400_000 },
} as const;
export type RangeKey = keyof typeof RANGES;
export const rangeKey = (v: string | undefined): RangeKey => (v && v in RANGES ? (v as RangeKey) : "6h");

export type Point = { t: number; v: number };
export type Series = { label: string; points: Point[] };
export type Performance = { cpu: Series[]; memory: Series[]; disk: Series[]; error: string | null };

const SLUG = /^[a-z0-9][a-z0-9-]{1,30}$/;
const HOST = /^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$/;

/** Rows of (_time, _value[, name]) grouped into one series per name. */
function toSeries(rows: Record<string, string>[], byName: boolean): Series[] {
  const map = new Map<string, Point[]>();
  for (const r of rows) {
    const v = Number(r._value), t = Date.parse(r._time);
    if (!Number.isFinite(v) || !Number.isFinite(t)) continue;
    const key = byName ? r.name || "?" : "";
    (map.get(key) ?? map.set(key, []).get(key)!).push({ t, v });
  }
  return [...map.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([label, points]) => ({ label, points: points.sort((a, b) => a.t - b.t) }));
}

export async function loadPerformance(slug: string, host: string, range: RangeKey): Promise<Performance> {
  if (!SLUG.test(slug) || !HOST.test(host)) return { cpu: [], memory: [], disk: [], error: "invalid computer" };
  const { start, every } = RANGES[range];
  const base = (filter: string) => `import "strings"
from(bucket: "cust_${slug}") |> range(start: ${start})
  |> filter(fn: (r) => ${filter} and strings.toLower(v: r.host) == "${host}")`;
  const win = `|> aggregateWindow(every: ${every}, fn: mean, createEmpty: false)`;
  try {
    const [cpu, mem, disk] = await Promise.all([
      fluxRows(`${base('r._measurement == "cpu" and r._field == "usage_idle" and r.cpu == "cpu-total"')}
        ${win} |> map(fn: (r) => ({r with _value: 100.0 - r._value})) |> keep(columns: ["_time", "_value"]) |> group()`),
      fluxRows(`${base('r._measurement == "mem" and r._field == "used_percent"')}
        ${win} |> keep(columns: ["_time", "_value"]) |> group()`),
      fluxRows(`${base('r._measurement == "volume" and r._field == "used_percent"')}
        ${win} |> keep(columns: ["_time", "_value", "name"]) |> group()`),
    ]);
    return { cpu: toSeries(cpu, false), memory: toSeries(mem, false), disk: toSeries(disk, true), error: null };
  } catch {
    return { cpu: [], memory: [], disk: [], error: "Performance data could not be read right now." };
  }
}
