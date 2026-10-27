"use client";
import { useEffect, useState } from "react";
import { runJob } from "@/lib/useJob";

type Dir = { name: string; path: string };

/** Pick one folder on the computer (live, from the computer itself). The person may add a new folder name on the end. */
export default function FolderChooser({ machineId, onChange }: { machineId: string; onChange: (folder: string) => void }) {
  const [trail, setTrail] = useState<Dir[]>([]);              // folders opened so far, from the drive down
  const [kids, setKids] = useState<Dir[]>([]);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [extra, setExtra] = useState("");

  const here = trail.length ? trail[trail.length - 1].path : "";
  const full = here ? `${here.replace(/\\+$/, "")}${extra.trim() ? `\\${extra.trim()}` : ""}` : "";

  async function open(path: string, name: string, nextTrail: Dir[]) {
    setLoading(true); setErr(null);
    try {
      const r = await runJob<{ entries: Dir[] }>(machineId, "list_dirs", { path });
      setKids(r.entries); setTrail(nextTrail); setExtra("");
    } catch (e) { setErr((e as Error).message); }
    setLoading(false);
  }

  useEffect(() => { open("", "This computer", []); }, []); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { onChange(full); }, [full]); // eslint-disable-line react-hooks/exhaustive-deps

  return (
    <div className="card" style={{ margin: "8px 0" }}>
      <div className="small" style={{ marginBottom: 8 }}>
        <a href="#" onClick={(e) => { e.preventDefault(); open("", "This computer", []); }}>This computer</a>
        {trail.map((t, i) => (
          <span key={t.path}> &rsaquo; <a href="#" onClick={(e) => { e.preventDefault(); open(t.path, t.name, trail.slice(0, i + 1)); }}>{t.name}</a></span>
        ))}
      </div>
      {err && <div className="banner bad">{err}</div>}
      {loading ? <div className="muted small">Loading...</div> : (
        <ul className="tree root">
          {kids.map((k) => (
            <li key={k.path}><div className="node"><span className="twist">&#128193;</span>
              <a href="#" onClick={(e) => { e.preventDefault(); open(k.path, k.name, [...trail, k]); }}>{k.name}</a></div></li>
          ))}
          {kids.length === 0 && <li className="muted small">No folders inside.</li>}
        </ul>
      )}
      {here && (
        <div style={{ marginTop: 10 }}>
          <label className="small">Put the files in <strong>{here}</strong>, or in a new folder inside it named:{" "}
            <input type="text" value={extra} onChange={(e) => setExtra(e.target.value.replace(/[\\/:*?"<>|]/g, ""))} placeholder="(optional)" style={{ width: 200 }} />
          </label>
          <div className="muted small" style={{ marginTop: 4 }}>Chosen: <strong>{full}</strong></div>
        </div>
      )}
    </div>
  );
}
