# Operations

Commands run on the VM in the app directory (`/srv/msp/app`) unless noted.

## Daily and weekly checks

| When | Check | How |
|---|---|---|
| Daily | Backup maintenance passed | `systemctl status msp-backup-maintain` (failed means a stale machine, a failed integrity check or a failed test restore); `journalctl -u msp-backup-maintain -n 50` |
| Daily | Portal dashboard | Failed, partial and stale computers |
| Daily | Catalog is current | `systemctl status msp-backup-catalog.timer` |
| Weekly | NAS space | `df -h /srv/msp-backups` |
| Weekly | Containers healthy | `docker compose ps` |
| Weekly | Disk on the VM and data volume | `df -h / /srv/msp` |
| Monthly | Image and agent updates | See "Updating" below |
| Monthly | Full-size restore test of one real machine | Portal restore to a new folder, open the files |

## Starting, stopping, rebuilding

- **Normal stop/start:** `docker compose down` then `docker compose up -d`. Always stop containers before unmounting or detaching the LUN.
- **Boot order:** `msp-data.service` unlocks and mounts the LUN, Docker starts after it, and `msp-backup-nfs.service` mounts the NAS share. If the LUN is missing, Docker refuses to start rather than write to the VM's disk. If the NAS is missing, the platform still starts and the backup server stays down.
- **Rebuild the VM from nothing:** fresh Debian, storage NIC up with a static address and no gateway, then `sudo scripts/bootstrap-vm.sh --portal <san ip> --target <iqn> --initiator <iqn> --luks-key <file>`. You need the LUKS key (kept in the vault, never in the repo). Only one VM may attach the LUN at a time: destroy the old one first.
- **After a rebuild:** install the host timers again (`install-backup-maintenance.sh`, `install-backup-catalog.sh`, `install-backup-replace-executor.sh`), check `docker compose ps`, run `scripts/test-isolation.sh`.

## Updating

1. Read the release notes and pick the new image tags in `.env` (see `.env.example`). Check for security fixes before every deploy.
2. `docker compose pull && docker compose up -d`.
3. Portal code: copy the new repo contents to the VM and `docker compose up -d --build portal`. Migrations are applied when the portal starts.
4. Run `scripts/test-isolation.sh`. Open the portal and Grafana once.
5. **Windows agents:** the monitoring agent upgrades by re-running `scripts/mesh-deploy-monitoring.sh <customer> <site> --yes`; the backup agent by `scripts/mesh-deploy-backup.sh <customer> <site> --yes` (it always rebuilds the installer, so an upgrade really ships). The agent version shows on each portal computer page.

## Routine tasks

| Task | Command |
|---|---|
| New customer | [ONBOARDING.md](ONBOARDING.md) |
| New location | `scripts/add-site.sh <customer> <site> "Name"` |
| Revoke a site's monitoring keys | `scripts/revoke-site.sh <customer> <site>` |
| Add a computer to backup | `scripts/mesh-deploy-backup.sh <customer> <site> --device NAME --register` |
| Stop backing up a computer | `scripts/backup-remove-machine.sh <customer> <site> <host>` (data kept; add `--delete-backups` to destroy) |
| Replace a failed computer | Portal, computer page, Replace this computer (second technician approves) |
| Show protected / stale computers | `sudo scripts/backup-list.sh <customer> <site>` |
| Browse a backup on the host | `sudo scripts/backup-restore.sh <customer> <site> <host> --list` |
| Push a dashboard change | Edit `dashboards/build_windows_overview.py`, run it, then `scripts/update-dashboards.sh` |
| End a customer | `scripts/offboard-customer.sh <customer> --suspend` then later `--purge --confirm <customer>` |

## MeshCentral login token

Scripts that touch MeshCentral need a short-lived login token because there is no standing admin credential. Create it while signed in (My Account, Create login token, 1-2 hours), store it with `scripts/mesh-token.sh set`, and clear it afterwards with `scripts/mesh-token.sh clear`. `scripts/mesh-token.sh check` says whether the stored one still works.

## What to do when

| Symptom | First steps |
|---|---|
| A computer shows stale | Is it on? In Mesh, is the agent online? On the PC: `Get-ScheduledTask -TaskPath '\MSP\*'`, logs in the `MSP-Backup` folders under `C:\Program Files` and `C:\ProgramData`. The long-poll task runs continuously; the backup task at the scheduled time |
| Backup partial | Usually open or locked files. Read the message on the computer page. Retry with Back up now |
| Maintenance failed: restore test | Treat as urgent. Run `sudo scripts/backup-maintain.sh --machine <customer>-<site>-<host>` and read the output. Do not prune until understood |
| Portal says "waiting" for a long time | The computer is off or offline. Jobs expire on their own |
| NAS missing | `systemctl status msp-backup-nfs`. The platform keeps running; backups resume when the share returns |
| A PC was stolen, or a site key leaked | `scripts/revoke-site.sh`; for a backup login `scripts/backup-remove-machine.sh`; for a replaced PC use the Replace flow, which rotates credentials |
| Customer forgot their phone | Remove the user's authenticator device in authentik; they enrol again at next sign-in |
| Disk full | `docker system df`; check Loki and Influx retention; the NAS dataset quota |

## Secrets and keys you must keep

- **LUKS key** for the data LUN: vault plus a printed copy. Without it the platform data is unrecoverable.
- **`./secrets`**: back up offline. It is excluded from git.
- **Each computer's repository password**: in its credentials file and in your vault. Without it its backups cannot be read.
- Admin sudo requires a password (passwordless sudo removed); scripts that use `sudo` need an interactive session.

## Host firewall

`msp-firewall.service` (`sudo scripts/install-host-firewall.sh`) lets only `NPM_IP` reach the platform's published ports. To reach a port directly while troubleshooting, add your workstation to `FW_ALLOW_FROM` in `.env` and re-run the script, or stop the service (`sudo systemctl stop msp-firewall`) and start it again afterwards. If you change NPM's address, update `NPM_IP` and re-run. `sudo scripts/install-host-firewall.sh --remove` removes it.

## Platform backup

`msp-platform-backup.timer` runs `scripts/backup-platform.sh` daily at 03:30 (install with `sudo scripts/install-platform-backup.sh`, once, after `sudo scripts/backup-platform.sh --init`). It saves a full database dump, an InfluxDB backup, `secrets/`, `generated/`, `config/`, `.env`, and the authentik, Grafana, MeshCentral and Influx config data to `/srv/msp-backups/_platform`, keeps 7 daily / 4 weekly / 6 monthly, runs `restic check` on a rotating subset, and restores the newest snapshot to prove the dump is complete. A failure leaves the service failed: `systemctl status msp-platform-backup`; the last result is in `generated/backup/platform.status`.

- **The repository password** is shown once by `--init`. It must be in your vault: the copy in `secrets/` is lost with the VM.
- **Not included:** Loki logs, the customer repositories (they have their own checks), and the LUKS key (vault only).
- **Rebuild from it:** bootstrap a new VM, then `restic -r /srv/msp-backups/_platform restore latest --target /` with the repository password, restore the database with `psql < postgres.sql` and Influx with `influx restore`. A full rehearsal is still on the [roadmap](ROADMAP.md).
- The NAS is the only place it is stored. An off-site copy comes with the cold tier.
