export const PAGE_SIZE = 15;

/** The page number from ?page=, clamped to what exists. */
export function pageOf(raw: string | undefined, total: number, size = PAGE_SIZE): number {
  const last = Math.max(1, Math.ceil(total / size));
  const n = Number.parseInt(raw ?? "1", 10);
  return Number.isFinite(n) ? Math.min(Math.max(n, 1), last) : 1;
}

// "Showing 1-15 of 22" on the left, page buttons on the right. Plain links, so it works without script and the URL is shareable.
// `params` are the other query values (filters) to keep when the page changes.
export default function Pager({ total, page, path, params = {}, size = PAGE_SIZE }: {
  total: number; page: number; path: string; params?: Record<string, string | undefined>; size?: number;
}) {
  const last = Math.max(1, Math.ceil(total / size));
  if (total <= size) return null;
  const href = (p: number) => {
    const u = new URLSearchParams();
    for (const [k, v] of Object.entries(params)) if (v) u.set(k, v);
    if (p > 1) u.set("page", String(p));
    const qs = u.toString();
    return qs ? `${path}?${qs}` : path;
  };
  // 1 … 4 5 [6] 7 8 … 20
  const pages: (number | "gap")[] = [];
  for (let p = 1; p <= last; p++) if (p === 1 || p === last || Math.abs(p - page) <= 1) pages.push(p);
  else if (pages[pages.length - 1] !== "gap") pages.push("gap");
  const from = (page - 1) * size + 1, to = Math.min(total, page * size);

  return (
    <nav className="pager" aria-label="Pages">
      <span className="muted small">Showing {from}–{to} of {total}</span>
      <span className="pages">
        {page > 1 ? <a className="btn small" href={href(page - 1)} rel="prev">Previous</a> : <span className="btn small off">Previous</span>}
        {pages.map((p, i) => p === "gap"
          ? <span key={`g${i}`} className="muted">…</span>
          : p === page
            ? <span key={p} className="btn small on" aria-current="page">{p}</span>
            : <a key={p} className="btn small" href={href(p)}>{p}</a>)}
        {page < last ? <a className="btn small" href={href(page + 1)} rel="next">Next</a> : <span className="btn small off">Next</span>}
      </span>
    </nav>
  );
}
