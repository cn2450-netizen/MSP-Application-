import { redirect } from "next/navigation";
import { getScope } from "@/lib/session";
import { getView } from "@/lib/view";
import { ago, when } from "@/lib/format";
import { loadHealth, type Light } from "@/lib/health";
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

const WORD = { ok: "good", warn: "needs a look", bad: "needs action", none: "no data" } as const;
const Lamp = ({ light, what }: { light: Light; what: string }) => (
  <td className="light-c"><span className={`lamp ${light.level}`} title={light.tip} role="img" aria-label={`${what}: ${WORD[light.level]}. ${light.tip}`} /></td>
);

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
  const lights = await loadHealth(pageRows);

  return (
    <>
      <h1>Computers</h1>
      <p className="sub">Every computer you look after, at a glance. Green is fine, yellow needs a look, red needs action, grey means no data. Open a computer for the details.</p>
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
              <thead><tr><th>Computer</th>{multi && <th>Company</th>}<th className="light-h">Encryption</th><th className="light-h">Backup</th><th className="light-h">Services</th><th className="light-h">Updates</th><th className="light-h">Performance</th><th>Last good backup</th><th>Last seen</th></tr></thead>
              <tbody>
                {pageRows.map((r) => (
                  <tr key={r.key}>
                    <td>
                      <span className={`dot ${r.online ? "ok" : "none"}`} title={r.online ? "Online" : "Not online"} />
                      <a href={`/computers/${r.slug}/${r.host}`}>{r.name}</a>
                      {r.site !== "main" && <span className="muted small"> · {r.site}</span>}
                    </td>
                    {multi && <td className="muted">{r.customerName}</td>}
                    {(["encryption", "backup", "services", "updates", "performance"] as const).map((k) => <Lamp key={k} light={lights.get(r.key)![k]} what={k} />)}
                    <td className="muted" title={r.m ? when(r.m.last_success) : ""}>{r.m ? ago(r.m.last_success) : ""}</td>
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
