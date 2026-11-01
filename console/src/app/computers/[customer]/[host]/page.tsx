import { notFound, redirect } from "next/navigation";
import { getScope } from "@/lib/session";
import { canSee, isStaffFor } from "@/lib/authz";
import { env } from "@/lib/env";
import { getView } from "@/lib/view";
import { ago, bytes, when } from "@/lib/format";
import { loadFleet } from "@/lib/fleet";
import { RANGES, loadPerformance, rangeKey } from "@/lib/metrics";
import LineChart from "../../../LineChart";
import Gauge from "../../../Gauge";

export const dynamic = "force-dynamic";

// One computer: header, then the same facts the list shows, in full. Charts, events and Connect arrive in later steps.
export default async function ComputerPage({ params, searchParams }: { params: Promise<{ customer: string; host: string }>; searchParams: Promise<{ range?: string }> }) {
  const scope = await getScope();
  if (!scope) redirect("/login");
  const { customer, host } = await params;
  const range = rangeKey((await searchParams).range);
  // A computer you may not see answers 404, the same as one that does not exist.
  if (!/^[a-z0-9][a-z0-9-]{1,30}$/.test(customer) || !/^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$/.test(host) || !canSee(scope, customer)) notFound();

  const view = await getView(scope);
  const { rows } = await loadFleet(scope, { ...view, customer, site: "" });
  const r = rows.find((x) => x.slug === customer && x.host === host);
  if (!r) notFound();
  const staff = isStaffFor(scope, customer);
  const classic = env.legacyUrl;
  const perf = await loadPerformance(customer, host, range);
  const to = Date.now(), from = to - RANGES[range].ms, gapMs = RANGES[range].ms / 40;

  return (
    <>
      <p className="small"><a href="/computers">← Computers</a></p>
      <h1><span className={`dot ${r.online ? "ok" : "none"}`} />{r.name}</h1>
      <p className="sub">{r.customerName}{r.site !== "main" ? ` · ${r.site}` : ""} · {r.online ? "online now" : `last seen ${ago(r.lastSeen)}`}{r.m?.os_desc ? ` · ${r.m.os_desc}` : ""}</p>

      <div className="grid2">
        <div className="panel">
          <h3>Drive encryption</h3>
          <div className="body">
            {r.drives.length === 0 ? <span className="muted">The monitoring agent has not reported any drives.</span> : <div className="enc-gauges">{r.drives.map((d) => (
              <div key={d.volume} className="enc-gauge-item">
                <Gauge percent={d.percent} label={`Drive ${d.volume} encryption`} caption={`Drive ${d.volume}:`} goodHigh />
                <div><span className={`pill ${d.state.key}`}>{d.state.label}</span> <span className="muted small">{d.key_saved ? "key saved" : "no key saved"}</span></div>
              </div>
            ))}</div>}
            {staff && r.drives.length > 0 && classic && <p><a className="btn small" href={`${classic}/encryption?customer=${customer}&host=${host}&volume=${r.drives[0].volume}`}>Manage encryption and keys</a></p>}
          </div>
        </div>

        <div className="panel">
          <h3>Backup</h3>
          <div className="body">
            {r.m ? (
              <>
                <p><span className={`pill ${r.backup!.key}`}>{r.backup!.label}</span></p>
                <div className="kv"><span className="muted">Last good backup</span><span title={when(r.m.last_success)}>{ago(r.m.last_success)}</span></div>
                <div className="kv"><span className="muted">Data protected</span><span>{r.m.bytes_processed ? bytes(r.m.bytes_processed) : "none yet"}</span></div>
                {classic && <p><a className="btn small" href={`${classic}/machines/${r.m.id}`}>Browse, restore and schedule</a></p>}
              </>
            ) : <span className="muted">This computer is not set up for backup.</span>}
          </div>
        </div>
      </div>
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
      <h2 style={{ margin: "18px 0 10px" }}>History</h2>
      <div className="grid2">
        <div className="panel"><h3>Processor use</h3><div className="body"><LineChart title="Processor use" series={perf.cpu.length ? perf.cpu.map((s) => ({ ...s, label: "" })) : []} from={from} to={to} gapMs={gapMs} /></div></div>
        <div className="panel"><h3>Memory use</h3><div className="body"><LineChart title="Memory use" series={perf.memory.map((s) => ({ ...s, label: "" }))} from={from} to={to} gapMs={gapMs} /></div></div>
      </div>
      <div className="panel"><h3>Disk space used</h3><div className="body"><LineChart title="Disk space used" series={perf.disk} from={from} to={to} gapMs={gapMs} /></div></div>
    </>
  );
}
