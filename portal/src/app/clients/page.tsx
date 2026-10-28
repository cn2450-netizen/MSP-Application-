import { redirect } from "next/navigation";
import { getScope } from "@/lib/session";
import { getView } from "@/lib/view";

export const dynamic = "force-dynamic";

export default async function Clients() {
  const scope = await getScope();
  if (!scope) redirect("/login");
  const view = await getView(scope);

  return (
    <>
      <h1>Clients</h1>
      <p className="sub">Every company you support. Open one to focus the whole portal on it.</p>
      <div className="panel">
        <h3>Companies</h3>
        <div className="scroll">
          {view.customers.length === 0 ? <div className="body muted">No companies yet.</div> : (
            <table>
              <thead><tr><th>Company</th><th>Sites</th><th>Computers backed up</th><th /></tr></thead>
              <tbody>
                {view.customers.map((c) => (
                  <tr key={c.slug}>
                    <td>{c.name}{view.customer === c.slug && <span className="pill ok" style={{ marginLeft: 8 }}>Selected</span>}</td>
                    <td className="muted">{c.sites.join(", ") || "none"}</td>
                    <td className="muted">{c.computers}</td>
                    <td>
                      <form method="post" action="/scope">
                        <input type="hidden" name="customer" value={c.slug} />
                        <input type="hidden" name="next" value="/" />
                        <button type="submit" className="small">Open</button>
                      </form>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      </div>
      <p className="muted small">New companies are added from the server for now (scripts/add-customer.sh). A form here comes later.</p>
    </>
  );
}
