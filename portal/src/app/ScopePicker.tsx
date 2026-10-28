"use client";
import { usePathname } from "next/navigation";

// Company / Site picker in the top bar. A plain POST form that submits on change, so it works without client state.
export default function ScopePicker({ customers, customer, site }: {
  customers: { slug: string; name: string; sites: string[] }[]; customer: string; site: string;
}) {
  const path = usePathname();
  const sites = customers.find((c) => c.slug === customer)?.sites ?? [];
  return (
    <form method="post" action="/scope" className="picker">
      <input type="hidden" name="next" value={path} />
      <label><span>Company</span>
        <select name="customer" defaultValue={customer} onChange={(e) => e.currentTarget.form?.requestSubmit()}>
          <option value="">All companies</option>
          {customers.map((c) => <option key={c.slug} value={c.slug}>{c.name}</option>)}
        </select>
      </label>
      <label><span>Site</span>
        <select name="site" defaultValue={site} disabled={!customer || sites.length < 2} onChange={(e) => e.currentTarget.form?.requestSubmit()}>
          <option value="">All sites</option>
          {sites.map((s) => <option key={s} value={s}>{s}</option>)}
        </select>
      </label>
    </form>
  );
}
