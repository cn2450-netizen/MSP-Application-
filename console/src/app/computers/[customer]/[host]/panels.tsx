import { env } from "@/lib/env";
import type { Logs } from "@/lib/logs";
import { LOG_DAYS } from "@/lib/logs";
import type { SignIns } from "@/lib/signins";
import { SIGNIN_DAYS } from "@/lib/signins";
import Pager, { PAGE_SIZE, pageOf } from "../../../Pager";

// The two panels that read Loki (about a second or two each). They are rendered inside <Suspense>, so the rest of the computer's
// page shows straight away and these fill in when their data arrives. The page starts both lookups first and passes the promises.
type Carry = { path: string; carry: Record<string, string | undefined> };

export async function SignInsPanel({ data, page: pageParam, path, carry }: Carry & { data: Promise<SignIns>; page?: string }) {
  const signins = await data;
  const ipage = pageOf(pageParam, signins.rows.length);
  return (
    <div className="panel" id="signins">
      <h3>Sign-ins (last {SIGNIN_DAYS} days)</h3>
      <div className="scroll">
        {signins.rows.length === 0 ? <div className="body muted">{signins.error ?? "No sign-in records yet. The monitoring agent needs the latest update (it starts collecting them once updated)."}</div> : (
          <table>
            <thead><tr><th>Time</th><th>What</th><th>User</th><th>How</th><th>From</th><th>Detail</th></tr></thead>
            <tbody>
              {signins.rows.slice((ipage - 1) * PAGE_SIZE, ipage * PAGE_SIZE).map((e, i) => (
                <tr key={i}>
                  <td className="muted" style={{ whiteSpace: "nowrap" }}>{new Date(e.t).toLocaleString()}</td>
                  <td><span className={`pill ${e.what === "Signed in" ? "ok" : e.what === "Signed out" ? "none" : e.what === "Locked out" ? "bad" : "warn"}`}>{e.what}</span></td>
                  <td>{e.user}</td>
                  <td className="muted">{e.how}</td>
                  <td className="muted">{e.from}</td>
                  <td className="muted small">{e.detail}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
      {signins.truncated && <p className="muted small" style={{ margin: "8px 16px" }}>Showing the newest events only.</p>}
      <Pager total={signins.rows.length} page={ipage} path={path} pageKey="ipage" hash="signins" params={carry} />
    </div>
  );
}

export async function LogsPanel({ data, page: pageParam, path, carry }: Carry & { data: Promise<Logs>; page?: string }) {
  const logs = await data;
  const lpage = pageOf(pageParam, logs.rows.length);
  return (
    <div className="panel" id="logs">
      <h3>Event log warnings and errors (last {LOG_DAYS} days)</h3>
      <div className="scroll">
        {logs.rows.length === 0 ? <div className="body muted">{logs.error ?? `No warnings or errors in the last ${LOG_DAYS} days.`}</div> : (
          <table>
            <thead><tr><th>Time</th><th>Level</th><th>Log</th><th>Source</th><th>Event</th><th>Message</th></tr></thead>
            <tbody>
              {logs.rows.slice((lpage - 1) * PAGE_SIZE, lpage * PAGE_SIZE).map((e, i) => (
                <tr key={i}>
                  <td className="muted" style={{ whiteSpace: "nowrap" }}>{new Date(e.t).toLocaleString()}</td>
                  <td><span className={`pill ${e.level === "Warning" ? "warn" : e.level === "Other" ? "none" : "bad"}`}>{e.level}</span></td>
                  <td className="muted">{e.channel}</td>
                  <td className="muted">{e.source}</td>
                  <td className="muted">{e.eventId}</td>
                  <td className="small">{e.message.length > 320 ? e.message.slice(0, 320) + "…" : e.message}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
      {env.grafanaUrl && <p className="muted small" style={{ margin: "8px 16px" }}>Older events (kept for a year) are in <a href={`${env.grafanaUrl}/explore`} target="_blank" rel="noreferrer">Grafana</a>: choose this company's logs there to review and export them.</p>}
      {logs.truncated && <p className="muted small" style={{ margin: "8px 16px" }}>Showing the newest {logs.rows.length} events.</p>}
      <Pager total={logs.rows.length} page={lpage} path={path} pageKey="lpage" hash="logs" params={carry} />
    </div>
  );
}

export const PanelFallback = ({ title }: { title: string }) => (
  <div className="panel"><h3>{title}</h3><div className="body muted">Loading…</div></div>
);
