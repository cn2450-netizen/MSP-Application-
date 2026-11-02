import { fluxRows } from "./influx";

// Windows update history for ONE computer, from the patch_history measurement the agent reports (see agent/windows/patches.ps1).
// The caller has already checked canSee() on the slug; slug and host are validated again here because they go into a query.

export type Patch = { date: string; kb: string; title: string; result: string; operation: string };
export type Compliance = { key: "ok" | "warn" | "bad" | "none"; label: string; detail: string };
export type Patches = { rows: Patch[]; lastInstall: string | null; failed: number; health: number | null; compliance: Compliance; error: string | null };

const SLUG = /^[a-z0-9][a-z0-9-]{1,30}$/;
const HOST = /^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$/;

/** A computer is "up to date" when it installed something in the last 45 days and nothing failed in the last 30. */
export const PATCH_FRESH_DAYS = 45;
export const PATCH_FAIL_DAYS = 30;

const none = (error: string | null, label = "No patch data"): Patches => ({ rows: [], lastInstall: null, failed: 0, health: null, compliance: { key: "none", label, detail: error ?? "The monitoring agent has not reported any update history." }, error });

/** The same verdict everywhere: from one computer's update history to its compliance state and gauge value. */
export function assessPatches(list: Patch[]): { lastInstall: string | null; failed: number; health: number | null; compliance: Compliance } {
    const day = 86_400_000, now = Date.now();
    const ms = (d: string) => (/^\d{4}-\d{2}-\d{2}$/.test(d) ? Date.parse(d) : NaN);
    const installs = list.filter((p) => p.operation === "Install" && (p.result === "Succeeded" || p.result === "SucceededWithErrors") && Number.isFinite(ms(p.date)));
    const lastInstall = installs.length ? installs.map((p) => p.date).sort().at(-1)! : null;
    const failedRecent = list.filter((p) => (p.result === "Failed" || p.result === "Aborted") && now - ms(p.date) <= PATCH_FAIL_DAYS * day);
    // a failure is cleared when the same KB later installed
    const failed = failedRecent.filter((f) => !f.kb || !installs.some((i) => i.kb === f.kb)).length;
    const age = lastInstall ? Math.floor((now - ms(lastInstall)) / day) : null;

    let compliance: Compliance;
    if (age === null) compliance = { key: "bad", label: "No updates installed", detail: "No successful update install appears in the last 90 days." };
    else if (age > PATCH_FRESH_DAYS) compliance = { key: "bad", label: "Out of date", detail: `Last update installed ${age} days ago (limit ${PATCH_FRESH_DAYS}).` };
    else if (failed > 0) compliance = { key: "warn", label: "Updates failing", detail: `${failed} update${failed === 1 ? "" : "s"} failed in the last ${PATCH_FAIL_DAYS} days and ${failed === 1 ? "has" : "have"} not installed since.` };
    else compliance = { key: "ok", label: "Up to date", detail: `Last update installed ${age === 0 ? "today" : `${age} day${age === 1 ? "" : "s"} ago`}; none failing.` };
    // gauge: share of install attempts in the last 90 days that worked
    const tried = list.filter((p) => p.operation === "Install" && p.result !== "InProgress");
    const health = tried.length ? (tried.filter((p) => p.result === "Succeeded" || p.result === "SucceededWithErrors").length / tried.length) * 100 : null;
    return { lastInstall, failed, health, compliance };
}

/** Flux rows from the patch_history query into Patch objects. */
export const toPatch = (r: Record<string, string>): Patch => ({ date: r.date || "unknown", kb: r.kb && r.kb !== "none" ? r.kb : "", title: r._value || "", result: r.result || "Unknown", operation: r.operation || "Other" });

export async function loadPatches(slug: string, host: string): Promise<Patches> {
  if (!SLUG.test(slug) || !HOST.test(host)) return none("invalid computer");
  try {
    const rows = await fluxRows(`import "strings"
from(bucket: "cust_${slug}") |> range(start: -90d)
  |> filter(fn: (r) => r._measurement == "patch_history" and r._field == "title" and strings.toLower(v: r.host) == "${host}")
  |> group(columns: ["kb", "result", "operation", "date", "source"]) |> last() |> group()
  |> sort(columns: ["date"], desc: true) |> keep(columns: ["date", "kb", "result", "operation", "_value"]) |> limit(n: 200)`);
    const list: Patch[] = rows.map(toPatch);
    if (list.length === 0) return none(null);

    return { rows: list, ...assessPatches(list), error: null };
  } catch {
    return none("Update history could not be read right now.", "Unknown");
  }
}
