import { notFound, redirect } from "next/navigation";
import { getScope } from "@/lib/session";
import { getMachine, getSchedule } from "@/lib/data";
import ScheduleForm from "./ScheduleForm";

export const dynamic = "force-dynamic";

export default async function SchedulePage({ params }: { params: Promise<{ id: string }> }) {
  const scope = await getScope();
  if (!scope) redirect("/login");
  const m = await getMachine(scope, (await params).id);
  if (!m || !m.backup_enabled) notFound();
  const s = await getSchedule(m.id);
  return (
    <>
      <p className="small"><a href={`/machines/${m.id}`}>&larr; {m.display_name || m.name}</a></p>
      <h1>When to back up</h1>
      <p className="sub">Pick the days and the time that suit the business, for example after closing. Times are this computer&apos;s own clock. The computer needs to be switched on; if it is off at that time the backup runs when it next starts.</p>
      <ScheduleForm machineId={m.id} initialDays={s?.days ?? [0, 1, 2, 3, 4, 5, 6]} initialTime={s?.at_time ?? "02:00"} />
    </>
  );
}
