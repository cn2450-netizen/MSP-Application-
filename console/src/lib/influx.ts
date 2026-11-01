import fs from "node:fs";

// Read-only access to the monitoring data in InfluxDB. The token (secrets/portal_influx_token, made by
// scripts/create-portal-influx-token.sh) can only READ. Every query is for ONE customer's bucket, and the bucket name
// comes from a validated slug that the caller took from the signed-in person's Scope.

const URL = process.env.INFLUX_URL || "http://influxdb:8086";
const ORG = "msp";

function token(): string {
  const f = process.env.INFLUX_TOKEN_FILE;
  const v = f ? fs.readFileSync(f, "utf8").trim() : process.env.INFLUX_TOKEN;
  if (!v) throw new Error("missing INFLUX_TOKEN");
  return v;
}

/** Splits one CSV line (annotated-CSV style: commas, optional double quotes). */
function splitCsv(line: string): string[] {
  const out: string[] = [];
  let cur = "", quoted = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (quoted) { if (ch === '"') { if (line[i + 1] === '"') { cur += '"'; i++; } else quoted = false; } else cur += ch; }
    else if (ch === '"') quoted = true;
    else if (ch === ",") { out.push(cur); cur = ""; }
    else cur += ch;
  }
  out.push(cur);
  return out;
}

/** Runs a Flux query against a customer's bucket and returns the rows as plain objects (all values are strings). */
export async function fluxRows(flux: string): Promise<Record<string, string>[]> {
  const res = await fetch(`${URL}/api/v2/query?org=${ORG}`, {
    method: "POST",
    headers: { authorization: `Token ${token()}`, "content-type": "application/json", accept: "application/csv" },
    body: JSON.stringify({ query: flux, type: "flux", dialect: { header: true, annotations: [] } }),
    cache: "no-store",
    signal: AbortSignal.timeout(8000),
  });
  if (!res.ok) throw new Error(`InfluxDB answered ${res.status}`);
  const rows: Record<string, string>[] = [];
  let header: string[] | null = null;
  for (const line of (await res.text()).split(/\r?\n/)) {
    if (!line) { header = null; continue; }               // a blank line starts a new table with its own header
    const f = splitCsv(line);
    if (!header) { header = f; continue; }
    const row: Record<string, string> = {};
    header.forEach((h, i) => { if (h) row[h] = f[i] ?? ""; });
    rows.push(row);
  }
  return rows;
}
