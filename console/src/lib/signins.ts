// Who signed in to ONE computer, from the Security log events the agent ships to Loki (4624 / 4625 / 4647 / 4740).
// The tenant header is set here from the slug the caller already checked with canSee().

export type SignIn = { t: number; what: "Signed in" | "Failed sign-in" | "Signed out" | "Locked out"; user: string; how: string; from: string; detail: string };
export type SignIns = { rows: SignIn[]; truncated: boolean; error: string | null };

const URL = process.env.LOKI_URL || "http://loki:3100";
const SLUG = /^[a-z0-9][a-z0-9-]{1,30}$/;
const HOST = /^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$/;
export const SIGNIN_DAYS = 14;
const LIMIT = 2000;

const LOGON_TYPES: Record<string, string> = { "2": "At the keyboard", "10": "Remote desktop", "11": "Cached sign-in" };
// the reason Windows gives for a failed sign-in (Status / SubStatus)
const FAIL: Record<string, string> = {
  "0xc000006a": "Wrong password", "0xc0000064": "Unknown user name", "0xc0000234": "Account locked out", "0xc0000072": "Account disabled",
  "0xc000006f": "Outside allowed hours", "0xc0000070": "Not allowed on this computer", "0xc0000071": "Password expired", "0xc0000193": "Account expired",
};

function fields(line: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const m of line.matchAll(/(\w+)="((?:[^"\\]|\\.)*)"/g)) out[m[1]] = m[2].replace(/\\(["\\])/g, "$1");
  return out;
}

export async function loadSignIns(slug: string, host: string): Promise<SignIns> {
  if (!SLUG.test(slug) || !HOST.test(host)) return { rows: [], truncated: false, error: "invalid computer" };
  try {
    const q = new URLSearchParams({ query: `{host=~"(?i)^${host}$",Channel="Security"}`, limit: String(LIMIT), direction: "backward", since: `${SIGNIN_DAYS}d` });
    const res = await fetch(`${URL}/loki/api/v1/query_range?${q}`, { headers: { "X-Scope-OrgID": slug }, cache: "no-store", signal: AbortSignal.timeout(8000) });
    if (!res.ok) throw new Error(`Loki answered ${res.status}`);
    const body = await res.json() as { data?: { result?: { stream: Record<string, string>; values: [string, string][] }[] } };
    const rows: SignIn[] = [];
    let seen = 0;
    for (const s of body.data?.result ?? []) for (const [ns, line] of s.values) {
      seen++;
      const f = fields(line), id = s.stream.EventID;
      const user = (f.Data_TargetDomainName ? f.Data_TargetDomainName + "\\" : "") + (f.Data_TargetUserName || "?");
      // Windows' own helper accounts and computer accounts are not people
      if (/^(DWM|UMFD)-\d+$/i.test(f.Data_TargetUserName || "") || /\$$/.test(f.Data_TargetUserName || "")) continue;
      const ip = f.Data_IpAddress && f.Data_IpAddress !== "-" && f.Data_IpAddress !== "::1" && f.Data_IpAddress !== "127.0.0.1" ? f.Data_IpAddress : "";
      const t = Number(BigInt(ns) / 1_000_000n);
      if (id === "4624") rows.push({ t, what: "Signed in", user, how: LOGON_TYPES[f.Data_LogonType] ?? "", from: ip || f.Data_WorkstationName || "", detail: "" });
      else if (id === "4625") rows.push({ t, what: "Failed sign-in", user, how: LOGON_TYPES[f.Data_LogonType] ?? "", from: ip || f.Data_WorkstationName || "", detail: FAIL[(f.Data_SubStatus || f.Data_Status || "").toLowerCase()] ?? "" });
      else if (id === "4647") rows.push({ t, what: "Signed out", user, how: "", from: "", detail: "" });
      else if (id === "4740") rows.push({ t, what: "Locked out", user, how: "", from: f.Data_CallerComputerName || "", detail: "" });
    }
    rows.sort((a, b) => b.t - a.t);
    return { rows, truncated: seen >= LIMIT, error: null };
  } catch {
    return { rows: [], truncated: false, error: "Sign-in records could not be read right now." };
  }
}
