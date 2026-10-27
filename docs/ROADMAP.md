# Status and roadmap

## Built and tested

- Single sign-on (authentik) with enforced TOTP MFA; Grafana, backup portal and remote access behind it.
- Windows monitoring agent: metrics, services, BitLocker, event logs; per-customer isolation proven with 19 checks.
- MeshCentral remote access with SSO, device group per site, notify-and-toolbar consent by default, deployment of the agents through it.
- Customer backups: restic over an append-only REST server on the NAS; scheduling; daily maintenance and verified test restore; backup portal with a server-side catalog, restore location picker, long-poll agent; Replace this computer.
- Customer offboarding: suspend (cut all access) and purge (delete data) with an audit log.

## Done

- Lab passwords rotated and passwordless sudo removed (verified: sudo now asks for a password).

## Before real customer data goes on the system

| Item | Why |
|---|---|
| CHAP on the iSCSI target | The target is restricted by initiator name and address only |
| HSTS on the remaining hosts | Only the portal sets it |
| Self-service password reset and mail (SMTP) | No recovery flow today; an admin removes the authenticator for lost phones |
| AD source (LDAPS) for staff | Staff are currently local authentik users |
| Security scan, hard power-off test, load test | Not run yet |
| Platform backup (databases, secrets, app directory) | The platform itself has no backup; the NAS copy covers customer data only |
| HIPAA/BAA review, risk analysis, customer agreements | Compliance work only you can do |
| Approve-by-second-technician test through the real UI | Needs a second staff account; only tested at the database level |
| Replace onto a genuinely different computer | Tested only for a rebuild under the same name |
| Incremental backup after the first large one; VSS open-file test; reboot test | Not yet observed |
| Delete `D:\MSP-Test-Restore` on the test PC and the lab test customers | Leftover test data |

## Next phase (as you decided): onboard customers and watch

Use [ONBOARDING.md](ONBOARDING.md). Watch the internet link, first-backup duration, failures and NAS growth. Ticketing, SNMP and syslog follow once data is flowing.

## Planned

| Phase | Item |
|---|---|
| 2 | SNMP polling and traps, syslog, network dashboards |
| 3 | Ticketing: custom app on Postgres, alert-to-ticket, recurring-problem detection |
| Backup | Wasabi cold tier (`restic copy` of long-lived monthly snapshots; check BAA, Object Lock, 90-day minimum) |
| Backup | Platform (VM) backup |
| Backup | Fleet-wide search page for staff; "waiting for the computer" status from an applied-schedule version |
| Backup | Per-customer encryption of catalog file names |
| Agent | Signed MSI/EXE installer; per-device enrolment tokens; uninstall test |
| Portal | Restyle the remaining pages to the new console look |

## On hold

- Linux backup agent (the need was internal, not customers).
