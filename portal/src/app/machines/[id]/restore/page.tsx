import { notFound, redirect } from "next/navigation";
import { getScope } from "@/lib/session";
import { getMachine } from "@/lib/data";
import { isStaffFor } from "@/lib/authz";
import RestoreBrowser from "./RestoreBrowser";

export const dynamic = "force-dynamic";

export default async function RestorePage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ mode?: string }> }) {
  const scope = await getScope();
  if (!scope) redirect("/login");
  const m = await getMachine(scope, (await params).id);
  if (!m || !m.backup_enabled) notFound();
  const staff = isStaffFor(scope, m.customer_slug);
  const mode = (await searchParams).mode === "search" && staff ? "search" : "browse";
  return (
    <>
      <p className="small"><a href={`/machines/${m.id}`}>&larr; {m.display_name || m.name}</a></p>
      <h1>{mode === "search" ? "Search all backups" : "Restore files"}</h1>
      <p className="sub">
        {mode === "search"
          ? "Find a file by name across every backup of this computer, then restore it."
          : "Pick a date, tick what you need, and it is put back in a new folder on the computer. Nothing is overwritten."}
        {staff && mode === "browse" && <> <a href={`/machines/${m.id}/restore?mode=search`}>Search by file name instead</a>.</>}
        {mode === "search" && <> <a href={`/machines/${m.id}/restore`}>Browse by date instead</a>.</>}
      </p>
      <RestoreBrowser machineId={m.id} machineName={m.display_name || m.name} mode={mode} staff={staff} />
    </>
  );
}
