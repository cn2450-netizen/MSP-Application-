import { redirect } from "next/navigation";
import { getScope } from "@/lib/session";
import { getView } from "@/lib/view";
import { ago } from "@/lib/format";
import { backupNeedsLook, fullyEncrypted, keyMissing, loadFleet, notFullyEncrypted, offlineLong, type FleetRow } from "@/lib/fleet";

export const dynamic = "force-dynamic";

type Issue = { row: FleetRow; what: string; tone: "bad" | "warn" };

function issuesFor(r: FleetRow): Issue[] {
  const out: Issue[] = [];
  if (r.lastSeen && offlineLong(r)) out.push({ row: r, what: `Not seen for ${ago(r.lastSeen).replace(" ago", "")}`, tone: "warn" });
  if (!r.lastSeen) out.push({ row: r, what: "No monitoring data (agent missing?)", tone: "warn" });
  if (r.drives.some((d) => d.state.label === "Off")) out.push({ row: r, what: "Drive not encrypted", tone: "bad" });
  else if (notFullyEncrypted(r)) out.push({ row: r, what: "Encryption suspended or in progress", tone: "warn" });
  if (keyMissing(r)) out.push({ row: r, what: "Recovery key not saved", tone: "warn" });
  if (backupNeedsLook(r)) out.push({ row: r, what: r.backup!.label, tone: r.backup!.key === "bad" ? "bad" : "warn" });
  return out;
}

export default async function Overview() {
  const scope = await getScope();
  if (!scope) redirect("/login");
  const view = await getView(scope);
  const { rows, failed } = await loadFleet(scope, view);
  const title = view.customer ? view.customers.find((c) => c.slug === view.customer)?.name ?? "Overview" : "Overview";

  const issues = rows.flatMap(issuesFor).sort((a, b) => (a.tone === b.tone ? 0 : a.tone === "bad" ? -1 : 1));
  const withIssue = new Set(issues.map((i) => i.row.key)).size;
  const multi = !view.customer && (scope.admin || view.customers.length > 1);

  return (
    <>
      <h1>{title}</h1>
      <p className="sub">{view.customer ? "A summary for this company. Use the Company box above to change it." : "Everything you look after, at a glance. Pick a company above to focus on one."}</p>
      {failed.length > 0 && <div className="banner warn">Could not read monitoring data for: {failed.join(", ")}.</div>}

      <div className="tiles">
        <div className="tile"><div className="label">Computers</div><div className="num">{rows.length}</div></div>
        <div className="tile ok"><div className="label">Online now</div><div className="num">{rows.filter((r) => r.online).length}</div></div>
        <div className="tile ok"><div className="label">Fully encrypted</div><div className="num">{rows.filter(fullyEncrypted).length}</div></div>
        <div className="tile ok"><div className="label">Backed up and healthy</div><div className="num">{rows.filter((r) => r.backup?.key === "ok").length}</div></div>
        <div className={`tile ${withIssue ? "bad" : "ok"}`}><div className="label">Need attention</div><div className="num">{withIssue}</div></div>
      </div>

      <div className="panel">
        <h3>Needs attention</h3>
        <div className="scroll">
          {issues.length === 0 ? <div className="body muted">{rows.length === 0 ? "No computers have reported yet." : "Nothing needs attention."}</div> : (
            <table>
              <thead><tr><th>Computer</th>{multi && <th>Company</th>}<th>Problem</th><th>Last seen</th></tr></thead>
              <tbody>
                {issues.map((i, n) => (
                  <tr key={`${i.row.key}-${n}`}>
                    <td><a href={`/computers/${i.row.slug}/${i.row.host}`}>{i.row.name}</a></td>
                    {multi && <td className="muted">{i.row.customerName}</td>}
                    <td><span className={`pill ${i.tone}`}>{i.what}</span></td>
                    <td className="muted">{ago(i.row.lastSeen)}</td>
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
