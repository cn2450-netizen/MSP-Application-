// Who may see and do what. Groups come from authentik (the same ones that gate Grafana and MeshCentral):
//   msp-admins            staff for every customer
//   tech-<slug>           staff for that customer only
//   cust-<slug>-users     a customer's own user: that customer only, no staff-only actions
export type Scope = {
  username: string;
  name: string;
  admin: boolean;
  staff: string[];       // customers this person supports (ignored when admin)
  customer: string[];    // customers this person belongs to as an end user
};

export function scopeFromGroups(username: string, name: string, groups: string[]): Scope {
  const staff = new Set<string>();
  const customer = new Set<string>();
  let admin = false;
  for (const g of groups) {
    if (g === "msp-admins") { admin = true; continue; }
    let m = /^tech-([a-z0-9][a-z0-9-]{1,30})$/.exec(g);
    if (m) { staff.add(m[1]); continue; }
    m = /^cust-([a-z0-9][a-z0-9-]{1,30})-users$/.exec(g);
    if (m) customer.add(m[1]);
  }
  return { username, name, admin, staff: [...staff], customer: [...customer] };
}

/** Customers visible to this person; null means all of them. Always pass this into queries. */
export function visibleCustomers(s: Scope): string[] | null {
  if (s.admin) return null;
  return [...new Set([...s.staff, ...s.customer])];
}

export function canSee(s: Scope, customerSlug: string): boolean {
  return s.admin || s.staff.includes(customerSlug) || s.customer.includes(customerSlug);
}

/** Staff-only actions (search across all snapshots, replace a machine, ...). */
export function isStaffFor(s: Scope, customerSlug: string): boolean {
  return s.admin || s.staff.includes(customerSlug);
}
