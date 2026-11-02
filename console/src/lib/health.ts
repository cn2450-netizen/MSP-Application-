import { fluxRows } from "./influx";
import { assessPatches, toPatch, type Patch } from "./patches";
import type { FleetRow } from "./fleet";

// One red / yellow / green light per area for each computer in a list, for the quick-glance Computers page. The lights use
// the same rules as the detail page, but are fetched per company (a handful of queries) rather than per computer.

export type Light = { level: "ok" | "warn" | "bad" | "none"; tip: string };
export type Health = { encryption: Light; backup: Light; services: Light; updates: Light; performance: Light };

/** Services that start automatically but are not running: 1-2 is yellow, 3 or more is red. */
export const SERVICES_WARN = 1, SERVICES_BAD = 3;
/** Processor, memory and the fullest disk, % used: yellow from the first number, red from the second. */
export const LOAD_LIMITS = { cpu: [75, 90], memory: [80, 90], disk: [80, 90] } as const;

const SLUG = /^[a-z0-9][a-z0-9-]{1,30}$/;
const NONE = (tip: string): Light => ({ level: "none", tip });

type Perf = { cpu?: number; memory?: number; disk?: number };
type Svc = { total: number; stopped: number };

async function forCustomer(slug: string) {
  const b = `from(bucket: "cust_${slug}")`;
  const get = (q: string) => fluxRows(q).catch(() => null);
  const [svc, cpu, mem, disk, patch] = await Promise.all([
    get(`${b} |> range(start: -15m) |> filter(fn: (r) => r._measurement == "win_services" and (r._field == "state" or r._field == "startup_mode")) |> last() |> group()
      |> pivot(rowKey: ["host", "service_name"], columnKey: ["_field"], valueColumn: "_value") |> filter(fn: (r) => r.startup_mode == 2) |> keep(columns: ["host", "state"])`),
    get(`${b} |> range(start: -15m) |> filter(fn: (r) => r._measurement == "cpu" and r._field == "usage_idle" and r.cpu == "cpu-total")
      |> map(fn: (r) => ({r with _value: 100.0 - r._value})) |> group(columns: ["host"]) |> mean() |> keep(columns: ["host", "_value"])`),
    get(`${b} |> range(start: -15m) |> filter(fn: (r) => r._measurement == "mem" and r._field == "used_percent") |> group(columns: ["host"]) |> last() |> keep(columns: ["host", "_value"])`),
    get(`${b} |> range(start: -15m) |> filter(fn: (r) => r._measurement == "volume" and r._field == "used_percent")
      |> group(columns: ["host", "name"]) |> last() |> group(columns: ["host"]) |> max() |> keep(columns: ["host", "_value"])`),
    get(`${b} |> range(start: -90d) |> filter(fn: (r) => r._measurement == "patch_history" and r._field == "title")
      |> group(columns: ["host", "kb", "result", "operation", "date", "source"]) |> last() |> group() |> sort(columns: ["date"], desc: true)
      |> keep(columns: ["host", "date", "kb", "result", "operation", "_value"]) |> limit(n: 4000)`),
  ]);
  const num = (rows: Record<string, string>[] | null, into: Map<string, number>) => { for (const r of rows ?? []) { const v = Number(r._value); if (Number.isFinite(v)) into.set(r.host.toLowerCase(), v); } };
  const perf = { cpu: new Map<string, number>(), memory: new Map<string, number>(), disk: new Map<string, number>() };
  num(cpu, perf.cpu); num(mem, perf.memory); num(disk, perf.disk);
  const services = new Map<string, Svc>();
  for (const r of svc ?? []) { const h = r.host.toLowerCase(), s = services.get(h) ?? services.set(h, { total: 0, stopped: 0 }).get(h)!; s.total++; if (Number(r.state) !== 4) s.stopped++; }
  const patches = new Map<string, Patch[]>();
  for (const r of patch ?? []) { const h = r.host.toLowerCase(); (patches.get(h) ?? patches.set(h, []).get(h)!).push(toPatch(r)); }
  return { perf, services, patches };
}

function lightEncryption(r: FleetRow): Light {
  if (r.drives.length === 0) return NONE("No drive data from the monitoring agent");
  const bad = r.drives.filter((d) => d.state.key === "bad"), warn = r.drives.filter((d) => d.state.key === "warn");
  if (bad.length) return { level: "bad", tip: `Drive ${bad.map((d) => d.volume + ":").join(", ")} not encrypted` };
  if (warn.length) return { level: "warn", tip: warn.map((d) => `Drive ${d.volume}: ${d.state.label.toLowerCase()}`).join("; ") };
  const nokey = r.drives.filter((d) => !d.key_saved);
  if (nokey.length) return { level: "warn", tip: `Encrypted, but no recovery key saved for ${nokey.map((d) => d.volume + ":").join(", ")}` };
  return { level: "ok", tip: "All drives encrypted, recovery keys saved" };
}

function lightBackup(r: FleetRow): Light {
  if (!r.backup) return NONE("Not set up for backup");
  const level = r.backup.key === "ok" || r.backup.key === "warn" || r.backup.key === "bad" ? r.backup.key : "none";
  return { level, tip: `Backup: ${r.backup.label}` };
}

/** Lights for every row, keyed by the row's key. Only the companies in `rows` are queried. */
export async function loadHealth(rows: FleetRow[]): Promise<Map<string, Health>> {
  const slugs = [...new Set(rows.map((r) => r.slug))].filter((s) => SLUG.test(s));
  const data = new Map(await Promise.all(slugs.map(async (s) => [s, await forCustomer(s)] as const)));
  const out = new Map<string, Health>();
  for (const r of rows) {
    const d = data.get(r.slug);
    let services = NONE("No service data"), updates = NONE("No update history"), performance = NONE("No recent performance data");
    if (d) {
      const sv = d.services.get(r.host);
      if (sv && sv.total) services = sv.stopped >= SERVICES_BAD ? { level: "bad", tip: `${sv.stopped} automatic services stopped` } : sv.stopped >= SERVICES_WARN ? { level: "warn", tip: `${sv.stopped} automatic service${sv.stopped === 1 ? "" : "s"} stopped` } : { level: "ok", tip: `All ${sv.total} automatic services running` };
      const pl = d.patches.get(r.host);
      if (pl?.length) { const c = assessPatches(pl).compliance; updates = { level: c.key, tip: `${c.label}. ${c.detail}` }; }
      const v: Perf = { cpu: d.perf.cpu.get(r.host), memory: d.perf.memory.get(r.host), disk: d.perf.disk.get(r.host) };
      const have = (Object.keys(LOAD_LIMITS) as (keyof Perf)[]).filter((k) => v[k] !== undefined);
      if (have.length) {
        const level = have.some((k) => v[k]! >= LOAD_LIMITS[k][1]) ? "bad" : have.some((k) => v[k]! >= LOAD_LIMITS[k][0]) ? "warn" : "ok";
        performance = { level, tip: have.map((k) => `${k === "cpu" ? "Processor" : k === "memory" ? "Memory" : "Fullest disk"} ${Math.round(v[k]!)}%`).join(", ") };
      }
    }
    out.set(r.key, { encryption: lightEncryption(r), backup: lightBackup(r), services, updates, performance });
  }
  return out;
}
