import { redirect } from "next/navigation";
import { getScope } from "@/lib/session";
import { getView } from "@/lib/view";
import { ago, bytes, when } from "@/lib/format";
import { backupNeedsLook, fullyEncrypted, keyMissing, loadFleet, notFullyEncrypted } from "@/lib/fleet";
import Filters from "../Filters";
import Pager, { PAGE_SIZE, pageOf } from "../Pager";

export const dynamic = "force-dynamic";

const ENC_OPTIONS = [
  { value: "off", label: "Not fully encrypted" },
  { value: "on", label: "Fully encrypted" },
  { value: "nokey", label: "Key not saved" },
];
const STATUS_OPTIONS = [
  { value: "online", label: "Online now" },
  { value: "offline", label: "Not online" },
  { value: "attention", label: "Backup needs a look" },
];

export default async function Computers({ searchParams }: { searchParams: Promise<{ enc?: string; status?: string; page?: string }> }) {
  const scope = await getScope();
  if (!scope) redirect("/login");
  const sp = await searchParams;
  const view = await getView(scope);
  const { rows, failed } = await loadFleet(scope, view);

  const shown = rows.filter((r) =>
    (!sp.enc || (sp.enc === "on" ? fullyEncrypted(r) : sp.enc === "off" ? notFullyEncrypted(r) : keyMissing(r))) &&
    (!sp.status || (sp.status === "online" ? r.online : sp.status === "offline" ? !r.online : backupNeedsLook(r))));
  const multi = !view.customer && (scope.admin || view.customers.length > 1);
  const page = pageOf(sp.page, shown.length);
  const pageRows = shown.slice((page - 1) * PAGE_SIZE, page * PAGE_SIZE);

  return (
    <>
      <h1>Computers</h1>
      <p className="sub">Every computer you look after: whether it is online, how its drives are encrypted, and its backup.</p>
      {failed.length > 0 && <div className="banner warn">Could not read monitoring data for: {failed.join(", ")}.</div>}
      <Filters action="/computers" fields={[
        { name: "status", label: "Status", value: sp.status ?? "", options: STATUS_OPTIONS },
        { name: "enc", label: "Encryption", value: sp.enc ?? "", options: ENC_OPTIONS },
      ]} />

      <div className="panel">
        <h3>{shown.length} {shown.length === 1 ? "computer" : "computers"}</h3>
        <div className="scroll">
          {shown.length === 0 ? <div className="body muted">{rows.length === 0 ? "No computers have reported yet." : "No computers match these filters."}</div> : (
            <table>
              <thead><tr><th>Computer</th>{multi && <th>Company</th>}<th>Encryption</th><th>Backup</th><th>Last good backup</th><th>Size</th><th>Last seen</th></tr></thead>
              <tbody>
                {pageRows.map((r) => (
                  <tr key={r.key}>
                    <td>
                      <span className={`dot ${r.online ? "ok" : "none"}`} title={r.online ? "Online" : "Not online"} />
                      <a href={`/computers/${r.slug}/${r.host}`}>{r.name}</a>
                      {r.site !== "main" && <span className="muted small"> · {r.site}</span>}
                    </td>
                    {multi && <td className="muted">{r.customerName}</td>}
                    <td>
                      {r.drives.length === 0 ? <span className="muted">No data</span> : r.drives.map((d) => (
                        <span key={d.volume} className="drive" title={`${d.label}: ${d.status}${d.key_saved ? ", recovery key saved" : ""}`}>
                          {d.volume}:
                          <span className="bar" role="progressbar" aria-valuenow={Math.round(d.percent)} aria-valuemin={0} aria-valuemax={100}>
                            <div className={d.state.key} style={{ width: `${Math.max(0, Math.min(100, d.percent))}%` }} />
                          </span>
                          <span className={`pill ${d.state.key}`}>{d.state.label}</span>
                        </span>
                      ))}
                    </td>
                    <td>{r.backup ? <span className={`pill ${r.backup.key}`}>{r.backup.label}</span> : <span className="muted">Not backed up</span>}</td>
                    <td className="muted" title={r.m ? when(r.m.last_success) : ""}>{r.m ? ago(r.m.last_success) : ""}</td>
                    <td className="muted">{r.m?.bytes_processed ? bytes(r.m.bytes_processed) : ""}</td>
                    <td className="muted" title={when(r.lastSeen)}>{ago(r.lastSeen)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
        <Pager total={shown.length} page={page} path="/computers" params={{ status: sp.status, enc: sp.enc }} />
      </div>
    </>
  );
}
