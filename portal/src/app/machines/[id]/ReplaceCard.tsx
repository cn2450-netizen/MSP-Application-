"use client";
import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { waitForJob } from "@/lib/useJob";

export type ReplacementView = { id: string; new_device: string; status: string; requested_by: string; requested_at: string; decided_by: string | null; message: string | null } | null;

// Moving a computer's backups to its replacement: ask, a second technician approves, the backup server does it, then
// the newest backup is restored onto the new computer.
export default function ReplaceCard({ machineId, machineName, me, rep, allowSelf }: { machineId: string; machineName: string; me: string; rep: ReplacementView; allowSelf: boolean }) {
  const router = useRouter();
  const [device, setDevice] = useState("");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ kind: "info" | "bad" | "ok"; text: string } | null>(null);
  const [pct, setPct] = useState<number | null>(null);

  // while the backup server is working on it, keep the page fresh
  useEffect(() => {
    if (!rep || !["approved", "running"].includes(rep.status)) return;
    const t = setInterval(() => router.refresh(), 5000);
    return () => clearInterval(t);
  }, [rep, router]);

  async function post(url: string, body?: unknown) {
    setBusy(true); setMsg(null);
    const res = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: body ? JSON.stringify(body) : undefined });
    const data = await res.json().catch(() => ({}));
    setBusy(false);
    if (!res.ok) { setMsg({ kind: "bad", text: data.error || "That did not work." }); return null; }
    router.refresh();
    return data;
  }

  async function restoreNewest() {
    if (!confirm(`Put the newest backup of ${machineName} onto the new computer, back in the original folders?\n\nFiles that already exist there are kept.`)) return;
    const d = await post(`/api/machines/${machineId}/restore-latest`);
    if (!d) return;
    setBusy(true); setPct(0); setMsg({ kind: "info", text: "Restoring from the newest backup..." });
    try {
      const r = await waitForJob<{ files: number }>(d.id, { timeoutMs: 6 * 3600_000, onProgress: (p) => { if (typeof p.percent_done === "number") setPct(p.percent_done); } });
      setMsg({ kind: "ok", text: `Done. ${r.files} files restored.` });
    } catch (e) { setMsg({ kind: "bad", text: (e as Error).message }); }
    setBusy(false); setPct(null);
  }

  const mine = rep?.requested_by === me;
  const canDecide = !mine || allowSelf;

  return (
    <div className="card">
      <h2 style={{ marginTop: 0 }}>Replace this computer</h2>
      {msg && <div className={`banner ${msg.kind === "bad" ? "bad" : "info"}`}>{msg.text}</div>}
      {pct !== null && <div className="bar" style={{ margin: "8px 0" }}><div style={{ width: `${Math.round(pct * 100)}%` }} /></div>}

      {(!rep || ["done", "rejected", "cancelled"].includes(rep.status)) && (
        <>
          {rep?.status === "done" && (
            <>
              <p>The backups of <strong>{machineName}</strong> now belong to <strong>{rep.new_device}</strong>, which keeps backing up into the same history. {rep.message && <span className="muted">{rep.message}</span>}</p>
              <button className="primary" onClick={restoreNewest} disabled={busy}>Restore the newest backup onto it</button>
              <p className="muted small">Until the files are back, its nightly backup will report a problem: that is expected.</p>
              <hr style={{ borderColor: "var(--line)" }} />
            </>
          )}
          {rep && rep.status !== "done" && <p className="muted small">The last request ({rep.new_device}) was {rep.status}.</p>}
          <p className="muted">If this computer has failed, point its backups at the new one. Install the monitoring agent on the new computer first, then enter its name. A second technician must approve.</p>
          <div className="row">
            <input type="text" value={device} onChange={(e) => setDevice(e.target.value.trim())} placeholder="New computer's name" style={{ width: 240 }} />
            <button onClick={async () => { if (device) await post(`/api/machines/${machineId}/replace`, { device }); }} disabled={busy || !device}>Request replacement</button>
          </div>
        </>
      )}

      {rep?.status === "pending" && (
        <>
          <p><strong>{rep.requested_by}</strong> asked to move the backups of <strong>{machineName}</strong> to <strong>{rep.new_device}</strong>. The old computer's backup login will stop working.</p>
          <div className="row">
            {canDecide ? (
              <>
                <button className="primary" onClick={() => post(`/api/replacements/${rep.id}`, { action: "approve" })} disabled={busy}>Approve</button>
                <button onClick={() => post(`/api/replacements/${rep.id}`, { action: "reject" })} disabled={busy}>Reject</button>
              </>
            ) : <span className="muted">Waiting for another technician to approve.</span>}
            {mine && <button onClick={() => post(`/api/replacements/${rep.id}`, { action: "cancel" })} disabled={busy}>Cancel request</button>}
          </div>
        </>
      )}

      {rep && ["approved", "running"].includes(rep.status) && (
        <p>Moving the backups of <strong>{machineName}</strong> to <strong>{rep.new_device}</strong> (approved by {rep.decided_by}). This takes a minute or two...</p>
      )}

      {rep?.status === "failed" && (
        <>
          <div className="banner bad">It did not finish: {rep.message || "unknown error"}</div>
          <div className="row">
            <button className="primary" onClick={() => post(`/api/replacements/${rep.id}`, { action: "retry" })} disabled={busy}>Try again</button>
            <button onClick={() => post(`/api/replacements/${rep.id}`, { action: "cancel" })} disabled={busy}>Cancel</button>
          </div>
        </>
      )}
    </div>
  );
}
