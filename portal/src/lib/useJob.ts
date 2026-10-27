"use client";

/** Asks the machine's agent to do something and waits for the answer (the agent checks in about once a minute, faster while a page is open). */
export async function runJob<T = any>(machineId: string, type: string, params: unknown, opts: { timeoutMs?: number; onStatus?: (s: string) => void; onProgress?: (p: any) => void } = {}): Promise<T> {
  const res = await fetch(`/api/machines/${machineId}/jobs`, {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ type, params }),
  });
  if (!res.ok) throw new Error((await res.json().catch(() => ({}))).error || `request failed (${res.status})`);
  const { id } = await res.json();
  const deadline = Date.now() + (opts.timeoutMs ?? 240_000);
  let wait = 1000;
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, wait));
    wait = Math.min(wait + 500, 3000);
    const j = await fetch(`/api/jobs/${id}`);
    if (!j.ok) throw new Error("lost track of the request");
    const job = await j.json();
    opts.onStatus?.(job.status);
    if (job.progress) opts.onProgress?.(job.progress);
    if (job.status === "done") return job.result as T;
    if (job.status === "failed") throw new Error(job.error || "the computer could not do that");
    if (job.status === "expired") throw new Error("the computer did not answer in time. Is it switched on and online?");
  }
  throw new Error("the computer did not answer in time. Is it switched on and online?");
}

/** Keeps the agent in fast-polling mode while this page is open. */
export function startHeartbeat(machineId: string): () => void {
  const beat = () => { fetch(`/api/machines/${machineId}/heartbeat`, { method: "POST" }).catch(() => {}); };
  beat();
  const t = setInterval(beat, 60_000);
  return () => clearInterval(t);
}
