import { redirect } from "next/navigation";
import { getScope } from "@/lib/session";
import { listMachines, health, recentActivity, restoresLast30Days, pendingReplacements } from "@/lib/data";
import { getView } from "@/lib/view";
import { isStaffFor } from "@/lib/authz";
import { ago, bytes, when, describeAction, describeSchedule } from "@/lib/format";
import Filters from "../Filters";
import Donut from "../Donut";

export const dynamic = "force-dynamic";

const STATUS_OPTIONS = [
  { value: "ok", label: "Protected" },
  { value: "attention", label: "Needs attention" },
  { value: "none", label: "No backup yet" },
];

export default async function Home({ searchParams }: { searchParams: Promise<{ status?: string }> }) {
  const scope = await getScope();
  if (!scope) redirect("/login");
  const sp = await searchParams;
  const view = await getView(scope);
  const all = (await listMachines(scope)).filter((m) => (!view.customer || m.customer_slug === view.customer) && (!view.site || m.site_slug === view.site));

  const withHealth = all.map((m) => ({ m, h: health(m) }));
  const shown = withHealth.filter(({ h }) =>
    !sp.status || (sp.status === "attention" ? h.key === "warn" || h.key === "bad" : h.key === sp.status));

  const count = (k: string[]) => shown.filter(({ h }) => k.includes(h.key)).length;
  const protectedN = count(["ok"]), attention = count(["warn", "bad"]), waiting = count(["none"]);
  const totalBytes = shown.reduce((a, { m }) => a + Number(m.bytes_processed ?? 0), 0);
  const [activity, restores] = await Promise.all([recentActivity(scope, 15), restoresLast30Days(scope)]);
  const multi = !view.customer && (scope.admin || view.customers.length > 1);
  const waiting_for_me = (await pendingReplacements(scope)).filter((r) => isStaffFor(scope, r.customer_slug));

  return (
    <>
      <h1>Data protection</h1>
      <p className="sub">Every computer set up for backup, how its last backup went, and what has been happening.</p>

      <Filters fields={[
        { name: "status", label: "Status", value: sp.status ?? "", options: STATUS_OPTIONS },
      ]} />

      <div className="tiles">
        <div className="tile"><div className="label">Computers</div><div className="num">{shown.length}</div></div>
        <div className="tile ok"><div className="label">Protected</div><div className="num">{protectedN}</div></div>
        <div className={`tile ${attention ? "bad" : ""}`}><div className="label">Need attention</div><div className="num">{attention}</div></div>
        <div className="tile"><div className="label">Data protected</div><div className="num">{bytes(totalBytes)}</div></div>
        <div className="tile"><div className="label">Restores (30 days)</div><div className="num">{restores}</div></div>
      </div>

      {waiting_for_me.length > 0 && (
        <div className="panel">
          <h3>Waiting for approval</h3>
          <div className="scroll">
            <table>
              <thead><tr><th>Computer</th>{multi && <th>Customer</th>}<th>Move backups to</th><th>Asked by</th><th /></tr></thead>
              <tbody>
                {waiting_for_me.map((r) => (
                  <tr key={r.id}>
                    <td>{r.computer}</td>{multi && <td className="muted">{r.customer}</td>}<td>{r.new_device}</td>
                    <td className="muted">{r.requested_by}, {ago(r.requested_at)}</td>
                    <td><a className="btn" href={`/machines/${r.machine_id}`}>Review</a></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}

      <div className="dash">
        <div className="panel">
          <h3>Computers</h3>
          <div className="scroll">
            {shown.length === 0 ? <div className="body muted">{all.length === 0 ? "No computers are set up for backup yet." : "No computers match these filters."}</div> : (
              <table>
                <thead><tr><th>Computer</th>{multi && <th>Customer</th>}<th>Status</th><th>Last good backup</th><th>Size</th><th>Runs</th><th>Last seen</th></tr></thead>
                <tbody>
                  {shown.map(({ m, h }) => (
                    <tr key={m.id}>
                      <td><a href={`/machines/${m.id}`}>{m.display_name || m.name}</a>{m.site_slug !== "main" && <span className="muted small"> · {m.site_slug}</span>}</td>
                      {multi && <td className="muted">{m.customer_name}</td>}
                      <td>
                        <span className={`pill ${h.key}`}>{h.label}</span>
                        {m.progress && typeof m.progress.percent_done === "number" && <span className="muted small"> backing up {Math.round(m.progress.percent_done * 100)}%</span>}
                      </td>
                      <td className="muted" title={when(m.last_success)}>{ago(m.last_success)}</td>
                      <td className="muted">{m.bytes_processed ? bytes(m.bytes_processed) : ""}</td>
                      <td className="muted">{m.sched_days && m.sched_time ? describeSchedule(m.sched_days, m.sched_time) : "Nightly"}</td>
                      <td className="muted">{ago(m.last_seen)}</td>
                    </tr>
                  ))}
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

      <div className="panel">
        <h3>Recent activity</h3>
        <div className="scroll">
          {activity.length === 0 ? <div className="body muted">Nothing yet.</div> : (
            <table>
              <thead><tr><th>Time</th><th>User</th><th>What</th><th>Computer</th>{multi && <th>Customer</th>}{scope.admin && <th>IP address</th>}</tr></thead>
              <tbody>
                {activity.map((a, i) => (
                  <tr key={i}>
                    <td className="muted" style={{ whiteSpace: "nowrap" }}>{when(a.at)}</td>
                    <td>{a.actor}</td>
                    <td>{describeAction(a.action, a.detail)}</td>
                    <td className="muted">{a.computer ?? ""}</td>
                    {multi && <td className="muted">{a.customer ?? ""}</td>}
                    {scope.admin && <td className="muted">{a.ip ?? ""}</td>}
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      </div>
    </>
  );
}
