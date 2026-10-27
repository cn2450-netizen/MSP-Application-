# Security and data protection

This describes the controls that exist and the ones that do not yet. It is not a compliance certificate. If customers hold patient data (HIPAA), a BAA, a risk analysis and your own review are still required.

## Controls in place

**Identity**
- One sign-in (authentik) for Grafana, the backup portal and remote access.
- TOTP MFA required for every login. WebAuthn is off on purpose: a passkey stored in the same vault as the password is not a second factor.
- Least privilege by group: `msp-admins`, `tech-<slug>`, `cust-<slug>-users`. Remote access is staff only.
- Scripts act as a service account with a one-hour token that is deleted when they finish. No standing admin credential. MeshCentral scripts use a short-lived login token.

**Customer separation**
- Metrics, logs, dashboards and backups are separated per customer in every layer ([ARCHITECTURE.md](ARCHITECTURE.md)). `scripts/test-isolation.sh` proves it with 19 checks.
- The portal derives a scope from the user's groups for every query. An unauthorised machine returns 404, indistinguishable from a missing one.

**Backups**
- Encrypted on the customer's computer before upload. One repository, login and password per computer.
- Append-only server: malware or a stolen credential on a PC cannot delete or alter existing backups.
- The portal never holds repository passwords, NAS access or the Docker socket.
- Restores need a person in scope, are written to the audit log, land in an admin-only folder by default, and refuse system paths. Restoring in place is staff only.
- Replacing a computer needs a second technician. The old computer's credentials are rotated, so a retired machine that wakes up is cut off.
- Daily verification: freshness, integrity check, rotating data re-read, and a real test restore.

**Platform**
- TLS on every host. HSTS from the portal. Rate limits and body size caps on the gateway.
- Databases and stores sit on an internal Docker network with no published ports and no internet access.
- Docker secrets from a mode-700 directory, never in `.env` or compose.
- All platform data on a LUKS2 volume. The SAN sees ciphertext only.
- The NAS share is restricted to the VM's storage address and mounts with an immutable mount point and a marker file, so nothing writes to the VM's own disk by mistake.
- Agents: a stolen monitoring key can only write to one site. The Windows Security event log is not shipped.
- Offboarding revokes every credential and can permanently delete the data ([ONBOARDING.md](ONBOARDING.md)).

## Data classification

| Data | Where | Sensitivity |
|---|---|---|
| File contents | Restic repositories, encrypted | Highest (may contain patient data) |
| File names, sizes, dates | Portal catalog in Postgres (on the LUKS volume) | High: names can identify patients. Visible only to staff and the owning customer; searches are audited |
| Metrics and event logs | InfluxDB, Loki | Medium: event logs include user names by design |
| Repository passwords | Credentials files on the VM and in your vault | Critical |
| Audit trail | Portal `audit` table, `restore-audit.log`, `offboard-audit.log` | Keep |

## Known gaps

These are tracked in [ROADMAP.md](ROADMAP.md). Close the first group before real customer data goes on this system:

1. Enable CHAP on the iSCSI target.
2. HSTS on the remaining hosts; self-service password reset and mail.
3. AD (LDAPS) source in authentik.
4. Security scan, hard power-off test and a load test.
5. Platform backup (the platform has no backup of its own yet).
6. Catalog file names are plain in the database. Per-customer encryption of names is a possible later step.
7. Agent tokens are per site for monitoring, so one key is shared by the PCs of a site.
8. The installer is a PowerShell script, not a signed MSI/EXE.

## Reporting and review

- Review `generated/backup/restore-audit.log`, the portal audit table and `generated/offboard-audit.log` regularly.
- Re-run `scripts/test-isolation.sh`, `scripts/test-backup-login.sh` and `scripts/test-backup-guard.sh` after every upgrade.
- Keep all images and the restic and Telegraf versions current; versions are pinned in `.env.example` and `agent/*/version.env`.
