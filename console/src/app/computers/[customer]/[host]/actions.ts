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
  const made = await q(
    `INSERT INTO service_restart(customer_slug, host, service_name, display_name, requested_by) VALUES ($1,$2,$3,$4,$5)
     ON CONFLICT DO NOTHING RETURNING id`, [customer, host, listed.name, listed.display, scope.username]);
  if (made.length) await audit(scope, "service.restart", { customer, detail: { host, service: listed.name } });
  redirect(`${back}#services`);
}
