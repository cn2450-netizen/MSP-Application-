import { z } from "zod";

// Everything a user can ask an agent to do is described here, and every parameter is validated BEFORE a job is
// created. The agent validates again before acting: it never trusts the network.

const noControl = (s: string) => !/[\u0000-\u001f]/.test(s);

/** A Windows path: "" (list the drives) or X:\folder\sub. No "..", no characters Windows forbids in names. */
export const winPath = z.string().max(400).refine(noControl).refine((p) => {
  if (p === "") return true;
  if (!/^[A-Za-z]:\\/.test(p)) return false;
  const parts = p.slice(3).split("\\").filter((x) => x !== "");
  return parts.every((x) => x !== ".." && x !== "." && !/[<>:"|?*]/.test(x));
}, "not a valid Windows path");

/** A path inside a snapshot: /C/Users/bob/Documents (drive letter first). */
export const snapPath = z.string().min(1).max(600).refine(noControl).refine(
  (p) => p.startsWith("/") && !p.split("/").some((x) => x === ".." || x === "."),
  "not a valid snapshot path",
);

export const snapshotId = z.string().regex(/^([0-9a-f]{8,64}|latest)$/);

/**
 * Where a person may restore files to. The agent writes as SYSTEM, so system locations are off limits: Windows, program
 * folders, ProgramData, any AppData (that is where Startup lives) and the drive itself. The agent checks the same rules.
 */
export function restoreFolderProblem(p: string): string | null {
  const m = /^([A-Za-z]):\\(.+)$/.exec(p.replace(/\\+$/, ""));
  if (!m) return "choose a folder, not a whole drive";
  const parts = m[2].split("\\");
  const first = parts[0].toLowerCase();
  if (["windows", "program files", "program files (x86)", "programdata", "system volume information", "recovery", "$recycle.bin", "msp-backup"].includes(first)) return "system folder";
  if (first === "users" && parts.some((x, i) => i >= 2 && x.toLowerCase() === "appdata")) return "system folder";
  if (first === "users" && parts[1]?.toLowerCase() === "default") return "system folder";
  return null;
}
export const restoreFolder = winPath.refine((p) => p !== "" && !/[*]/.test(p) && restoreFolderProblem(p) === null, "cannot restore there");

export const JobSchemas = {
  list_dirs: z.object({ path: winPath }).strict(),
  backup_now: z.object({}).strict(),
  list_snapshots: z.object({}).strict(),
  ls_snapshot: z.object({ snapshot: snapshotId, path: snapPath }).strict(),
  find: z.object({
    pattern: z.string().min(1).max(100).refine(noControl).refine((s) => !s.startsWith("-")),
    snapshot: snapshotId.optional(),
  }).strict(),
  restore: z.object({
    snapshot: snapshotId,
    items: z.array(snapPath).min(1).max(50),
    drive: z.string().regex(/^[A-Z]$/).optional(),
    // safe = a new administrators-only folder (default); folder = a folder the person chose; original = back where
    // the files came from (staff only, enforced by the route). Existing files are kept unless overwrite is "always".
    target: z.enum(["safe", "folder", "original"]).optional(),
    folder: z.string().max(400).optional(),
    overwrite: z.enum(["never", "always"]).optional(),
  }).strict().superRefine((v, ctx) => {
    if ((v.target === "folder") !== (v.folder !== undefined)) ctx.addIssue({ code: "custom", message: "folder is for the folder choice only" });
    if (v.folder !== undefined) {
      const r = restoreFolder.safeParse(v.folder);
      if (!r.success) ctx.addIssue({ code: "custom", message: "that folder cannot be restored into" });
    }
  }),
} as const;

export type JobType = keyof typeof JobSchemas;

/** How long an unanswered request stays valid. Interactive screens give up quickly; restores may wait for a machine to come online. */
export const JobTtlMinutes: Record<JobType, number> = {
  list_dirs: 10, backup_now: 30, list_snapshots: 10, ls_snapshot: 10, find: 15, restore: 24 * 60,
};

/** The folders/files a person may choose to back up: drive-rooted folders, never "" (the drive list) and no wildcards. */
export const backupPath = winPath.refine((p) => p !== "" && !/[*]/.test(p), "choose a folder");
export const PolicySchema = z.object({ include: z.array(backupPath).min(1).max(200) }).strict();

/** Which days (0 = Sunday ... 6 = Saturday) and what local time of day the backup runs. */
export const ScheduleSchema = z.object({
  days: z.array(z.number().int().min(0).max(6)).min(1).max(7),
  time: z.string().regex(/^([01][0-9]|2[0-3]):[0-5][0-9]$/),
}).strict();
