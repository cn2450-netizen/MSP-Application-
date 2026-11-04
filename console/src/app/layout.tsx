import "./globals.css";
import type { Metadata } from "next";
import { brand } from "@/brand";
import { env } from "@/lib/env";
import { getScope } from "@/lib/session";
import { getView } from "@/lib/view";
import ThemeToggle from "./ThemeToggle";
import ScopePicker from "./ScopePicker";
import Nav from "./Nav";

export const metadata: Metadata = { title: brand.name, description: brand.tagline, robots: { index: false, follow: false } };

const ICON = {
  home: "M3 11l9-8 9 8v10a1 1 0 0 1-1 1h-5v-7H9v7H4a1 1 0 0 1-1-1z",
  computer: "M4 5h16a1 1 0 0 1 1 1v9a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1zM8 20h8M12 16v4",
  lock: "M6 11V8a6 6 0 0 1 12 0v3M5 11h14a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1v-8a1 1 0 0 1 1-1zM12 15v2",
  shield: "M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z",
};

export default async function RootLayout({ children }: { children: React.ReactNode }) {
  const scope = await getScope();
  const view = scope ? await getView(scope) : null;
  const classic = env.legacyUrl;
  const items = [
    { href: "/", label: "Overview", icon: ICON.home },
    { href: "/computers", label: "Computers", icon: ICON.computer },
    ...(classic ? [
      { href: `${classic}/encryption`, label: "Encryption", icon: ICON.lock, external: true },
      { href: `${classic}/backups`, label: "Data protection", icon: ICON.shield, external: true },
    ] : []),
  ];
  return (
    <html lang="en">
      <body>
        {scope && view ? (
          <div className="shell">
            <aside>
              <a className="brand" href="/">
                {brand.logo ? <img src={brand.logo} alt="" height={24} /> : <span className="mark" aria-hidden="true">{brand.short.slice(0, 3)}</span>}
                <span>{brand.name}</span>
              </a>
              <Nav items={items} />
              {brand.support && <div className="support muted small">Help: <a href={`mailto:${brand.support}`}>{brand.support}</a></div>}
            </aside>
            <div className="col">
              <header className="top">
                <ScopePicker customers={view.customers} customer={view.customer} site={view.site} />
                <div className="who row">
                  <span>{scope.name}{scope.admin ? " (administrator)" : ""}</span>
                  <ThemeToggle />
                  <form action="/logout" method="post"><button type="submit" className="small">Sign out</button></form>
                </div>
              </header>
              <main>{children}</main>
            </div>
          </div>
        ) : <main>{children}</main>}
      </body>
    </html>
  );
}
