"use server";
import { redirect } from "next/navigation";
import { getScope } from "@/lib/session";
import { isStaffFor } from "@/lib/authz";
import { audit } from "@/lib/audit";
import { q } from "@/lib/db";
import { loadServices, canRestart } from "@/lib/services";

// "Restart this service": staff only. The request is saved and audited here; scripts/service-restart-executor.sh carries it
// out on the computer within a minute (through MeshCentral). The service has to be one the computer reports as an
// automatic-start service, so the browser cannot ask for any other name.
export async function requestRestart(form: FormData) {
  const scope = await getScope();
  if (!scope) redirect("/login");
  const customer = String(form.get("customer") ?? ""), host = String(form.get("host") ?? ""), service = String(form.get("service") ?? "");
  const back = `/computers/${customer}/${host}`;
  if (!/^[a-z0-9][a-z0-9-]{1,30}$/.test(customer) || !/^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$/.test(host)) redirect("/computers");
  if (!isStaffFor(scope, customer)) redirect(back);
  const listed = (await loadServices(customer, host)).rows.find((s) => s.name === service);
  if (!listed || !canRestart(listed.name)) redirect(`${back}#services`);
  let made: unknown[] = [];
  try {
    made = await q(
    `INSERT INTO service_restart(customer_slug, host, service_name, display_name, requested_by) VALUES ($1,$2,$3,$4,$5)
     ON CONFLICT DO NOTHING RETURNING id`, [customer, host, listed.name, listed.display, scope.username]);
  } catch { /* a bad name or a database hiccup must not take the page down */ }
  if (made.length) await audit(scope, "service.restart", { customer, detail: { host, service: listed.name } });
  redirect(`${back}#services`);
}

// "Ignore this service" / "Stop ignoring it": staff only, one list per company that covers every computer of that company.
// An ignored service is still listed but no longer counts toward the Services gauge or light. The service has to be one this
// computer reports as an automatic-start service. Audited.
export async function setIgnore(form: FormData) {
  const scope = await getScope();
  if (!scope) redirect("/login");
  const customer = String(form.get("customer") ?? ""), host = String(form.get("host") ?? ""), service = String(form.get("service") ?? "");
  const stop = String(form.get("mode") ?? "") === "stop";
  const back = `/computers/${customer}/${host}`;
  if (!/^[a-z0-9][a-z0-9-]{1,30}$/.test(customer) || !/^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$/.test(host)) redirect("/computers");
  if (!isStaffFor(scope, customer)) redirect(back);
  const listed = (await loadServices(customer, host)).rows.find((s) => s.name === service);
  if (!listed) redirect(`${back}#services`);
  try {
    if (stop) await q(`DELETE FROM service_ignore WHERE customer_slug = $1 AND lower(service_name) = lower($2)`, [customer, listed.name]);
    else await q(`INSERT INTO service_ignore(customer_slug, service_name, display_name, added_by) VALUES ($1,$2,$3,$4) ON CONFLICT DO NOTHING`, [customer, listed.name, listed.display, scope.username]);
    await audit(scope, stop ? "service.unignore" : "service.ignore", { customer, detail: { host, service: listed.name } });
  } catch { /* a database hiccup must not take the page down */ }
  redirect(`${back}#services`);
}
