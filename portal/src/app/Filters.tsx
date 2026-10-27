"use client";

// The filter bar: each choice submits at once (a plain GET form, so the page stays a server page and the URL is shareable).
export default function Filters({ fields }: { fields: { name: string; label: string; value: string; options: { value: string; label: string }[] }[] }) {
  return (
    <form method="get" action="/" className="filters">
      {fields.map((f) => (
        <label key={f.name}>
          <span>{f.label}</span>
          <select name={f.name} defaultValue={f.value} onChange={(e) => e.currentTarget.form?.requestSubmit()}>
            <option value="">All</option>
            {f.options.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
          </select>
        </label>
      ))}
      <noscript><button type="submit">Apply</button></noscript>
    </form>
  );
}
