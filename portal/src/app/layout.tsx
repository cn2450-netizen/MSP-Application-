import "./globals.css";
import type { Metadata } from "next";
import { getScope } from "@/lib/session";

export const metadata: Metadata = { title: "Backup Portal", robots: { index: false, follow: false } };

export default async function RootLayout({ children }: { children: React.ReactNode }) {
  const scope = await getScope();
  return (
    <html lang="en">
      <body>
        <header className="top">
          <a className="brand" href="/">Backup Portal</a>
          {scope && (
            <div className="who row">
              <span>{scope.name}{scope.admin ? " (administrator)" : ""}</span>
              <form action="/logout" method="post"><button type="submit" className="small">Sign out</button></form>
            </div>
          )}
        </header>
        <main>{children}</main>
      </body>
    </html>
  );
}
