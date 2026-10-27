# Architecture

## Pieces

| Piece | What it does | Where it runs |
|---|---|---|
| **authentik** | Single sign-on for everything. Staff come from AD over LDAPS, customers are local users. TOTP MFA is enforced for every login. | Docker |
| **Reverse proxy (NPM)** | TLS for every public host name. Not part of this repo. | Existing |
| **Gateway** | The only door for monitoring agents. Maps an agent's key to exactly one customer. | Docker |
| **InfluxDB / Loki** | Metrics (bucket per customer) and logs (tenant per customer). | Docker, internal network only |
| **Grafana** | Dashboards. One org per customer. Sign-in only through authentik. | Docker |
| **MeshCentral** | Remote desktop, terminal and files. Sign-in through authentik, staff only. | Docker |
| **Restic REST server** | Receives customer backups. Append-only, one login and repository per computer. | Docker |
| **Backup portal** | Customers and techs pick folders and schedules, browse and restore. Metadata only. | Docker |
| **Postgres** | authentik, MeshCentral and portal databases. | Docker |
| **Windows agents** | Telegraf (monitoring), restic plus two small PowerShell tasks (backup). | Customer PCs |
| **Host timers** | Backup maintenance, catalog indexer, replace-machine executor. They hold the secrets the containers must not. | The VM, systemd |

## Data flow

```
monitoring agent --https--> NPM --> gateway --> Loki (tenant = customer)
                                         \----> InfluxDB (bucket cust_<slug>, write-only token)

backup agent -----https--> NPM --> restic REST server --> NAS (NFS)    one repository per computer
backup agent <--https--- NPM <-- portal (long-poll: policy, schedule, at most one job)

people ----------https--> NPM --> authentik (MFA) --> Grafana | portal | MeshCentral
```

Agents always call out. Nothing connects in to a customer network.

## Who can see what

Groups in authentik decide everything:

| Group | Sees |
|---|---|
| `msp-admins` | Every customer |
| `tech-<slug>` | That customer, as staff (Grafana Editor, portal staff, remote access) |
| `cust-<slug>-users` | That customer only, as a customer (Grafana Viewer, portal customer) |

A user in none of these is stopped by authentik and never reaches an application.

## Isolation, layer by layer

- **InfluxDB:** bucket per customer. Agents hold a write-only token for their site, Grafana a read-only token for one bucket.
- **Loki:** `auth_enabled: true`. The gateway sets the tenant from the agent's key and overwrites anything the client sent.
- **Grafana:** one org per customer with datasources bound to that customer.
- **Backups:** each computer has its own server login, repository and encryption password. A login reaches only its own repository.
- **Portal:** every query carries a scope derived from the user's groups. A machine you may not see answers 404, the same as one that does not exist.
- **Tests:** `scripts/test-isolation.sh` (19 cross-tenant checks), `scripts/test-backup-login.sh`, `scripts/test-backup-guard.sh`.

## Where state lives

All state is on one LUKS2-encrypted iSCSI LUN mounted at `/srv/msp`. The VM is disposable; see [OPERATIONS.md](OPERATIONS.md) for the rebuild. Customer backup data is separate, on an NFS share at `/srv/msp-backups`, and is encrypted by restic before it leaves the customer's computer.

| Path | Holds |
|---|---|
| `/srv/msp/data` | Databases, metrics, logs, MeshCentral data |
| `/srv/msp/app/secrets` | Docker secrets (mode 700) |
| `/srv/msp/app/generated` | Rendered config, credentials files, installers, registries (`customers.tsv`, `sites.tsv`, `backup/machines.tsv`) |
| `/srv/msp-backups` | Restic repositories (NAS) |

## Backup design in one page

- **Engine:** restic over its REST server, `--append-only --private-repos`. A hacked PC cannot delete its history.
- **Retention and checks** run on the VM against the local NAS path, never through the append-only server: 7 daily, 4 weekly, 6 monthly; a freshness check (36 h); `restic check` plus a rotating one-seventh data re-read; a verified test restore of three random files each day.
- **Portal and agent:** the agent long-polls the portal (a job starts in about a second). The portal validates every job; the agent validates it again. The portal never holds a repository password.
- **Catalog:** after each backup a host script reads the snapshots and stores file names and sizes in Postgres, so browsing and search are instant. It holds names only, never contents. Customers see only their own computers' entries.
- **Restore targets:** a new admin-only folder, a folder the person picks, or (staff only) back in place. The agent runs as SYSTEM, so it refuses Windows, Program Files, ProgramData, AppData, drive roots and anything through a junction.
- **Replacing a computer:** a technician requests it, a different technician approves, a host executor rotates the old credentials and installs the identity on the new PC. The new PC continues the same repository.
