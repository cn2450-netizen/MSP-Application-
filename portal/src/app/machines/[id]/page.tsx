import { notFound, redirect } from "next/navigation";
import { getScope } from "@/lib/session";
import { getMachine, getPolicy, getSchedule, recentJobs, health, currentReplacement } from "@/lib/data";
import { env } from "@/lib/env";
import ReplaceCard from "./ReplaceCard";
import { isStaffFor } from "@/lib/authz";
import { ago, bytes, when, describeSchedule } from "@/lib/format";
import BackupNow from "./BackupNow";
import Heartbeat from "./Heartbeat";

export const dynamic = "force-dynamic";

const JOB_LABEL: Record<string, string> = {
  backup_now: "Back up now", restore: "Restore files", find: "File search", list_snapshots: "Looked at backups",
  ls_snapshot: "Looked inside a backup", list_dirs: "Browsed folders",
};

export default async function MachinePage({ params }: { params: Promise<{ id: string }> }) {
  const scope = await getScope();
  if (!scope) redirect("/login");
  const m = await getMachine(scope, (await params).id);
  if (!m) notFound();
  const h = health(m);
  const policy = await getPolicy(m.id);
  const schedule = await getSchedule(m.id);
  const jobs = await recentJobs(m.id);
  const staff = isStaffFor(scope, m.customer_slug);
  const replacement = staff ? await currentReplacement(m.id) : null;
  const online = m.last_seen && Date.now() - new Date(m.last_seen).getTime() < 5 * 60_000;

  return (
    <>
      <Heartbeat machineId={m.id} />
      <p className="small"><a href="/">&larr; All computers</a></p>
      <div className="row">
        <div className="grow">
          <h1>{m.display_name || m.name}</h1>
          <p className="sub">{m.customer_name}{m.site_slug !== "main" ? ` · ${m.site_slug}` : ""} · {m.os_desc || "Windows"} · {online ? "online now" : `last seen ${ago(m.last_seen)}`}</p>
        </div>
        <span className={`pill ${h.key}`}>{h.label}</span>
      </div>

      <div className="card">
        <h2 style={{ marginTop: 0 }}>Last backup</h2>
        <table><tbody>
          <tr><td className="muted">Last good backup</td><td>{when(m.last_success)} ({ago(m.last_success)})</td></tr>
          <tr><td className="muted">Result of last run</td><td>{m.result === "ok" ? "Completed" : m.result === "partial" ? "Completed, but some files could not be read" : m.result === "failed" ? `Failed${m.message ? ` — ${m.message}` : ""}` : "No backup has run yet"}</td></tr>
          <tr><td className="muted">Size protected</td><td>{bytes(m.bytes_processed)}</td></tr>
          <tr><td className="muted">New since the one before</td><td>{bytes(m.data_added)}</td></tr>
        </tbody></table>
        <div style={{ marginTop: 14 }}><BackupNow machineId={m.id} /></div>
      </div>

      <div className="card">
        <h2 style={{ marginTop: 0 }}>What is backed up</h2>
        {policy ? (
          <ul style={{ margin: "0 0 12px", paddingLeft: 20 }}>{policy.include_paths.map((p) => <li key={p}>{p}</li>)}</ul>
        ) : (
          <p className="muted">Using the setup chosen when backup was installed. You can choose specific folders instead.</p>
        )}
        <a className="btn" href={`/machines/${m.id}/folders`}>Choose folders</a>
        {policy && <span className="muted small" style={{ marginLeft: 12 }}>Changed by {policy.updated_by}, {ago(policy.updated_at)}. Applies from the next backup.</span>}
      </div>

      <div className="card">
        <h2 style={{ marginTop: 0 }}>When it runs</h2>
        {schedule ? <p style={{ margin: "0 0 12px" }}>{describeSchedule(schedule.days, schedule.at_time)}</p>
                  : <p className="muted">Every night at a time picked when backup was installed. You can choose a time that suits the business.</p>}
        <a className="btn" href={`/machines/${m.id}/schedule`}>Change schedule</a>
        {schedule && <span className="muted small" style={{ marginLeft: 12 }}>Changed by {schedule.updated_by}, {ago(schedule.updated_at)}.</span>}
      </div>

      <div className="card">
        <h2 style={{ marginTop: 0 }}>Restore</h2>
        <p className="muted">Bring back files or folders from an earlier backup. They are put in a new folder on the computer, never over your current files.</p>
        <a className="btn primary" href={`/machines/${m.id}/restore`}>Restore files</a>
        {staff && <a className="btn" style={{ marginLeft: 8 }} href={`/machines/${m.id}/restore?mode=search`}>Search all backups</a>}
      </div>

      {staff && <ReplaceCard machineId={m.id} machineName={m.display_name || m.name} me={scope.username} rep={replacement} allowSelf={env.allowSelfApprove} />}

      <h2>Recent activity</h2>
      <div className="card">
        {jobs.length === 0 ? <span className="muted">Nothing yet.</span> : (
          <table><tbody>{jobs.map((j) => (
            <tr key={j.id}><td>{JOB_LABEL[j.type] ?? j.type}</td><td className="muted">{j.requested_by}</td><td className="muted">{ago(j.requested_at)}</td>
              <td>{j.status === "done" ? "Done" : j.status === "failed" ? `Failed${j.error ? `: ${j.error}` : ""}` : j.status === "expired" ? "Not picked up" : "In progress"}</td></tr>
          ))}</tbody></table>
        )}
      </div>
    </>
  );
}
