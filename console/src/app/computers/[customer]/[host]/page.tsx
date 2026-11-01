import { notFound, redirect } from "next/navigation";
import { getScope } from "@/lib/session";
import { canSee, isStaffFor } from "@/lib/authz";
import { env } from "@/lib/env";
import { getView } from "@/lib/view";
import { ago, bytes, when } from "@/lib/format";
import { loadFleet } from "@/lib/fleet";

export const dynamic = "force-dynamic";

// One computer: header, then the same facts the list shows, in full. Charts, events and Connect arrive in later steps.
export default async function ComputerPage({ params }: { params: Promise<{ customer: string; host: string }> }) {
  const scope = await getScope();
  if (!scope) redirect("/login");
  const { customer, host } = await params;
  // A computer you may not see answers 404, the same as one that does not exist.
  if (!/^[a-z0-9][a-z0-9-]{1,30}$/.test(customer) || !/^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$/.test(host) || !canSee(scope, customer)) notFound();

  const view = await getView(scope);
  const { rows } = await loadFleet(scope, { ...view, customer, site: "" });
  const r = rows.find((x) => x.slug === customer && x.host === host);
  if (!r) notFound();
  const staff = isStaffFor(scope, customer);
  const classic = env.legacyUrl;

  return (
    <>
      <p className="small"><a href="/computers">← Computers</a></p>
      <h1><span className={`dot ${r.online ? "ok" : "none"}`} />{r.name}</h1>
      <p className="sub">{r.customerName}{r.site !== "main" ? ` · ${r.site}` : ""} · {r.online ? "online now" : `last seen ${ago(r.lastSeen)}`}{r.m?.os_desc ? ` · ${r.m.os_desc}` : ""}</p>

      <div className="grid2">
        <div className="panel">
          <h3>Drive encryption</h3>
          <div className="body">
            {r.drives.length === 0 ? <span className="muted">The monitoring agent has not reported any drives.</span> : r.drives.map((d) => (
              <div key={d.volume} className="kv">
                <strong>{d.volume}:</strong>
                <span className="bar grow" role="progressbar" aria-valuenow={Math.round(d.percent)} aria-valuemin={0} aria-valuemax={100}>
                  <div className={d.state.key} style={{ width: `${Math.max(0, Math.min(100, d.percent))}%` }} />
                </span>
                <span className={`pill ${d.state.key}`}>{d.state.label}</span>
                <span className="muted small">{d.key_saved ? "key saved" : "no key saved"}</span>
              </div>
            ))}
            {staff && r.drives.length > 0 && classic && <p><a className="btn small" href={`${classic}/encryption?customer=${customer}&host=${host}&volume=${r.drives[0].volume}`}>Manage encryption and keys</a></p>}
          </div>
        </div>

        <div className="panel">
          <h3>Backup</h3>
          <div className="body">
            {r.m ? (
              <>
                <p><span className={`pill ${r.backup!.key}`}>{r.backup!.label}</span></p>
                <div className="kv"><span className="muted">Last good backup</span><span title={when(r.m.last_success)}>{ago(r.m.last_success)}</span></div>
                <div className="kv"><span className="muted">Data protected</span><span>{r.m.bytes_processed ? bytes(r.m.bytes_processed) : "none yet"}</span></div>
                {classic && <p><a className="btn small" href={`${classic}/machines/${r.m.id}`}>Browse, restore and schedule</a></p>}
              </>
            ) : <span className="muted">This computer is not set up for backup.</span>}
          </div>
        </div>
      </div>
    </>
  );
}
