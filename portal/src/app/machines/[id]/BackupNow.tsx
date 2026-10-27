"use client";
import { useEffect, useRef, useState } from "react";
import { runJob } from "@/lib/useJob";

export default function BackupNow({ machineId }: { machineId: string }) {
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState("");
  const [pct, setPct] = useState<number | null>(null);
  const timer = useRef<ReturnType<typeof setInterval> | null>(null);
  const sawProgress = useRef(false);

  useEffect(() => () => { if (timer.current) clearInterval(timer.current); }, []);

  async function start() {
    setBusy(true); setNote("Contacting the computer..."); setPct(null); sawProgress.current = false;
    try {
      await runJob(machineId, "backup_now", {}, { timeoutMs: 180_000 });
      setNote("Backup started. This can take a while on a large computer; you can leave this page.");
      timer.current = setInterval(async () => {
        const r = await fetch(`/api/machines/${machineId}`);
        if (!r.ok) return;
        const s = await r.json();
        const p = s.progress?.percent_done;
        if (typeof p === "number") { sawProgress.current = true; setPct(p); setNote(`Backing up... ${Math.round(p * 100)}%`); }
        else if (sawProgress.current) { setNote("Backup finished. Refresh the page to see the result."); setBusy(false); if (timer.current) clearInterval(timer.current); }
      }, 4000);
    } catch (e) { setNote((e as Error).message); setBusy(false); }
  }

  return (
    <div>
      <button className="primary" onClick={start} disabled={busy}>Back up now</button>
      {note && <div className="muted small" style={{ marginTop: 8 }}>{note}</div>}
      {pct !== null && <div className="bar" style={{ marginTop: 8 }}><div style={{ width: `${Math.round(pct * 100)}%` }} /></div>}
    </div>
  );
}
