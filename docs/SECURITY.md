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
- TLS 1.2/1.3 only on every public host; plain HTTP redirects. HSTS on every host except dashboards (open).
- Host firewall (`scripts/install-host-firewall.sh`): only NPM may reach the published service ports on the VM; rpcbind is closed. Self-tests through NPM and removes itself if that fails. Rate limits and body size caps on the gateway.
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

1. Enable CHAP on the iSCSI target (first attempt rolled back; see [ROADMAP.md](ROADMAP.md)).
2. HSTS on the dashboards host; self-service password reset and mail.
3. AD (LDAPS) source in authentik.
4. Security scan, hard power-off test and a load test.
5. Platform backup is on the NAS only: add an off-site copy and rehearse a full rebuild from it.
6. Catalog file names are plain in the database. Per-customer encryption of names is a possible later step.
7. Agent tokens are per site for monitoring, so one key is shared by the PCs of a site.
8. The installer is a PowerShell script, not a signed MSI/EXE.

## Security review log

**2026-10-27, first pass (read-only checks from the management network):**

| Finding | Result |
|---|---|
| Services reachable directly, bypassing NPM/TLS, from any host on the management network | **Fixed**: host firewall; verified blocked from a workstation, NPM paths unchanged |
| rpcbind (111) open on all addresses | **Fixed**: closed by the same firewall |
| TLS versions on the six public hosts | OK: 1.2 and 1.3 only |
| Portal dependency audit (`npm audit --omit=dev`) | OK: 0 vulnerabilities |
| Pending OS upgrades on the VM | OK: none |
| HSTS on the public hosts | NPM now sends it on the authentik, ingest, backup, Mesh and portal hosts (checked 2026-10-27). Still missing on the dashboards (Grafana) host's redirect response |
| SSH allows password login, root login with a key, and X11 forwarding | Open: key login is the only one in use; disable password login and root login |
| The admin account is in the `docker` group (root-equivalent) | Accepted for the admin; keep it to named admins |
| Container image CVE scan | Done 2026-10-27, see below: all nine images have known HIGH findings; the old ones carry CRITICAL ones. Updates needed |
| Authenticated web testing, load test, hard power-off test | Not done |

### Container image scan, 2026-10-27

Trivy 0.75.0 (database of the same day) against the images the stack runs. Vulnerabilities only, no secret or config scan. Counts include findings that have no fix yet.

| Image | Critical | High | Notes |
|---|---|---|---|
| Grafana 11.4.0 (23 months old) | 9 | 144 | Go standard library, OpenSSL, grpc, pgx, kin-openapi |
| InfluxDB 2.7 | 18 | 324 | Go 1.18-1.23 toolchains inside the binary, Debian 12 packages |
| MeshCentral 1.2.1 (our build) | 5 | 98 | handlebars, tar, proxy-addr, nodejs, postgresql client |
| restic rest-server 0.14.0 (17 months old) | 3 | 90 | Go standard library, OpenSSL |
| nginx-unprivileged 1.27-alpine (gateway) | 2 | 56 | OpenSSL (CVE-2026-31789), libexpat, curl |
| Loki 3.3.2 (22 months old) | 2 | 58 | Go standard library, grpc |
| authentik 2026.8.4 | 3 | 71 | libxml2, certifi (fix 2026.10.18), util-linux |
| postgres 16-alpine | 1 | 25 | Go standard library in the bundled helper |
| portal (our build) | 0 | 11 | npm build tooling packages only |

Most findings are in old base images and in Go standard-library versions that a newer image release fixes. Which matter most depends on exposure: the gateway (nginx), the backup server (rest-server) and MeshCentral accept traffic from the internet through NPM, so they come first; Grafana, Loki and InfluxDB are reachable only behind authentik, NPM and the host firewall, or on the internal network. Whether a given CVE is reachable in this setup has not been analysed. A finding is a reason to update, not proof of compromise.

Reports are kept outside the repository. Re-run after every update; see ROADMAP.md.

## Reporting and review

- Review `generated/backup/restore-audit.log`, the portal audit table and `generated/offboard-audit.log` regularly.
- Re-run `scripts/test-isolation.sh`, `scripts/test-backup-login.sh` and `scripts/test-backup-guard.sh` after every upgrade.
- Keep all images and the restic and Telegraf versions current; versions are pinned in `.env.example` and `agent/*/version.env`.
