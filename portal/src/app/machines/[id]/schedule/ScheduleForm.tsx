"use client";
import { useState } from "react";

const DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

// Times the platform itself is busy: the storage server takes its nightly snapshot at 06:00 and checks/cleans every
// repository from 10:00. A backup still works then, it is just slower, so this is advice and not a rule.
function advice(time: string): string | null {
  const [h, m] = time.split(":").map(Number); const t = h * 60 + m;
  if (t >= 5 * 60 + 40 && t <= 6 * 60 + 20) return "Around 6:00 AM the storage server takes its daily snapshot. It is safe, but an earlier time is better.";
  if (t >= 9 * 60 + 30 && t <= 11 * 60) return "Around 10:00 AM the backup server runs its daily checks and clean-up. It is safe, but an earlier or later time is better.";
  return null;
}

export default function ScheduleForm({ machineId, initialDays, initialTime }: { machineId: string; initialDays: number[]; initialTime: string }) {
  const [days, setDays] = useState<number[]>(initialDays);
  const [time, setTime] = useState(initialTime);
  const [saving, setSaving] = useState(false);
  const [status, setStatus] = useState<{ kind: "ok" | "bad"; text: string } | null>(null);
  const tip = /^\d\d:\d\d$/.test(time) ? advice(time) : null;

  const toggle = (d: number) => setDays((c) => (c.includes(d) ? c.filter((x) => x !== d) : [...c, d].sort()));

  async function save() {
    setSaving(true); setStatus(null);
    const res = await fetch(`/api/machines/${machineId}/schedule`, { method: "PUT", headers: { "content-type": "application/json" }, body: JSON.stringify({ days, time }) });
    setSaving(false);
    if (res.ok) setStatus({ kind: "ok", text: "Saved. The computer picks this up within a minute." });
    else setStatus({ kind: "bad", text: (await res.json().catch(() => ({}))).error || "Could not save." });
  }

  return (
    <div>
      {status && <div className={`banner ${status.kind === "bad" ? "bad" : "info"}`}>{status.text}</div>}
      <div className="card">
        <strong>Days</strong>
        <div className="row" style={{ margin: "8px 0 16px", gap: 16, flexWrap: "wrap" }}>
          {DAYS.map((n, i) => (
            <label key={n}><input type="checkbox" checked={days.includes(i)} onChange={() => toggle(i)} /> {n}</label>
          ))}
        </div>
        <label htmlFor="time"><strong>Time</strong></label>{" "}
        <input id="time" type="time" value={time} onChange={(e) => setTime(e.target.value)} />
        {tip && <p className="muted small">{tip}</p>}
        <div style={{ marginTop: 16 }}>
          <button className="primary" onClick={save} disabled={saving || days.length === 0 || !/^\d\d:\d\d$/.test(time)}>Save</button>
        </div>
      </div>
    </div>
  );
}
