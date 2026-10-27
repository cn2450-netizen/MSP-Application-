"use client";
import { useEffect, useRef, useState } from "react";
import { runJob, startHeartbeat } from "@/lib/useJob";

type Entry = { name: string; path: string };
type Node = { path: string; name: string; state: "idle" | "loading" | "loaded" | "error"; open: boolean; kids: string[]; err?: string };

const norm = (p: string) => (p.endsWith("\\") ? p : p + "\\").toLowerCase();
const covers = (a: string, b: string) => norm(b).startsWith(norm(a));   // a contains (or is) b

export default function FolderPicker({ machineId, initial }: { machineId: string; initial: string[] }) {
  const [nodes, setNodes] = useState<Record<string, Node>>({ "": { path: "", name: "This computer", state: "idle", open: true, kids: [] } });
  const [chosen, setChosen] = useState<string[]>(initial);
  const [status, setStatus] = useState<{ kind: "info" | "bad" | "ok"; text: string } | null>(null);
  const [saving, setSaving] = useState(false);
  const started = useRef(false);

  useEffect(() => startHeartbeat(machineId), [machineId]);

  async function load(path: string) {
    setNodes((n) => ({ ...n, [path]: { ...(n[path] ?? { path, name: path, kids: [], open: true }), state: "loading", open: true } }));
    try {
      const res = await runJob<{ entries: Entry[] }>(machineId, "list_dirs", { path });
      setNodes((n) => {
        const next = { ...n };
        for (const e of res.entries) next[e.path] = next[e.path] ?? { path: e.path, name: e.name, state: "idle", open: false, kids: [] };
        next[path] = { ...next[path], state: "loaded", open: true, kids: res.entries.map((e) => e.path) };
        return next;
      });
      setStatus(null);
    } catch (e) {
      setNodes((n) => ({ ...n, [path]: { ...n[path], state: "error", err: (e as Error).message } }));
    }
  }

  useEffect(() => {
    if (started.current) return; started.current = true;
    setStatus({ kind: "info", text: "Connecting to the computer. This can take up to a minute..." });
    load("");
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  function toggleOpen(p: string) {
    const n = nodes[p];
    if (n.state === "idle" || n.state === "error") load(p);
    else setNodes((all) => ({ ...all, [p]: { ...n, open: !n.open } }));
  }

  function toggleChosen(p: string) {
    setStatus(null);
    setChosen((c) => {
      if (c.some((x) => norm(x) === norm(p))) return c.filter((x) => norm(x) !== norm(p));
      if (c.some((x) => covers(x, p))) return c;                       // already inside a ticked folder
      return [...c.filter((x) => !covers(p, x)), p];                   // ticking a parent replaces its children
    });
  }

  async function save() {
    setSaving(true); setStatus(null);
    const res = await fetch(`/api/machines/${machineId}/policy`, { method: "PUT", headers: { "content-type": "application/json" }, body: JSON.stringify({ include: chosen }) });
    setSaving(false);
    if (res.ok) setStatus({ kind: "ok", text: "Saved. The computer picks this up within a minute and uses it from the next backup." });
    else setStatus({ kind: "bad", text: (await res.json().catch(() => ({}))).error || "Could not save." });
  }

  function render(p: string, depth: number): React.ReactNode {
    const n = nodes[p];
    if (!n) return null;
    const isRoot = p === "";
    const direct = chosen.some((x) => norm(x) === norm(p));
    const inherited = !direct && chosen.some((x) => covers(x, p));
    return (
      <li key={p || "root"}>
        {!isRoot && (
          <div className="node">
            <span className="twist" onClick={() => toggleOpen(p)}>{n.state === "loading" ? "…" : n.open && n.state === "loaded" ? "▾" : "▸"}</span>
            <input type="checkbox" checked={direct || inherited} disabled={inherited} onChange={() => toggleChosen(p)} aria-label={`Back up ${n.name}`} />
            <span>{n.name}</span>
            {n.state === "error" && <span className="muted small">— {n.err}</span>}
          </div>
        )}
        {isRoot && n.state === "error" && <div className="banner bad">{n.err} <button onClick={() => load("")}>Try again</button></div>}
        {n.open && n.state === "loaded" && n.kids.length > 0 && <ul className={`tree${isRoot ? " root" : ""}`}>{n.kids.map((k) => render(k, depth + 1))}</ul>}
        {n.open && n.state === "loaded" && n.kids.length === 0 && !isRoot && <div className="muted small" style={{ paddingLeft: 52 }}>No folders inside.</div>}
      </li>
    );
  }

  return (
    <div>
      {status && <div className={`banner ${status.kind === "bad" ? "bad" : status.kind === "ok" ? "info" : "info"}`}>{status.text}</div>}
      <div className="card"><ul className="tree root">{render("", 0)}</ul></div>
      <div className="card">
        <strong>Chosen for backup ({chosen.length})</strong>
        {chosen.length === 0 ? <p className="muted">Nothing chosen yet.</p> : <ul style={{ paddingLeft: 20 }}>{chosen.map((c) => <li key={c}>{c}</li>)}</ul>}
        <button className="primary" onClick={save} disabled={saving || chosen.length === 0}>Save</button>
      </div>
    </div>
  );
}
