import { redirect } from "next/navigation";
import { getScope } from "@/lib/session";
import { getView } from "@/lib/view";
import { ago, when } from "@/lib/format";
import { isStaffFor } from "@/lib/authz";
import { loadFleet } from "@/lib/fleet";
import { env } from "@/lib/env";
import { connectUrl, loadNodes } from "@/lib/meshnodes";
import Filters from "../Filters";
import Pager, { PAGE_SIZE, pageOf } from "../Pager";

export const dynamic = "force-dynamic";

const STATUS_OPTIONS = [
  { value: "online", label: "Online now" },
  { value: "offline", label: "Not online" },
];

export default async function Remote({ searchParams }: { searchParams: Promise<{ status?: string; page?: string }> }) {
  const scope = await getScope();
  if (!scope) redirect("/login");
  const sp = await searchParams;
  const view = await getView(scope);
  const { rows, failed } = await loadFleet(scope, view);
  const mesh = env.meshUrl;
  const nodes = await loadNodes();

  const shown = rows.filter((r) => !sp.status || (sp.status === "online" ? r.online : !r.online));
  const multi = !view.customer && (scope.admin || view.customers.length > 1);
  const page = pageOf(sp.page, shown.length);
  const pageRows = shown.slice((page - 1) * PAGE_SIZE, page * PAGE_SIZE);

  return (
    <>
      <h1>Remote access</h1>
      <p className="sub">
        Connect opens a remote desktop session on that computer in MeshCentral (same sign-in as this console). From there you can also open a command prompt or transfer files.
        {mesh && <> <a href={mesh} target="_blank" rel="noopener noreferrer">Open MeshCentral ↗</a></>}
      </p>
      {!mesh && <div className="banner warn">The remote access address is not configured (MESH_HOST).</div>}
      {failed.length > 0 && <div className="banner warn">Could not read monitoring data for: {failed.join(", ")}.</div>}
      <Filters action="/remote" fields={[{ name: "status", label: "Status", value: sp.status ?? "", options: STATUS_OPTIONS }]} />

      <div className="panel">
        <h3>{shown.length} {shown.length === 1 ? "computer" : "computers"}</h3>
        <div className="scroll">
          {shown.length === 0 ? <div className="body muted">{rows.length === 0 ? "No computers have reported yet." : "No computers match this filter."}</div> : (
            <table>
              <thead><tr><th>Computer</th>{multi && <th>Company</th>}<th>Last seen</th><th>Remote session</th></tr></thead>
              <tbody>
                {pageRows.map((r) => (
                  <tr key={r.key}>
                    <td>
                      <span className={`dot ${r.online ? "ok" : "none"}`} title={r.online ? "Online" : "Not online"} />
                      <a href={`/computers/${r.slug}/${r.host}`}>{r.name}</a>
                      {r.site !== "main" && <span className="muted small"> · {r.site}</span>}
                    </td>
                    {multi && <td className="muted">{r.customerName}</td>}
                    <td className="muted" title={when(r.lastSeen)}>{ago(r.lastSeen)}</td>
                    <td>
                      {mesh && isStaffFor(scope, r.slug)
                        ? <a href={nodes.has(r.key) ? connectUrl(mesh, nodes.get(r.key)!) : mesh} target="_blank" rel="noopener noreferrer" title={nodes.has(r.key) ? `Open a remote session on ${r.name}` : `Open MeshCentral and pick ${r.name}`}>Connect ↗</a>
                        : <span className="muted small">{mesh ? "Technicians only" : ""}</span>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
        <Pager total={shown.length} page={page} path="/remote" params={{ status: sp.status }} />
      </div>
    </>
  );
}
