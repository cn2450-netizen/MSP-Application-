# Status and roadmap

## Built and tested

- Single sign-on (authentik) with enforced TOTP MFA; Grafana, backup portal and remote access behind it.
- Windows monitoring agent: metrics, services, BitLocker, event logs; per-customer isolation proven with 19 checks.
- MeshCentral remote access with SSO, device group per site, notify-and-toolbar consent by default, deployment of the agents through it.
- Customer backups: restic over an append-only REST server on the NAS; scheduling; daily maintenance and verified test restore; backup portal with a server-side catalog, restore location picker, long-poll agent; Replace this computer.
- Customer offboarding: suspend (cut all access) and purge (delete data) with an audit log.

## Done

- Platform backup: databases, InfluxDB, secrets, config and app data to the NAS daily 03:30, with retention, integrity check and a restore proof (`scripts/backup-platform.sh`). Still to do: rehearse a full rebuild from it, and add an off-site copy.
- Host firewall: only NPM reaches the platform's ports; rpcbind closed (verified from a workstation).
- Lab passwords rotated and passwordless sudo removed (verified: sudo now asks for a password).

## Before real customer data goes on the system

| Item | Why |
|---|---|
| CHAP on the iSCSI target | The target is restricted by initiator name and address only. First attempt 2026-10-27 failed and was rolled back (see "CHAP retry plan" below) |
| HSTS on the remaining hosts | Missing on the authentik, dashboards and ingest hosts (NPM setting) |
| SSH hardening on the VM | Disable password login and root login, turn off X11 forwarding (key login is the only one in use) |
| Self-service password reset and mail (SMTP) | No recovery flow today; an admin removes the authenticator for lost phones |
| AD source (LDAPS) for staff | Staff are currently local authentik users |
| Security scan, hard power-off test, load test | Not run yet |
| HIPAA/BAA review, risk analysis, customer agreements | Compliance work only you can do |
| Approve-by-second-technician test through the real UI | Needs a second staff account; only tested at the database level |
| Replace onto a genuinely different computer | Tested only for a rebuild under the same name |
| Incremental backup after the first large one; VSS open-file test; reboot test | Not yet observed |
| Delete `D:\MSP-Test-Restore` on the test PC and the lab test customers | Leftover test data |

## CHAP retry plan

The VM side is ready (`scripts/iscsi-set-chap.sh`, `bootstrap-vm.sh --chap`). The 2026-10-27 attempt used mutual CHAP, the login was refused in every combination, and the target was set back to None. Retry as one-way CHAP in a planned window:

1. Stop the platform (`docker compose down`); keep an SSH session open on the management address.
2. TrueNAS, Authorized Access: a **new** entry with only User and Secret (12-16 characters, no look-alikes); leave **Peer User and Peer Secret empty** and **Discovery Authentication None**.
3. Target `msp-apps`, group: Authorization Method **CHAP**, Authorization Group Number = the entry's Group ID.
4. VM: `sudo scripts/iscsi-set-chap.sh --set` (blank peer secret), then log out and in: `iscsiadm -m node -T <iqn> --logout` then `--login`.
5. Reboot once to prove the boot-time login, and keep the secret in the vault (a rebuilt VM needs it: `bootstrap-vm.sh --chap`).
6. Rollback if it fails: TrueNAS group method None, then on the VM `sudo ~/iscsi-set-chap.sh --disable` (the repo is on the LUN, so keep a copy of the script outside it) and `systemctl restart msp-data`.

Mutual CHAP can follow once one-way works.

## Next phase (as you decided): onboard customers and watch

Use [ONBOARDING.md](ONBOARDING.md). Watch the internet link, first-backup duration, failures and NAS growth. Ticketing, SNMP and syslog follow once data is flowing.

## Planned

| Phase | Item |
|---|---|
| 2 | SNMP polling and traps, syslog, network dashboards |
| 3 | Ticketing: custom app on Postgres, alert-to-ticket, recurring-problem detection |
| Backup | Wasabi cold tier (`restic copy` of long-lived monthly snapshots; check BAA, Object Lock, 90-day minimum) |
| Backup | Off-site copy of the platform backup (with the Wasabi tier) |
| Backup | Fleet-wide search page for staff; "waiting for the computer" status from an applied-schedule version |
| Backup | Per-customer encryption of catalog file names |
| Agent | Signed MSI/EXE installer; per-device enrolment tokens; uninstall test |
| Portal | Restyle the remaining pages to the new console look |

## On hold

- Linux backup agent (the need was internal, not customers).
