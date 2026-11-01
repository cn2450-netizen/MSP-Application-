export function ago(iso: string | null | undefined): string {
  if (!iso) return "never";
  const s = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
  if (s < 90) return "just now";
  if (s < 3600) return `${Math.round(s / 60)} minutes ago`;
  if (s < 86400) { const h = Math.round(s / 3600); return `${h} hour${h === 1 ? "" : "s"} ago`; }
  const d = Math.round(s / 86400);
  return `${d} day${d === 1 ? "" : "s"} ago`;
}

export function bytes(v: string | number | null | undefined): string {
  const n = Number(v ?? 0);
  if (!Number.isFinite(n) || n <= 0) return "0 B";
  const u = ["B", "KB", "MB", "GB", "TB"];
  const i = Math.min(u.length - 1, Math.floor(Math.log(n) / Math.log(1024)));
  return `${(n / 1024 ** i).toFixed(i === 0 ? 0 : 1)} ${u[i]}`;
}

/** "Every day at 2:00 AM", "Mon, Wed, Fri at 9:30 PM" from a schedule's days (0 = Sunday) and "HH:MM". */
export function describeSchedule(days: number[], time: string): string {
  const [h, m] = time.split(":").map(Number);
  const clock = `${h % 12 === 0 ? 12 : h % 12}:${String(m).padStart(2, "0")} ${h < 12 ? "AM" : "PM"}`;
  const names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  const who = days.length === 7 ? "Every day" : [...days].sort((a, b) => a - b).map((d) => names[d]).join(", ");
  return `${who} at ${clock}`;
}

/** An audit action in plain words. */
export function describeAction(action: string, detail: any): string {
  switch (action) {
    case "login": return "Signed in";
    case "policy.set": return "Changed what is backed up";
    case "schedule.set": return "Changed the backup schedule";
    case "job.backup_now": return "Started a backup";
    case "job.restore": {
      const n = Array.isArray(detail?.params?.items) ? detail.params.items.length : 0;
      return n ? `Restored ${n} ${n === 1 ? "item" : "items"}` : "Restored files";
    }
    case "job.find": case "catalog.search": return "Searched the backups";
    default: return action;
  }
}

export function when(iso: string | null | undefined): string {
  return iso ? new Date(iso).toLocaleString() : "never";
}
