# Backup guide

For technicians and, with the customer sections, for the people who use the portal. Install and engineering details are in the [README](../README.md).

## What is backed up

Windows computers, files only. Registration is per computer: install the monitoring agent everywhere, back up the file servers and the PCs that hold local data. Operating system, programs and caches are excluded by `agent/backup/windows/excludes.txt`. Site-specific excludes go in `agent/backup/windows/excludes.site/<customer>-<site>.txt`; write a literal `$` as `[$]`.

Retention: 7 daily, 4 weekly, 6 monthly snapshots. Backups use VSS, so open files are consistent. Cloud-synced placeholder files are excluded.

## For the customer (portal)

Sign in at the portal address you were given (with your authenticator code).

| I want to | Do this |
|---|---|
| See if my computers are protected | The dashboard shows each computer as OK, partial, failed or stale |
| Change what is backed up | Computer, then Choose folders |
| Change when | Computer, then Schedule (days and time) |
| Back up right now | Computer, then Back up now |
| Get a file back | Computer, then Restore. Pick the date, tick the files or folders, choose where they go |

**Where do restored files go?**
- *A new folder* (default): `<drive>:\MSP-Restored\<date and time>`, which only administrators can open.
- *A folder I pick*: browse the computer and choose a folder. Existing files are kept unless you tick "replace".
- *Back where they came from*: technicians only.

Some places are never allowed (Windows, Program Files, ProgramData, AppData, a whole drive). Choose another folder.

## For the technician

**Add a computer**
```bash
scripts/mesh-deploy-backup.sh <customer> <site> --device NAME --register --run-now
```
Then watch the first backup finish, set the schedule with the customer, store the repository password in your vault, and prove it with a restore ([ONBOARDING.md](ONBOARDING.md)).

**Restore for a customer.** Portal, computer, Restore. Staff can also search all backups of a computer for a file name, across dates. If the portal or the computer is unavailable, use the host: `sudo scripts/backup-restore.sh <customer> <site> <host> --target <name> --path /C/Data` (restores to `/srv/msp/restore/<name>`, needs the customer name typed, is logged). Delete restored data once delivered.

**Replace a failed or stolen computer.**
1. Install Windows and the MeshCentral agent on the new computer, name it, and wait until it is online in the customer's group.
2. Portal, old computer's page, **Replace this computer**, enter the new computer's name.
3. A *different* technician approves it.
4. The host rotates the old credentials, installs the identity on the new computer and the next backup continues the same history.
5. Click **Restore the newest backup onto it** to put the files back in place.

If the new computer is not online, the request fails with a message and changes nothing; retry once it is.

**Retire a computer.** `scripts/backup-remove-machine.sh <customer> <site> <host>` removes its login and keeps the data. Add `--delete-backups` to destroy the repository permanently.

## How you know it works

Every day the host checks each repository: newest snapshot under 36 hours old, `restic check`, one seventh of the data re-read (all of it each week), and three random files restored and compared. Anything wrong leaves `msp-backup-maintain` failed. A green dashboard means "the job ran"; the daily restore test and your own periodic restore are what prove the data is recoverable.

## Limits you should know

- Windows only. Linux backup is on hold.
- The first backup of a large machine takes many hours or days depending on the upload line; it resumes if interrupted.
- The NAS is the only copy of the data for now. The off-site cold tier (Wasabi) is not built.
- A PC that is off at its scheduled time misses that run and is reported stale after 36 hours.
- Restores run as SYSTEM on the computer and only work while the computer is on and online.
