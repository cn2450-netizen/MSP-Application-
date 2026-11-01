import { redirect } from "next/navigation";
import { getScope } from "@/lib/session";
import { isStaffFor } from "@/lib/authz";
import { listMachines, health } from "@/lib/data";
import { driveState, listComputers } from "@/lib/bitlocker";
import { getView } from "@/lib/view";
import { ago, bytes, when } from "@/lib/format";
import Filters from "../Filters";

export const dynamic = "force-dynamic";

const ENC_OPTIONS = [
  { value: "off", label: "Not fully encrypted" },
  { value: "on", label: "Fully encrypted" },
  { value: "nokey", label: "Key not saved" },
];
const BACKUP_OPTIONS = [
  { value: "yes", label: "Backed up" },
  { value: "no", label: "Not backed up" },
];

// One list of every computer: what the monitoring agent reports about its drive encryption (read live from InfluxDB),
// next to its backup status and whether a recovery key is saved.
export default async function Computers({ searchParams }: { searchParams: Promise<{ enc?: string; backup?: string }> }) {
  const scope = await getScope();
  if (!scope) redirect("/login");
  const sp = await searchParams;
  const view = await getView(scope);
  const inView = (c: string, s: string) => (!view.customer || c === view.customer) && (!view.site || s === view.site);

  const machines = (await listMachines(scope)).filter((m) => inView(m.customer_slug, m.site_slug));
  const byKey = new Map(machines.map((m) => [`${m.customer_slug}|${m.name}`, m]));
  const { computers, failed } = await listComputers(scope, view.customers.filter((c) => !view.customer || c.slug === view.customer));

  type Drive = (typeof computers)[number]["drives"][number] & { state: ReturnType<typeof driveState> };
  type Row = { key: string; slug: string; customerName: string; host: string; name: string; site: string; lastSeen: string | null; drives: Drive[]; m?: (typeof machines)[number] };
  const rows: Row[] = computers.filter((c) => inView(c.customer_slug, c.site_slug)).map((c) => ({
    key: `${c.customer_slug}|${c.host}`, slug: c.customer_slug, customerName: c.customer_name, host: c.host, name: c.name, site: c.site_slug,
    lastSeen: c.last_seen, drives: c.drives.map((d) => ({ ...d, state: driveState(d) })), m: byKey.get(`${c.customer_slug}|${c.host}`),
  }));
  const seen = new Set(rows.map((r) => r.key));
  // computers set up for backup that have sent no monitoring data
  for (const m of machines) {
    if (seen.has(`${m.customer_slug}|${m.name}`)) continue;
    rows.push({ key: `${m.customer_slug}|${m.name}`, slug: m.customer_slug, customerName: m.customer_name, host: m.name, name: m.display_name || m.name, site: m.site_slug, lastSeen: null, drives: [], m });
  }

  const notFull = (r: Row) => r.drives.some((d) => d.state.key !== "ok");
  const noKey = (r: Row) => r.drives.some((d) => d.state.key === "ok" && !d.key_saved);
  const full = (r: Row) => r.drives.length > 0 && !notFull(r);
  const shown = rows.filter((r) =>
    (!sp.enc || (sp.enc === "on" ? full(r) : sp.enc === "off" ? notFull(r) : noKey(r))) &&
    (!sp.backup || (sp.backup === "yes" ? !!r.m?.backup_enabled : !r.m?.backup_enabled)));

  const multi = !view.customer && (scope.admin || view.customers.length > 1);

  return (
    <>
      <h1>Computers</h1>
      <p className="sub">Every computer the monitoring agent reports: drive encryption (BitLocker) next to its backup status.</p>
      {failed.length > 0 && <div className="banner warn">Could not read monitoring data for: {failed.join(", ")}.</div>}
      <Filters action="/computers" fields={[
        { name: "enc", label: "Encryption", value: sp.enc ?? "", options: ENC_OPTIONS },
        { name: "backup", label: "Backup", value: sp.backup ?? "", options: BACKUP_OPTIONS },
      ]} />

      <div className="tiles">
        <div className="tile"><div className="label">Computers</div><div className="num">{shown.length}</div></div>
        <div className="tile ok"><div className="label">Fully encrypted</div><div className="num">{shown.filter(full).length}</div></div>
        <div className={`tile ${shown.some(notFull) ? "bad" : ""}`}><div className="label">Not fully encrypted</div><div className="num">{shown.filter(notFull).length}</div></div>
        <div className="tile"><div className="label">Key not saved</div><div className="num">{shown.filter(noKey).length}</div></div>
        <div className="tile"><div className="label">Backed up</div><div className="num">{shown.filter((r) => r.m?.backup_enabled).length}</div></div>
      </div>

      <div className="panel">
        <h3>All computers</h3>
        <div className="scroll">
          {shown.length === 0 ? <div className="body muted">{rows.length === 0 ? "No computers have reported yet." : "No computers match these filters."}</div> : (
            <table>
              <thead><tr><th>Computer</th>{multi && <th>Customer</th>}<th>Encryption (BitLocker)</th><th>Backup</th><th>Last good backup</th><th>Size</th><th>Last seen</th><th /></tr></thead>
              <tbody>
                {shown.map((r) => {
                  const h = r.m ? health(r.m) : null;
                  const first = r.drives.find((d) => d.volume === "C") ?? r.drives[0];
                  return (
                    <tr key={r.key}>
                      <td>{r.m ? <a href={`/machines/${r.m.id}`}>{r.name}</a> : r.name}{r.site !== "main" && <span className="muted small"> · {r.site}</span>}</td>
                      {multi && <td className="muted">{r.customerName}</td>}
                      <td>
                        {r.drives.length === 0 ? <span className="muted">No data</span> : r.drives.map((d) => (
                          <span key={d.volume} className="drive" title={`${d.label}: ${d.status}${d.key_saved ? ", recovery key saved" : ""}`}>
                            {d.volume}:
                            <span className="bar" role="progressbar" aria-valuenow={Math.round(d.percent)} aria-valuemin={0} aria-valuemax={100}>
                              <div className={d.state.key} style={{ width: `${Math.max(0, Math.min(100, d.percent))}%` }} />
                            </span>
                            <span className="small">{Math.round(d.percent)}%</span>
                            <span className={`pill ${d.state.key}`}>{d.state.label}</span>
                            {d.key_saved && <span className="muted small"> key saved</span>}
                          </span>
                        ))}
                      </td>
                      <td>{h ? <span className={`pill ${h.key}`}>{h.label}</span> : <span className="muted">Not backed up</span>}</td>
                      <td className="muted" title={r.m ? when(r.m.last_success) : ""}>{r.m ? ago(r.m.last_success) : ""}</td>
                      <td className="muted">{r.m?.bytes_processed ? bytes(r.m.bytes_processed) : ""}</td>
                      <td className="muted" title={when(r.lastSeen)}>{ago(r.lastSeen)}</td>
                      <td>{first && isStaffFor(scope, r.slug) && <a className="btn small" href={`/encryption?customer=${r.slug}&host=${r.host}&volume=${first.volume}`}>Encryption</a>}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          )}
        </div>
      </div>
    </>
  );
}
