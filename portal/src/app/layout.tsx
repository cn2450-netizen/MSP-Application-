import "./globals.css";
import type { Metadata } from "next";
import { getScope } from "@/lib/session";
import { getView } from "@/lib/view";
import ThemeToggle from "./ThemeToggle";
import ScopePicker from "./ScopePicker";
import Nav from "./Nav";

export const metadata: Metadata = { title: "MSP Portal", robots: { index: false, follow: false } };

export default async function RootLayout({ children }: { children: React.ReactNode }) {
  const scope = await getScope();
  const view = scope ? await getView(scope) : null;
  return (
    <html lang="en">
      <body>
        {scope && view ? (
          <div className="shell">
            <aside>
              <a className="brand" href="/">MSP Portal</a>
              <Nav />
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
