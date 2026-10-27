import { notFound, redirect } from "next/navigation";
import { getScope } from "@/lib/session";
import { getMachine, getPolicy } from "@/lib/data";
import FolderPicker from "./FolderPicker";

export const dynamic = "force-dynamic";

export default async function FoldersPage({ params }: { params: Promise<{ id: string }> }) {
  const scope = await getScope();
  if (!scope) redirect("/login");
  const m = await getMachine(scope, (await params).id);
  if (!m || !m.backup_enabled) notFound();
  const policy = await getPolicy(m.id);
  return (
    <>
      <p className="small"><a href={`/machines/${m.id}`}>&larr; {m.display_name || m.name}</a></p>
      <h1>Choose what to back up</h1>
      <p className="sub">Tick the folders you want protected. Ticking a folder includes everything inside it. Windows itself and installed programs are never backed up (they can be reinstalled).</p>
      <FolderPicker machineId={m.id} initial={policy?.include_paths ?? []} />
    </>
  );
}
