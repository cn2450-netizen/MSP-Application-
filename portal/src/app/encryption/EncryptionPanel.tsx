"use client";
import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";

type Key = { id: string; customer_slug: string; company: string; host: string; volume: string; protector_id: string; collected_at: string };
type Req = {
  id: string; customer_slug: string; company: string; host: string; volume: string; action: "enable" | "escrow";
  status: "pending" | "running" | "done" | "failed" | "cancelled"; requested_by: string; requested_at: string; message: string | null; finished_at: string | null;
};

const when = (s: string) => new Date(s).toLocaleString();
const STATUS: Record<Req["status"], string> = { pending: "Waiting", running: "Working", done: "Done", failed: "Failed", cancelled: "Cancelled" };

export default function EncryptionPanel(p: { customer: string | null; filter: string | null; host: string | null; volume: string | null; companyName: string | null; customers: { slug: string; name: string }[]; defaultCustomer: string; keys: Key[]; requests: Req[] }) {
  const router = useRouter();
  const [vol, setVol] = useState(p.volume ?? "");
  const [pickCust, setPickCust] = useState(p.defaultCustomer || p.customers[0]?.slug || "");
  const [pickHost, setPickHost] = useState("");
  const customer = p.customer ?? pickCust;
  const host = p.host ?? pickHost.trim().toLowerCase().replace(/[^a-z0-9-]/g, "");
  const [msg, setMsg] = useState<{ kind: "info" | "bad"; text: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const [reveal, setReveal] = useState<{ id: string; reason: string } | null>(null);
  const [shown, setShown] = useState<{ id: string; key: string } | null>(null);

  // while something is waiting or running, look again every few seconds
  const open = p.requests.some((r) => r.status === "pending" || r.status === "running");
  useEffect(() => {
    if (!open) return;
    const t = setInterval(() => router.refresh(), 4000);
    return () => clearInterval(t);
  }, [open, router]);

  // the recovery key is on screen only briefly
  useEffect(() => {
    if (!shown) return;
    const t = setTimeout(() => setShown(null), 60_000);
    return () => clearTimeout(t);
  }, [shown]);

  async function call(url: string, body: object): Promise<any | null> {
    setBusy(true); setMsg(null);
    try {
      const res = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
      const j = await res.json().catch(() => ({}));
      if (!res.ok) { setMsg({ kind: "bad", text: j.error || "That did not work." }); return null; }
      return j;
    } finally { setBusy(false); }
  }

  async function request(action: "enable" | "escrow") {
    if (!customer || !host || !/^[A-Za-z]$/.test(vol)) return;
    const ok = action === "enable"
      ? confirm(`Turn on BitLocker for drive ${vol.toUpperCase()}: on ${host}?\n\nThe drive is encrypted in the background (used space only) and the recovery key is saved here. A computer without a working TPM cannot encrypt its Windows drive this way.`)
      : true;
    if (!ok) return;
    const j = await call("/api/bitlocker/requests", { customer, host, volume: vol, action });
    if (j) { setMsg({ kind: "info", text: "Requested. The computer is contacted within a minute." }); router.refresh(); }
  }

  async function decide(id: string, action: "cancel" | "retry") {
    if (await call(`/api/bitlocker/requests/${id}`, { action })) router.refresh();
  }

  async function doReveal() {
    if (!reveal) return;
    const j = await call(`/api/bitlocker/keys/${reveal.id}/reveal`, { reason: reveal.reason });
    if (j) { setShown({ id: reveal.id, key: j.key }); setReveal(null); }
  }

  const showCompany = !p.customer && !p.filter;
  return (
    <>
      {msg && <div className={`banner ${msg.kind}`}>{msg.text}</div>}

      {(p.customers.length > 0) && (
        <div className="card">
          {!p.host && (
            <div className="row" style={{ marginBottom: 12, gap: 12, flexWrap: "wrap" }}>
              <label>Company{" "}
                <select value={pickCust} onChange={(e) => setPickCust(e.target.value)}>
                  {p.customers.map((c) => <option key={c.slug} value={c.slug}>{c.name}</option>)}
                </select>
              </label>
              <label>Computer name{" "}
                <input value={pickHost} onChange={(e) => setPickHost(e.target.value)} placeholder="e.g. DESKTOP-UJPN596" />
              </label>
            </div>
          )}
          <strong>Drive</strong>{" "}
          <input value={vol} onChange={(e) => setVol(e.target.value.replace(/[^A-Za-z]/g, "").slice(0, 1).toUpperCase())} size={2} aria-label="Drive letter" style={{ width: 40, textAlign: "center" }} /> :
          <div className="row" style={{ marginTop: 12, gap: 8, flexWrap: "wrap" }}>
            <button className="primary" disabled={busy || !vol || !host} onClick={() => request("enable")}>Turn on BitLocker</button>
            <button disabled={busy || !vol || !host} onClick={() => request("escrow")}>Save the recovery key</button>
          </div>
          <p className="muted small" style={{ marginBottom: 0 }}>
            &ldquo;Turn on&rdquo; encrypts the drive and saves its recovery key. &ldquo;Save the recovery key&rdquo; is for a drive that is already encrypted: it reads the key from the computer (adding one if the drive has none) and stores it here.
          </p>
        </div>
      )}

      <div className="panel">
        <h3>Saved recovery keys</h3>
        <div className="scroll">
          {p.keys.length === 0 ? <div className="body muted">No recovery keys saved{p.host ? " for this computer" : ""} yet.</div> : (
            <table>
              <thead><tr>{showCompany && <th>Company</th>}{!p.host && <th>Computer</th>}<th>Drive</th><th>Key ID</th><th>Saved</th><th /></tr></thead>
              <tbody>
                {p.keys.map((k) => (
                  <tr key={k.id}>
                    {showCompany && <td>{k.company}</td>}
                    {!p.host && <td>{k.host}</td>}
                    <td>{k.volume}:</td>
                    <td className="muted small" style={{ fontFamily: "monospace" }}>{k.protector_id.slice(1, 9).toUpperCase()}</td>
                    <td className="muted">{when(k.collected_at)}</td>
                    <td>
                      {shown?.id === k.id ? (
                        <span>
                          <code style={{ fontSize: 15, userSelect: "all" }}>{shown.key}</code>{" "}
                          <button className="small" onClick={() => navigator.clipboard?.writeText(shown.key)}>Copy</button>{" "}
                          <button className="small" onClick={() => setShown(null)}>Hide</button>
                        </span>
                      ) : reveal?.id === k.id ? (
                        <span>
                          <input autoFocus placeholder="Why do you need it?" value={reveal.reason} onChange={(e) => setReveal({ id: k.id, reason: e.target.value })}
                                 onKeyDown={(e) => { if (e.key === "Enter") doReveal(); }} style={{ width: 220 }} />{" "}
                          <button className="small primary" disabled={busy || reveal.reason.trim().length < 3} onClick={doReveal}>Show</button>{" "}
                          <button className="small" onClick={() => setReveal(null)}>Cancel</button>
                        </span>
                      ) : <button className="small" onClick={() => setReveal({ id: k.id, reason: "" })}>Show key</button>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
        <p className="muted small" style={{ margin: "8px 16px" }}>The Windows recovery screen shows the first 8 characters of the Key ID, so you can match it to the right key. Every time a key is shown, who and why is logged.</p>
      </div>

      <div className="panel">
        <h3>Requests</h3>
        <div className="scroll">
          {p.requests.length === 0 ? <div className="body muted">None yet.</div> : (
            <table>
              <thead><tr>{showCompany && <th>Company</th>}{!p.host && <th>Computer</th>}<th>Drive</th><th>What</th><th>Status</th><th>By</th><th>When</th><th /></tr></thead>
              <tbody>
                {p.requests.map((r) => (
                  <tr key={r.id}>
                    {showCompany && <td>{r.company}</td>}
                    {!p.host && <td>{r.host}</td>}
                    <td>{r.volume}:</td>
                    <td>{r.action === "enable" ? "Turn on BitLocker" : "Save recovery key"}</td>
                    <td>
                      <span className={`pill ${r.status === "done" ? "ok" : r.status === "failed" ? "bad" : ""}`}>{STATUS[r.status]}</span>
                      {r.message && <div className="muted small">{r.message}</div>}
                    </td>
                    <td className="muted">{r.requested_by}</td>
                    <td className="muted">{when(r.requested_at)}</td>
                    <td>
                      {(r.status === "pending" || r.status === "failed") && <button className="small" disabled={busy} onClick={() => decide(r.id, "cancel")}>Cancel</button>}{" "}
                      {r.status === "failed" && <button className="small" disabled={busy} onClick={() => decide(r.id, "retry")}>Try again</button>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      </div>
    </>
  );
}
