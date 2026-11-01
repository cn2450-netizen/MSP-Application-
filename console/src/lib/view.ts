import { cookies } from "next/headers";
import { listCustomers, type CustomerRow } from "./data";
import type { Scope } from "./authz";

export const VIEW_COOKIE = "__Host-msp_view";

export type View = { customer: string; site: string; customers: CustomerRow[] };

/**
 * The company and site picked in the top bar ("" = all). It only narrows what is shown: the cookie is checked against
 * the customers this person may see on every request, and every query still gets their Scope.
 */
export async function getView(scope: Scope): Promise<View> {
  const customers = await listCustomers(scope);
  const raw = (await cookies()).get(VIEW_COOKIE)?.value ?? "";
  const [c = "", s = ""] = raw.split("|");
  const cust = customers.find((x) => x.slug === c);
  const site = cust && cust.sites.includes(s) ? s : "";
  return { customer: cust ? cust.slug : "", site, customers };
}
