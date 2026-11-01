"use client";
import { usePathname } from "next/navigation";

type Item = { href: string; label: string; icon: string; external?: boolean };

// `external` items still live in the classic portal and open there (same sign-in); they move here one at a time.
export default function Nav({ items }: { items: Item[] }) {
  const path = usePathname();
  const active = (h: string) => (h === "/" ? path === "/" : path === h || path.startsWith(h + "/"));
  return (
    <nav className="side" aria-label="Main">
      {items.map((i) => (
        <a key={i.href} href={i.href} className={!i.external && active(i.href) ? "on" : ""} aria-current={!i.external && active(i.href) ? "page" : undefined}>
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d={i.icon} /></svg>
          <span>{i.label}</span>
          {i.external && <span className="ext" aria-hidden="true">↗</span>}
        </a>
      ))}
    </nav>
  );
}
