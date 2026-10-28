import { redirect } from "next/navigation";
import { getScope } from "@/lib/session";
import { getView } from "@/lib/view";
import { listMachines, health, restoresLast30Days, pendingReplacements } from "@/lib/data";
import { isStaffFor } from "@/lib/authz";
import { ago, bytes } from "@/lib/format";
import Donut from "./Donut";

export const dynamic = "force-dynamic";

export default async function Home() {
  const scope = await getScope();
  if (!scope) redirect("/login");
  const view = await getView(scope);
  const machines = (await listMachines(scope)).filter((m) => (!view.customer || m.customer_slug === view.customer) && (!view.site || m.site_slug === view.site));
  const rows = machines.map((m) => ({ m, h: health(m) }));
  const n = (keys: string[]) => rows.filter(({ h }) => keys.includes(h.key)).length;
  const protectedN = n(["ok"]), attention = n(["warn", "bad"]), waiting = n(["none"]);
  const clients = view.customer ? view.customers.filter((c) => c.slug === view.customer) : view.customers;
  const restores = await restoresLast30Days(scope);
  const approvals = (await pendingReplacements(scope)).filter((r) => isStaffFor(scope, r.customer_slug) && (!view.customer || r.customer_slug === view.customer));
  const title = view.customer ? view.customers.find((c) => c.slug === view.customer)?.name ?? "Home" : "Overview";

  return (
    <>
      <h1>{title}</h1>
      <p className="sub">{view.customer ? "A summary for this company. Use the Company box above to change it." : "All of your companies at a glance. Pick a company above to focus on one."}</p>

      <div className="tiles">
        <div className="tile"><div className="label">Companies</div><div className="num">{clients.length}</div></div>
        <div className="tile"><div className="label">Backed-up computers</div><div className="num">{machines.length}</div></div>
        <div className="tile ok"><div className="label">Protected</div><div className="num">{protectedN}</div></div>
        <div className={`tile ${attention ? "bad" : ""}`}><div className="label">Need attention</div><div className="num">{attention}</div></div>
        <div className="tile"><div className="label">Restores (30 days)</div><div className="num">{restores}</div></div>
      </div>

      {approvals.length > 0 && (
        <div className="panel">
          <h3>Waiting for approval</h3>
          <div className="scroll"><table>
            <thead><tr><th>Computer</th><th>Company</th><th>Asked by</th><th /></tr></thead>
            <tbody>{approvals.map((r) => (
              <tr key={r.id}><td>{r.computer}</td><td className="muted">{r.customer}</td><td className="muted">{r.requested_by}, {ago(r.requested_at)}</td>
                <td><a className="btn" href={`/machines/${r.machine_id}`}>Review</a></td></tr>
            ))}</tbody>
          </table></div>
        </div>
      )}

      <div className="dash">
        <div className="panel">
          <h3>Companies</h3>
          <div className="scroll">
            {clients.length === 0 ? <div className="body muted">Nothing to show yet.</div> : (
              <table>
                <thead><tr><th>Company</th><th>Sites</th><th>Computers</th><th>Backup health</th><th>Data protected</th></tr></thead>
                <tbody>
                  {clients.map((c) => {
                    const mine = rows.filter(({ m }) => m.customer_slug === c.slug);
                    const bad = mine.filter(({ h }) => h.key === "warn" || h.key === "bad").length;
                    const none = mine.filter(({ h }) => h.key === "none").length;
                    const size = mine.reduce((a, { m }) => a + Number(m.bytes_processed ?? 0), 0);
                    return (
                      <tr key={c.slug}>
                        <td>{c.name}</td>
                        <td className="muted">{c.sites.length}</td>
                        <td className="muted">{mine.length}</td>
                        <td>{mine.length === 0 ? <span className="muted">No backups set up</span>
                          : bad ? <span className="pill bad">{bad} need attention</span>
                          : none ? <span className="pill none">{none} waiting for first backup</span>
                          : <span className="pill ok">All protected</span>}</td>
                        <td className="muted">{size ? bytes(size) : ""}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            )}
          </div>
        </div>
        <div className="panel">
          <h3>Backup health</h3>
          <div className="body">
            <Donut label="Computers by backup health" slices={[
              { label: "Protected", value: protectedN, color: "var(--ok)" },
              { label: "Needs attention", value: attention, color: "var(--bad)" },
              { label: "No backup yet", value: waiting, color: "var(--none)" },
            ]} />
          </div>
        </div>
      </div>
    </>
  );
}
