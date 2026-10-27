"use client";
import { useEffect, useRef, useState } from "react";
import { runJob, startHeartbeat } from "@/lib/useJob";
import FolderChooser from "./FolderChooser";

type Snap = { id: string; time: string; host: string; paths: string[] };
type Entry = { name: string; path: string; type: "dir" | "file"; size: number };
type Node = { path: string; state: "idle" | "loading" | "loaded" | "error"; open: boolean; kids: Entry[]; err?: string };
type Hit = { snapshot: string; path: string; type: string; size: number; mtime?: string | null };

// Browsing and searching read the portal's catalog, which answers at once. Only a machine that has no catalogued backup yet
// (its first backup finished minutes ago) falls back to asking the computer, which can take a minute.
async function fromCatalog<T>(machineId: string, query: string): Promise<T> {
  const res = await fetch(`/api/machines/${machineId}/catalog?${query}`);
  if (!res.ok) throw new Error((await res.json().catch(() => ({}))).error || `request failed (${res.status})`);
  return res.json();
}

const size = (n: number) => { if (!n) return ""; const u = ["B", "KB", "MB", "GB", "TB"]; const i = Math.min(4, Math.floor(Math.log(n) / Math.log(1024))); return `${(n / 1024 ** i).toFixed(i ? 1 : 0)} ${u[i]}`; };
const inside = (a: string, b: string) => b === a || b.startsWith(a.endsWith("/") ? a : a + "/");   // a contains b
const nice = (p: string) => { const m = /^\/([A-Za-z])(\/.*)?$/.exec(p); return m ? `${m[1].toUpperCase()}:${(m[2] ?? "/").replace(/\//g, "\\")}` : p; };

