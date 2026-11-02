import { notFound, redirect } from "next/navigation";
import { getScope } from "@/lib/session";
import { canSee, isStaffFor } from "@/lib/authz";
import { env } from "@/lib/env";
import { getView } from "@/lib/view";
import { ago, bytes, when } from "@/lib/format";
import { loadFleet } from "@/lib/fleet";
import { RANGES, loadPerformance, rangeKey } from "@/lib/metrics";
import { loadPatches } from "@/lib/patches";
import { loadServices, loadRestarts, canRestart } from "@/lib/services";
import { requestRestart } from "./actions";
import { loadStuck } from "@/lib/agentupdate";
import { loadLogs, LOG_DAYS } from "@/lib/logs";
import { loadSignIns, SIGNIN_DAYS } from "@/lib/signins";
import Pager, { PAGE_SIZE, pageOf } from "../../../Pager";
import LineChart from "../../../LineChart";
import Gauge from "../../../Gauge";

export const dynamic = "force-dynamic";

// One computer: header, then the same facts the list shows, in full. Charts, events and Connect arrive in later steps.
export default async function ComputerPage({ params, searchParams }: { params: Promise<{ customer: string; host: string }>; searchParams: Promise<{ range?: string; spage?: string; cpage?: string; lpage?: string; ipage?: string }> }) {
  const scope = await getScope();
  if (!scope) redirect("/login");
  const { customer, host } = await params;
  const sp = await searchParams;
  const range = rangeKey(sp.range);
  // A computer you may not see answers 404, the same as one that does not exist.
  if (!/^[a-z0-9][a-z0-9-]{1,30}$/.test(customer) || !/^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$/.test(host) || !canSee(scope, customer)) notFound();

  const view = await getView(scope);
  const { rows } = await loadFleet(scope, { ...view, customer, site: "" });
  const r = rows.find((x) => x.slug === customer && x.host === host);
  if (!r) notFound();
  const staff = isStaffFor(scope, customer);
  const stuck = staff ? (await loadStuck()).get(`${customer}|${host}`) : undefined;
  const classic = env.legacyUrl;
  const [perf, patches, services, logs, signins] = await Promise.all([loadPerformance(customer, host, range), loadPatches(customer, host), loadServices(customer, host), loadLogs(customer, host), loadSignIns(customer, host)]);
  const restarts = await loadRestarts(customer, host);
  const spage = pageOf(sp.spage, services.rows.length), cpage = pageOf(sp.cpage, patches.rows.length), lpage = pageOf(sp.lpage, logs.rows.length), ipage = pageOf(sp.ipage, signins.rows.length);
  const num = (n: number) => (n > 1 ? String(n) : undefined);
  const path = `/computers/${customer}/${host}`;
  const keep = (o: Record<string, string | undefined>) => ({ range: range === "6h" ? undefined : range, ...o });
  const stopped = services.total - services.running;
  // backup gauge: full at a backup within a day, falling to empty at a week old
  const backupAge = r.m?.last_success ? (Date.now() - new Date(r.m.last_success).getTime()) / 86_400_000 : null;
  const backupFresh = backupAge === null ? null : Math.max(0, Math.min(100, 100 - ((backupAge - 1) / 6) * 100));
  const to = Date.now(), from = to - RANGES[range].ms, gapMs = RANGES[range].ms / 40;

  const drivePanel = (d: (typeof r.drives)[number]) => (
    <div className="panel" key={d.volume}>
      <h3>{staff && classic ? <a className="btn small" href={`${classic}/encryption?customer=${customer}&host=${host}&volume=${d.volume}`} title="Manage encryption and keys">Drive {d.volume}: encryption</a> : <>Drive {d.volume}: encryption</>} <span className="muted small">· {d.key_saved ? "key saved" : "no key saved"}</span></h3>
      <div className="body gauge-body"><Gauge percent={d.percent} label={`Drive ${d.volume} encryption`} caption={d.state.label} goodHigh /></div>
    </div>
  );

  return (
    <>
      <p className="small"><a href="/computers">← Computers</a></p>
      {stuck && <div className="banner warn">The monitoring agent on this computer could not be updated automatically ({stuck.failures} failed {stuck.failures === 1 ? "try" : "tries"}{stuck.reason ? `: ${stuck.reason}` : ""}). Automatic updates are paused for it until a technician clears it: <code>scripts/autoupdate-clear.sh {customer} {host}</code> on the server.</div>}
      <h1><span className={`dot ${r.online ? "ok" : "none"}`} />{r.name}</h1>
      <p className="sub">{r.customerName}{r.site !== "main" ? ` · ${r.site}` : ""} · {r.online ? "online now" : `last seen ${ago(r.lastSeen)}`}{r.m?.os_desc ? ` · ${r.m.os_desc}` : ""}</p>

      <div className="row perf-head">
        <h2 style={{ margin: 0 }}>Performance</h2>
        <span className="ranges">
          {(Object.keys(RANGES) as (keyof typeof RANGES)[]).map((k) => (
            <a key={k} className={`btn small${k === range ? " on" : ""}`} href={`?range=${k}`} aria-current={k === range ? "true" : undefined}>{RANGES[k].label}</a>
          ))}
        </span>
      </div>
      {perf.error && <div className="banner warn">{perf.error}</div>}
      <div className="gauges">
        <div className="panel"><h3>Processor</h3><div className="body gauge-body"><Gauge percent={perf.now.cpu} label="Processor use" caption="in use now" /></div></div>
        <div className="panel"><h3>Memory</h3><div className="body gauge-body"><Gauge percent={perf.now.memory} label="Memory use" caption="in use now" /></div></div>
        {perf.now.disk.map((d) => (
          <div className="panel" key={d.name}><h3>Disk {d.name}</h3><div className="body gauge-body"><Gauge percent={d.v} label={`Disk ${d.name} used`} caption="space used" /></div></div>
        ))}
      </div>
      <div className="gauges">
        {r.drives.length === 0 ? <div className="panel"><h3>Drive encryption</h3><div className="body muted">The monitoring agent has not reported any drives.</div></div> : drivePanel(r.drives[0])}
        <div className="panel"><h3>Services running</h3><div className="body gauge-body"><Gauge percent={services.total ? (services.running / services.total) * 100 : null} label="Automatic services running" caption={services.total ? `${services.running} of ${services.total} running` : "no data"} goodHigh /></div></div>
        <div className="panel"><h3>Updates installed OK</h3><div className="body gauge-body"><Gauge percent={patches.health} label="Update installs that succeeded" caption={patches.compliance.label} goodHigh /></div></div>
      </div>

      <div className="gauges">
        <div className="panel">
          <h3>{r.m && classic ? <a className="btn small" href={`${classic}/machines/${r.m.id}`} title="Browse, restore and schedule">Backup</a> : <>Backup</>} {r.m && <span className="muted small">· {r.backup!.label}</span>}</h3>
          <div className="body gauge-body"><Gauge percent={backupFresh} label="Backup freshness" caption={r.m ? (r.m.last_success ? `last good ${ago(r.m.last_success)}` : "no good backup yet") : "not set up"} goodHigh /></div>
        </div>
        {r.drives.slice(1).map(drivePanel)}
      </div>

      <h2 style={{ margin: "18px 0 10px" }}>History</h2>
      <div className="grid2">
        <div className="panel"><h3>Processor use</h3><div className="body"><LineChart title="Processor use" series={perf.cpu.map((s) => ({ ...s, label: "" }))} from={from} to={to} gapMs={gapMs} /></div></div>
        <div className="panel"><h3>Memory use</h3><div className="body"><LineChart title="Memory use" series={perf.memory.map((s) => ({ ...s, label: "" }))} from={from} to={to} gapMs={gapMs} /></div></div>
      </div>
      <div className="grid2">
        <div className="panel"><h3>Disk space used</h3><div className="body"><LineChart title="Disk space used" series={perf.disk} from={from} to={to} gapMs={gapMs} /></div></div>
        <div className="panel"><h3>Network traffic</h3><div className="body"><LineChart title="Network traffic" unit="Mbps" series={perf.network} from={from} to={to} gapMs={gapMs} /></div></div>
      </div>

      <div className="grid2">
        <div className="panel" id="services">
          <h3>Services (start automatically)</h3>
          <div className="body">
            {services.error ? <span className="muted">{services.error}</span> : services.total === 0 ? <span className="muted">No service list reported yet. The monitoring agent needs the latest update.</span>
              : <span className={`pill ${stopped ? "bad" : "ok"}`}>{stopped ? `${stopped} stopped` : "All running"}</span>}
          </div>
          {services.total > 0 && (
            <div className="scroll">
              <table>
                <thead><tr><th>Service</th><th>Status</th>{staff && <th />}</tr></thead>
                <tbody>
                  {services.rows.slice((spage - 1) * PAGE_SIZE, spage * PAGE_SIZE).map((s) => (
                    <tr key={s.name}>
                      <td>{s.display}</td>
                      <td><span className={`pill ${s.running ? "ok" : "bad"}`}>{s.running ? "Running" : "Stopped"}</span></td>
                      {staff && (
                        <td style={{ textAlign: "right", whiteSpace: "nowrap" }}>
                          {(() => {
                            const rq = restarts.get(s.name);
                            if (rq && (rq.status === "pending" || rq.status === "running")) return <span className="muted small" title={rq.message}>{rq.status === "running" ? "Working…" : "Requested…"}</span>;
                            return (
                              <>
                                {rq && <span className={`muted small`} title={rq.message} style={{ marginRight: 8 }}>{rq.status === "done" ? "restarted" : rq.status === "failed" ? `failed: ${rq.message}` : ""}</span>}
                                {canRestart(s.name) && (
                                  <form action={requestRestart} style={{ display: "inline" }}>
                                    <input type="hidden" name="customer" value={customer} /><input type="hidden" name="host" value={host} /><input type="hidden" name="service" value={s.name} />
                                    <button className="small" type="submit" title={s.running ? "Restart this service on the computer" : "Start this service on the computer"}>{s.running ? "Restart" : "Start"}</button>
                                  </form>
                                )}
                              </>
                            );
                          })()}
                        </td>
                      )}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
          <Pager total={services.rows.length} page={spage} path={path} pageKey="spage" hash="services" params={keep({ cpage: num(cpage), lpage: num(lpage), ipage: num(ipage) })} />
        </div>

        <div className="panel" id="patching">
          <h3>Compliance and update history</h3>
          <div className="body">
            <p><span className={`pill ${patches.compliance.key}`}>{patches.compliance.label}</span> <span className="muted small">{patches.compliance.detail}</span></p>
            {patches.lastInstall && <div className="kv"><span className="muted">Last update installed</span><span>{patches.lastInstall}</span></div>}
          </div>
          <div className="scroll">
            {patches.rows.length === 0 ? <div className="body muted">{patches.error ?? "No update history reported yet."}</div> : (
              <table>
                <thead><tr><th>Date</th><th>Update</th><th>Result</th></tr></thead>
                <tbody>
                  {patches.rows.slice((cpage - 1) * PAGE_SIZE, cpage * PAGE_SIZE).map((p, i) => (
                    <tr key={i}>
                      <td className="muted">{p.date}</td>
                      <td>{p.title}{p.operation !== "Install" && <span className="muted small"> ({p.operation})</span>}</td>
                      <td><span className={`pill ${p.result === "Succeeded" ? "ok" : p.result === "Failed" || p.result === "Aborted" ? "bad" : p.result === "SucceededWithErrors" ? "warn" : ""}`}>{p.result === "SucceededWithErrors" ? "With errors" : p.result}</span></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div>
          <Pager total={patches.rows.length} page={cpage} path={path} pageKey="cpage" hash="patching" params={keep({ spage: num(spage), lpage: num(lpage), ipage: num(ipage) })} />
        </div>
      </div>

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
        <Pager total={signins.rows.length} page={ipage} path={path} pageKey="ipage" hash="signins" params={keep({ spage: num(spage), cpage: num(cpage), lpage: num(lpage) })} />
      </div>

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
        <Pager total={logs.rows.length} page={lpage} path={path} pageKey="lpage" hash="logs" params={keep({ spage: num(spage), cpage: num(cpage), ipage: num(ipage) })} />
      </div>
    </>
  );
}
