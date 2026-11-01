import { redirect } from "next/navigation";
import { getScope } from "@/lib/session";
import { isStaffFor } from "@/lib/authz";
import { customerSlug, hostName, listKeys, listRequests, volumeLetter } from "@/lib/bitlocker";
import { getView } from "@/lib/view";
import EncryptionPanel from "./EncryptionPanel";

export const dynamic = "force-dynamic";

type SP = Record<string, string | string[] | undefined>;
const one = (v: string | string[] | undefined) => (Array.isArray(v) ? v[0] : v) ?? "";

// BitLocker for one computer (the Grafana BitLocker table links here with ?customer=&host=&volume=), or, without a
// computer, every saved recovery key and request this person may see. Staff only.
export default async function Encryption({ searchParams }: { searchParams: Promise<SP> }) {
  const scope = await getScope();
  if (!scope) redirect("/login");
  const sp = await searchParams;
  const c = customerSlug.safeParse(one(sp.customer));
  const h = hostName.safeParse(one(sp.host));
  // "C: (Windows)" from the Grafana table: only the drive letter matters
  const v = volumeLetter.safeParse(/^([A-Za-z]):/.exec(one(sp.volume))?.[1] ?? one(sp.volume));
  const customer = c.success ? c.data : null;
  const host = h.success ? h.data : null;
  const volume = v.success ? v.data : null;

  const view = await getView(scope);
  const names = new Map(view.customers.map((x) => [x.slug, x.name]));
  const staff = (slug: string) => isStaffFor(scope, slug);
  if (customer && !staff(customer)) {
    return (<><h1>Encryption</h1><div className="banner bad">Recovery keys are for support staff only.</div></>);
  }

  // the company picked in the top bar narrows the lists too (an explicit ?customer= wins)
  const filter = customer ?? (view.customer || null);
  const keys = (await listKeys(scope, filter, host)).filter((k) => staff(k.customer_slug));
  const requests = (await listRequests(scope, filter, host)).filter((r) => staff(r.customer_slug));

  return (
    <>
      <h1>Encryption</h1>
      <p className="sub">
        {customer && host
          ? <>BitLocker on <strong>{host}</strong> at {names.get(customer) ?? customer}.</>
          : filter ? `BitLocker recovery keys and requests for ${names.get(filter) ?? filter}.` : "BitLocker recovery keys saved by the platform, and requests to turn BitLocker on."}
      </p>
      <EncryptionPanel
        customer={customer} filter={filter} host={host} volume={volume}
        customers={view.customers.filter((x) => staff(x.slug)).map((x) => ({ slug: x.slug, name: x.name }))}
        defaultCustomer={customer ?? view.customer}
        companyName={customer ? names.get(customer) ?? customer : null}
        keys={keys.map((k) => ({ ...k, collected_at: String(k.collected_at), company: names.get(k.customer_slug) ?? k.customer_slug }))}
        requests={requests.map((r) => ({ ...r, requested_at: String(r.requested_at), finished_at: r.finished_at ? String(r.finished_at) : null, company: names.get(r.customer_slug) ?? r.customer_slug }))}
      />
    </>
  );
}
