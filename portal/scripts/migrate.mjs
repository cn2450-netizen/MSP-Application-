// Applies migrations/*.sql in order, once each. Runs at container start, before the web server.
import pg from "pg";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const dir = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "migrations");
const password = process.env.PORTAL_DB_PASSWORD_FILE ? fs.readFileSync(process.env.PORTAL_DB_PASSWORD_FILE, "utf8").trim() : process.env.PORTAL_DB_PASSWORD;
const client = new pg.Client({ host: process.env.PORTAL_DB_HOST || "postgres", user: "portal", database: "portal", password });
await client.connect();
await client.query("CREATE TABLE IF NOT EXISTS schema_migration (name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())");
await client.query("SELECT pg_advisory_lock(7301)");
for (const f of fs.readdirSync(dir).filter((n) => n.endsWith(".sql")).sort()) {
  const done = await client.query("SELECT 1 FROM schema_migration WHERE name = $1", [f]);
  if (done.rowCount) continue;
  console.log("applying", f);
  await client.query("BEGIN");
  try {
    await client.query(fs.readFileSync(path.join(dir, f), "utf8"));
    await client.query("INSERT INTO schema_migration(name) VALUES ($1)", [f]);
    await client.query("COMMIT");
  } catch (e) {
    await client.query("ROLLBACK");
    console.error("migration failed:", f, e.message);
    process.exit(1);
  }
}
await client.end();
console.log("database is up to date");