export default function RestoreBrowser({ machineId, machineName, mode, staff }: { machineId: string; machineName: string; mode: "browse" | "search"; staff: boolean }) {
  const [target, setTarget] = useState<"safe" | "folder" | "original">("safe");
  const [folder, setFolder] = useState("");
  const [replace, setReplace] = useState(false);
  const [snaps, setSnaps] = useState<Snap[] | null>(null);
  const [snap, setSnap] = useState<string>("");
  const [nodes, setNodes] = useState<Record<string, Node>>({});
  const [chosen, setChosen] = useState<string[]>([]);
  const [msg, setMsg] = useState<{ kind: "info" | "bad" | "ok"; text: string } | null>({ kind: "info", text: "Loading backups..." });
  const [live, setLive] = useState(false);
  const [hits, setHits] = useState<Hit[] | null>(null);
  const [q, setQ] = useState("");
  const [busy, setBusy] = useState(false);
  const [pct, setPct] = useState<number | null>(null);
  const started = useRef(false);

  useEffect(() => startHeartbeat(machineId), [machineId]);
  useEffect(() => {
    if (started.current) return; started.current = true;
    fromCatalog<{ snapshots: Snap[] }>(machineId, "view=snapshots")
      .then(async (r) => {
        if (r.snapshots.length) return r;
        setLive(true); setMsg({ kind: "info", text: "Connecting to the computer. This can take up to a minute..." });
        return runJob<{ snapshots: Snap[] }>(machineId, "list_snapshots", {});
      })
      .then((r) => { setSnaps(r.snapshots); setMsg(r.snapshots.length ? null : { kind: "info", text: "There are no backups of this computer yet." }); if (r.snapshots[0]) setSnap(r.snapshots[0].id); })
      .catch((e) => setMsg({ kind: "bad", text: e.message }));
  }, [machineId]);

  async function load(path: string, sid = snap) {
    const key = `${sid}|${path}`;
    setNodes((n) => ({ ...n, [key]: { path, state: "loading", open: true, kids: n[key]?.kids ?? [] } }));
    try {
      const r = live ? await runJob<{ entries: Entry[] }>(machineId, "ls_snapshot", { snapshot: sid, path })
                     : await fromCatalog<{ entries: Entry[] }>(machineId, `view=ls&snapshot=${encodeURIComponent(sid)}&path=${encodeURIComponent(path)}`);
      const kids = [...r.entries].sort((a, b) => (a.type === b.type ? a.name.localeCompare(b.name) : a.type === "dir" ? -1 : 1));
      setNodes((n) => ({ ...n, [key]: { path, state: "loaded", open: true, kids } }));
      setMsg(null);
    } catch (e) { setNodes((n) => ({ ...n, [key]: { path, state: "error", open: true, kids: [], err: (e as Error).message } })); }
  }

  useEffect(() => { if (mode === "browse" && snap) { setChosen([]); load("/", snap); } }, [snap, mode]); // eslint-disable-line react-hooks/exhaustive-deps

  function toggle(p: string) {
    setMsg(null);
    setChosen((c) => c.includes(p) ? c.filter((x) => x !== p) : c.some((x) => inside(x, p)) ? c : c.length >= 50 ? c : [...c.filter((x) => !inside(p, x)), p]);
  }

  async function search() {
    if (!q.trim()) return;
    setBusy(true); setHits(null); setChosen([]); setMsg({ kind: "info", text: live ? "Searching every backup. This can take a minute..." : "Searching..." });
    try { const r = live ? await runJob<{ hits: Hit[]; truncated: boolean }>(machineId, "find", { pattern: q.trim() }, { timeoutMs: 600_000 })
                         : await fromCatalog<{ hits: Hit[]; truncated: boolean }>(machineId, `view=search&q=${encodeURIComponent(q.trim())}`); setHits(r.hits); setMsg(r.hits.length ? (r.truncated ? { kind: "info", text: "Showing the first 500 matches. Narrow the search to see others." } : null) : { kind: "info", text: "No files with that name were found in any backup." }); }
    catch (e) { setMsg({ kind: "bad", text: (e as Error).message }); }
    setBusy(false);
  }

  const searchSnap = hits && chosen.length ? hits.find((h) => chosen.includes(h.path))?.snapshot : undefined;
  const restoreSnap = mode === "search" ? searchSnap : snap;

  async function restore() {
    if (!restoreSnap || chosen.length === 0) return;
    if (target === "folder" && !folder) { setMsg({ kind: "bad", text: "Choose the folder to restore into." }); return; }
    const when = snaps?.find((s) => s.id === restoreSnap || restoreSnap.startsWith(s.id));
    const where = target === "safe" ? "They will be put in a new folder; nothing is overwritten."
      : target === "folder" ? `They will be put in ${folder}. ${replace ? "Files that already exist there WILL BE REPLACED." : "Files that already exist there are kept."}`
      : `They will be put back in their original locations. ${replace ? "Files that already exist WILL BE REPLACED." : "Files that already exist are kept."}`;
    if (!confirm(`Restore ${chosen.length} item${chosen.length === 1 ? "" : "s"} from the backup of ${when ? new Date(when.time).toLocaleString() : restoreSnap} onto ${machineName}?\n\n${where}`)) return;
    setBusy(true); setPct(0); setMsg({ kind: "info", text: "Contacting the computer..." });
    try {
      const params = { snapshot: restoreSnap, items: chosen, ...(target !== "safe" ? { target, overwrite: replace ? "always" : "never" } : {}), ...(target === "folder" ? { folder } : {}) };
      const r = await runJob<{ target: string; files: number }>(machineId, "restore", params, {
        timeoutMs: 6 * 3600_000, onStatus: (s) => { if (s === "running") setMsg({ kind: "info", text: "Restoring..." }); },
        onProgress: (p) => { if (typeof p.percent_done === "number") setPct(p.percent_done); },
      });
      setMsg({ kind: "ok", text: `Done. ${r.files} file${r.files === 1 ? "" : "s"} restored to ${r.target} on ${machineName}.${target === "safe" ? " An administrator can open that folder." : ""}` });
      setChosen([]);
    } catch (e) { setMsg({ kind: "bad", text: (e as Error).message }); }
    setBusy(false); setPct(null);
  }

  function row(e: Entry, depth: number): React.ReactNode {
    const key = `${snap}|${e.path}`; const n = nodes[key];
    const direct = chosen.includes(e.path); const inh = !direct && chosen.some((x) => inside(x, e.path));
    return (
      <li key={e.path}>
        <div className="node">
          {e.type === "dir" ? <span className="twist" onClick={() => (!n || n.state === "idle" || n.state === "error" ? load(e.path) : setNodes((a) => ({ ...a, [key]: { ...n, open: !n.open } })))}>{n?.state === "loading" ? "…" : n?.open && n.state === "loaded" ? "▾" : "▸"}</span> : <span className="twist" />}
          <input type="checkbox" checked={direct || inh} disabled={inh} onChange={() => toggle(e.path)} aria-label={`Restore ${e.name}`} />
          <span>{e.name}</span>{e.type === "file" && <span className="muted small">{size(e.size)}</span>}
          {n?.state === "error" && <span className="muted small">— {n.err}</span>}
        </div>
        {n?.open && n.state === "loaded" && (n.kids.length ? <ul className="tree">{n.kids.map((k) => row(k, depth + 1))}</ul> : <div className="muted small" style={{ paddingLeft: 52 }}>Empty.</div>)}
      </li>
    );
  }

  const root = nodes[`${snap}|/`];
  return (
    <div>
      {msg && <div className={`banner ${msg.kind === "bad" ? "bad" : "info"}`}>{msg.text}</div>}
      {pct !== null && <div className="bar" style={{ margin: "8px 0" }}><div style={{ width: `${Math.round(pct * 100)}%` }} /></div>}

      {mode === "browse" && snaps && snaps.length > 0 && (
        <>
          <div className="card row">
            <label htmlFor="snap"><strong>Restore from</strong></label>
            <select id="snap" value={snap} onChange={(e) => setSnap(e.target.value)} disabled={busy}>
              {snaps.map((s) => <option key={s.id} value={s.id}>{new Date(s.time).toLocaleString()}</option>)}
            </select>
            <span className="muted small">{snaps.length} backup{snaps.length === 1 ? "" : "s"} available (newest first)</span>
          </div>
          <div className="card">
            {root?.state === "loaded" && <ul className="tree root">{root.kids.map((k) => row(k, 0))}</ul>}
            {root?.state === "error" && <div className="banner bad">{root.err} <button onClick={() => load("/")}>Try again</button></div>}
          </div>
        </>
      )}

      {mode === "search" && (
        <>
          <div className="card row">
            <input type="search" placeholder="File name, e.g. budget or *.xlsx" value={q} onChange={(e) => setQ(e.target.value)} onKeyDown={(e) => e.key === "Enter" && search()} style={{ minWidth: 280 }} />
            <button className="primary" onClick={search} disabled={busy || !snaps}>Search</button>
          </div>
          {hits && hits.length > 0 && (
            <div className="card">
              <table><thead><tr><th /><th>File</th><th>Last changed</th><th>Newest backup with it</th><th>Size</th></tr></thead><tbody>
                {hits.map((h) => {
                  const when = snaps?.find((s) => s.id === h.snapshot);
                  const disabled = !!searchSnap && searchSnap !== h.snapshot;
                  return <tr key={h.snapshot + h.path}><td><input type="checkbox" checked={chosen.includes(h.path) && searchSnap === h.snapshot} disabled={disabled} onChange={() => toggle(h.path)} /></td><td>{nice(h.path)}</td><td className="muted">{h.mtime ? new Date(h.mtime).toLocaleString() : ""}</td><td className="muted">{when ? new Date(when.time).toLocaleString() : h.snapshot}</td><td className="muted">{size(h.size)}</td></tr>;
                })}
              </tbody></table>
              <p className="muted small">Tick files from one backup at a time.</p>
            </div>
          )}
        </>
      )}

      {chosen.length > 0 && (
        <div className="card">
          <div><strong>{chosen.length} selected</strong><div className="muted small">{chosen.slice(0, 3).map(nice).join(", ")}{chosen.length > 3 ? ` and ${chosen.length - 3} more` : ""}</div></div>
          <h3 style={{ margin: "14px 0 6px", fontSize: 15 }}>Where should they go?</h3>
          <label style={{ display: "block", margin: "4px 0" }}><input type="radio" name="target" checked={target === "safe"} onChange={() => setTarget("safe")} disabled={busy} />{" "}
            A new folder on the computer <span className="muted small">(safest; only an administrator can open it)</span></label>
          <label style={{ display: "block", margin: "4px 0" }}><input type="radio" name="target" checked={target === "folder"} onChange={() => setTarget("folder")} disabled={busy} />{" "}
            A folder I choose</label>
          {staff && <label style={{ display: "block", margin: "4px 0" }}><input type="radio" name="target" checked={target === "original"} onChange={() => setTarget("original")} disabled={busy} />{" "}
            Back where they came from <span className="muted small">(technicians only)</span></label>}
          {target === "folder" && <FolderChooser machineId={machineId} onChange={setFolder} />}
          {target !== "safe" && (
            <label style={{ display: "block", margin: "8px 0" }}><input type="checkbox" checked={replace} onChange={(e) => setReplace(e.target.checked)} disabled={busy} />{" "}
              Replace files that already exist there <span className="muted small">(otherwise they are left alone)</span></label>
          )}
          <div style={{ marginTop: 12 }}>
            <button className="primary" onClick={restore} disabled={busy || !restoreSnap || (target === "folder" && !folder)}>Restore</button>
          </div>
        </div>
      )}
    </div>
  );
}
