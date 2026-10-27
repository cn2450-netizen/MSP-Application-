import { redirect } from "next/navigation";
import { getScope } from "@/lib/session";
import { listMachines, health } from "@/lib/data";
import { ago } from "@/lib/format";

export const dynamic = "force-dynamic";

export default async function Home() {
  const scope = await getScope();
  if (!scope) redirect("/login");
  const machines = await listMachines(scope);
  const byCustomer = new Map<string, typeof machines>();
  for (const m of machines) byCustomer.set(m.customer_name, [...(byCustomer.get(m.customer_name) ?? []), m]);

  return (
    <>
      <h1>Your computers</h1>
      <p className="sub">Every computer that is set up for backup, and how its last backup went.</p>
      {machines.length === 0 && <div className="card">No computers are set up for backup yet.</div>}
      {[...byCustomer].map(([customer, list]) => (
        <section key={customer}>
          {(scope.admin || byCustomer.size > 1) && <h2>{customer}</h2>}
          {list.map((m) => {
            const h = health(m);
            return (
              <a key={m.id} className="card machine" href={`/machines/${m.id}`}>
                <div className="row">
                  <div className="grow">
                    <div className="name">{m.display_name || m.name}</div>
                    <div className="muted small">
                      {m.site_slug !== "main" ? `${m.site_slug} · ` : ""}last good backup {ago(m.last_success)}
                      {m.progress && typeof m.progress.percent_done === "number" ? ` · backing up now (${Math.round(m.progress.percent_done * 100)}%)` : ""}
                    </div>
                  </div>
                  <span className={`pill ${h.key}`}>{h.label}</span>
                </div>
              </a>
            );
          })}
        </section>
      ))}
    </>
  );
}
