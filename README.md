# MSP Platform

Self-hosted MSP tooling: single sign-on with MFA, per-customer monitoring, and (later) ticketing and remote access. Runs with Docker Compose behind your existing Nginx Proxy Manager.

## Status

**Phase 1 (foundation + Windows monitoring) is built and tested on a Debian 13 VM with an iSCSI-backed data volume.**

Tested: full stack boots; customer onboarding (with rollback on failure); 19 cross-tenant isolation checks pass (`scripts/test-isolation.sh`); VM rebuild from scratch using only the bootstrap script and the LUKS key; clean reboot with automatic LUN attach.

**Not yet tested:** the Windows agent on a real Windows machine, and the authentik UI setup (MFA, AD/LDAPS, Grafana OIDC login) — those steps are manual and documented below. Image tags in `.env.example` were the newest that pulled on amd64 when tested; check for newer security releases before a production deploy.

| Phase | Scope |
|---|---|
| 1 | authentik (MFA, AD via LDAPS, local users), Postgres, InfluxDB, Loki, Grafana, ingest gateway, Windows agent (CPU/RAM/disk/services/BitLocker/event logs), per-customer isolation |
| 2 | SNMP polling + traps, syslog, network dashboards |
| 3 | Ticketing app (custom, Postgres) with alert-to-ticket and recurring-problem detection |
| 4 | MeshCentral remote access, SSO via authentik |
| 5 | Backups: local / NFS / SMB / S3, per-customer age-encrypted exports |

## Architecture

```
agents ──https──> NPM ──> gateway ──> Loki      (tenant = customer, set by gateway from the agent's key)
                              └─────> InfluxDB  (bucket cust_<slug>, bucket-scoped write-only token)
users  ──https──> NPM ──> authentik (MFA, AD/LDAPS, local users)
                    └──> Grafana (OIDC via authentik; one org per customer)
```

Isolation, enforced server-side at every layer:

- **InfluxDB**: bucket per customer. Agents hold a write-only token for that one bucket. Grafana holds a read-only token for that one bucket.
- **Loki**: `auth_enabled: true`. The gateway maps each agent's push key to exactly one tenant and overwrites any client-supplied tenant header.
- **Grafana**: one org per customer, with datasources bound to that customer only.
- **Who sees what** is driven by authentik groups:
  - `msp-admins`: everything
  - `tech-<slug>`: Editor in that customer's org (so techs only see customers they're assigned)
  - `cust-<slug>-users`: Viewer in that customer's org

## Disposable VM, persistent data

The Docker VM is cattle: destroy it any time. **All state lives on one iSCSI LUN** (LUKS2-encrypted, XFS inside), mounted at `/srv/msp`: databases under `/srv/msp/data`, plus this repo, `secrets/` and `generated/` under `/srv/msp/app`. The SAN only ever sees ciphertext.

Rebuild a node (fresh Debian, storage NIC up with a static IP and **no gateway**):

```bash
sudo scripts/bootstrap-vm.sh \
  --portal 192.168.20.251 --target iqn.2005-10.org.freenas.ctl:msp-apps \
  --initiator iqn.2026-10.lan.msp:msp-app --luks-key /path/to/msp-luks.key
# first build only, on a blank LUN:  add --init-new-lun --repo <git url>
```

- **Keep the LUKS key safe and offline** (password manager + a printed copy). Without it the data is unrecoverable. It is never stored in the repo or on the SAN.
- **Only one VM may attach the LUN at a time.** Destroy the old VM first, and restrict the target to a single initiator name and the VM's storage IP, with CHAP.
- At boot, `msp-data.service` unlocks and mounts the LUN, and Docker is ordered after it. If the LUN is missing, Docker refuses to start rather than write empty data to the VM's disk. On shutdown Docker stops first, then the volume unmounts cleanly.
- Don't `umount` or log out of iSCSI while containers run. Use `docker compose down` first.

## Deploy

```bash
git clone https://github.com/cn2450-netizen/MSP-Application-.git msp-platform && cd msp-platform
scripts/init-secrets.sh          # generates ./secrets, .env, prints first-login info
nano .env                        # set AUTH_HOST / GRAFANA_HOST / INGEST_HOST, BIND_ADDR
docker compose up -d postgres redis authentik-server authentik-worker
```

### NPM proxy hosts (all with TLS, force-SSL, HTTP/2)

| Host | Forward to | Notes |
|---|---|---|
| `AUTH_HOST` | `BIND_ADDR:9000` | enable websockets |
| `GRAFANA_HOST` | `BIND_ADDR:3000` | enable websockets |
| `INGEST_HOST` | `BIND_ADDR:8080` | agents only; consider an NPM access list on source IPs if customer ranges are known |

If NPM runs in Docker on this host, either keep `BIND_ADDR=127.0.0.1` and forward to the host's IP, or attach the services to NPM's Docker network instead of publishing ports.

### Configure authentik

Run `scripts/setup-authentik.sh` once authentik is healthy. It enforces MFA for every login (TOTP authenticator app such as Google Authenticator, enrolled at first sign-in), creates `msp-admins`, and registers Grafana as an OIDC app that only bound groups can open. It's repeatable and uses a short-lived API token that it deletes afterwards. `add-customer.sh` creates each customer's `tech-<slug>` and `cust-<slug>-users` groups and binds them to Grafana; `scripts/sync-customer-groups.sh` repairs or backfills them.

What stays manual, in the UI: create your named admin user (then lock down `akadmin`), and the AD source in step 3 below. Steps 2, 5 and 6 of the list below are automated by the script and are kept as reference.


1. Sign in at `https://AUTH_HOST/` as `akadmin` (password printed by `init-secrets.sh`, also in `secrets/authentik_bootstrap_password`). Do not use `/if/flow/initial-setup/`: it only works on an install with no users. Create your named admin user, then disable or lock down `akadmin`.
2. **MFA**: Flows & Stages → Stages → edit the default *Authenticator Validation* stage (in `default-authentication-mfa-validation`): set *Not configured action* to **Force the user to configure an authenticator** and allow TOTP only (`scripts/setup-authentik.sh` does this). A lost phone is handled by an admin removing the user's device so they re-enrol.
3. **AD users (internal team)**: Directory → Federation & Social login → Create **LDAP Source**. Use `ldaps://` with your CA's cert uploaded as a Certificate Key Pair, a read-only bind account, and your user/group base DNs. Map AD groups to authentik groups.
4. **Local users (customers)**: create them under Directory → Users and assign to `cust-<slug>-users`.
5. Create groups: `msp-admins`, then per-customer groups (the add-customer script tells you which).
6. **Grafana provider**: Applications → create *OAuth2/OpenID* provider.
   - Client ID `grafana`, client secret = contents of `secrets/grafana_oauth_secret`
   - Redirect URI `https://GRAFANA_HOST/login/generic_oauth`
   - Scopes: `openid profile email`; application slug `grafana`
   - Confirm the `groups` claim is present in the userinfo response (the default `profile` scope mapping includes it).
7. Then start the monitoring stack: `docker compose up -d`.

### Onboard a customer

```bash
scripts/add-customer.sh acme "Acme Corp" 90     # 90 = metric retention in days
```

Creates their bucket, Grafana org + datasources + starter dashboard and authentik groups, then a first site `main` whose agent credentials are written to `generated/credentials/acme/main.txt` (mode 600). Then create the `tech-acme` and `cust-acme-users` groups in authentik.

### Change the dashboard

Edit `dashboards/build_windows_overview.py` (house style: every percentage is a 0-100 gauge), run it to regenerate `windows-overview.json`, then `scripts/update-dashboards.sh` pushes it to every customer org.

### Sites (locations) and per-site keys

A customer is one bucket, one Loki tenant and one Grafana org. Each **site** (location) under it has its own write-only Influx token and Loki push key, so one office's key can be revoked without touching the others, and everything an agent sends carries a `site` label.

```bash
scripts/add-site.sh acme branch "Branch office"   # new keys + that site's one-file installer
scripts/revoke-site.sh acme branch                # waits until the gateway really refuses the key
```

`add-customer.sh` creates the first site, `main`. Credentials live in `generated/credentials/<customer>/<site>.txt` and installers in `generated/agents/<customer>/<site>/`. All PCs at one site share that site's key (per-device keys are a later step).

### Install the Windows agent

Download `telegraf.exe` from the vendor's release page and note its published SHA256. On the customer PC (elevated PowerShell), with `telegraf.exe` next to the scripts in `agent/windows/`:

```powershell
.\install-agent.ps1 -Customer acme -IngestHost ingest.example.com `
  -InfluxWriteToken <from credentials file> -LokiPushKey <from credentials file> `
  -TelegrafSha256 <published hash>
```

## Remote access and agent rollout (MeshCentral)

MeshCentral (https://remote.<domain>) signs in through authentik and gives techs Desktop / Terminal / Files on managed PCs. Each site is a device group named `<customer> / <site>`; the default consent is **notify + on-screen toolbar** (71), set per group with `--consent`.

**There is no standing admin credential.** Scripts use a short-lived login token that a person creates while signed in (My Account -> Create login token, 1-2 hours) and stores with `scripts/mesh-token.sh set` (username on line 1, password on line 2, from stdin). Clear it when done: `scripts/mesh-token.sh clear`.

Onboarding a customer end to end:

```bash
scripts/add-customer.sh acme "Acme Corp"          # customer + first site "main" (+ its device group if a token is stored)
scripts/add-site.sh acme branch "Branch office"   # more locations; each gets its own keys and device group
scripts/mesh-site.sh acme main                    # (re)create a site's device group and fetch its MeshCentral agent; --all for every site
# put the MeshCentral agent on each PC: send generated/agents/acme/main/meshagent64-acme-main.exe,
# or give the user a link:
scripts/mesh-invite.sh acme main 24               # invitation link, valid 24 h; send privately
scripts/mesh-deploy-monitoring.sh acme main --yes # push + run the monitoring agent on every online PC in the site (also upgrades)
scripts/mesh-grant.sh                             # give each customer's techs access (see note)
```

Notes:
- **Tech access:** MeshCentral takes user groups from authentik and refuses to create them by hand, so `tech-<customer>` only exists in MeshCentral after someone in that authentik group has signed in once. Run `scripts/mesh-grant.sh` after that first sign-in (and after adding sites).
- **Deploying through Mesh** copies the site's installer (it holds that site's write-only keys) into the MeshCentral container only for the push, uploads it to `C:\Windows\Temp`, runs it as SYSTEM, then deletes it from the PC and the container.
- `scripts/revoke-site.sh <customer> <site> [--remove-mesh-group]` cuts the monitoring keys; the group (and its devices in MeshCentral) is only removed with the flag.
- MeshCentral Router is not used: the Desktop/Terminal/Files tabs cover day-to-day support.

## Customer backup storage (NAS)

Customer-machine backups (Restic) are stored on the NAS, not on the platform volume. `scripts/setup-backup-storage.sh --nfs HOST:/export [--init]` (called by `bootstrap-vm.sh --backup-nfs ...`) mounts the share at `/srv/msp-backups` through `msp-backup-nfs.service`:

- The mount point is **immutable while unmounted**, so nothing can write to the VM's own disk if the NAS is missing.
- A marker file (`.msp-backup-root`) must exist on the share, so a wrong or uninitialised share is refused (`--init` creates it on a new, empty one).
- It retries while the NAS is unreachable and recovers by itself. Docker is ordered after it but never *requires* it, so a NAS outage cannot stop the platform from starting.

NAS side (TrueNAS SCALE 25.10): dataset `Share/msp-backups` (quota, 1 MiB records, POSIX ACLs, mode 750, owner `restic-svc` uid 1500 / gid 3002), NFS share restricted to the VM's storage address with Mapall `restic-svc`, plus a daily ZFS snapshot task. S3 (e.g. Wasabi) is planned later as a cold tier by copying long-lived snapshots with `restic copy`.

### Backup server (Restic REST server)

`restic-server` (compose) serves repositories on the NAS share with **`--append-only`** (clients can add backups but never delete or alter existing ones; a ransomware-infected machine cannot erase its history) and **`--private-repos`** (each machine's login reaches only its own repository). Each machine gets its own login, its own repository and its own encryption password:

```bash
sudo scripts/install-restic.sh                              # pinned, checksum-verified restic on the VM (once)
scripts/backup-add-machine.sh acme main dc01                # login + repo + passwords -> generated/backup/credentials/acme/main/dc01.txt
scripts/backup-remove-machine.sh acme main dc01             # cut off access; data kept on the NAS
scripts/backup-remove-machine.sh acme main dc01 --delete-backups   # PERMANENT: also delete the repository
```

The repository password in that credentials file is the only way to read the backups: copy it to your vault. Retention and pruning are done on the VM against the local NAS path (never through the append-only server). The container refuses to start unless the NAS marker file is visible, so it can never write to the VM's disk. Put it behind NPM at `backup.<domain>` (WebSockets not needed; set `client_max_body_size 0;`, `proxy_request_buffering off;`, `proxy_read_timeout 600s;`; use a DNS-only Cloudflare record, since proxying large backup uploads through Cloudflare is limited and against its terms for non-web content).

### Backing up a Windows machine

```bash
scripts/backup-add-machine.sh acme main dc01                                  # once per machine (see above)
scripts/build-backup-installer.sh acme main dc01 [--paths 'D:\Data;E:\Shares'] [--time 02:30]
# -> generated/agents/acme/main/backup/install-backup-dc01.ps1 (holds that machine's credentials: deliver securely, delete after use)
```

Run it elevated on the machine (`-RunNow` for a first backup). To roll it out through MeshCentral instead: `scripts/mesh-deploy-backup.sh acme main [--device DC01 | --yes] [--register] [--paths ...] [--run-now]` (`--register` creates the machine's login, repository and installer for any online device that has none; needs a login token, `scripts/mesh-token.sh set`). Backup is opt-in per machine: devices that are not registered are simply skipped, so install the monitoring agent everywhere and back up only the critical servers. `sudo scripts/backup-list.sh acme main` shows each device as protected, STALE, registered with no backup yet, or not backed up, and flags registered machines missing from Mesh. It installs the pinned restic, tests the login, and schedules `\MSP\MSPBackup` daily (SYSTEM, VSS so open files are consistent). Default scope is every fixed drive minus `agent/backup/windows/excludes.txt` (OS, programs, caches); add per-site rules in `agent/backup/windows/excludes.site/<customer>-<site>.txt`. In exclude files a literal `$` must be written `[$]` (restic expands `$NAME`, and an empty expansion excludes everything). A backup that stores 0 files is reported as failed. The result is shipped by the monitoring agent to the **Backups** panel of the customer's dashboard.

### Maintenance, verification and restore

```bash
sudo scripts/install-backup-maintenance.sh [10:00]   # daily timer (msp-backup-maintain): run once
sudo scripts/backup-maintain.sh [--machine acme-main-dc01] [--no-prune] [--no-restore-test]
sudo scripts/backup-restore.sh acme main dc01 --list
sudo scripts/backup-restore.sh acme main dc01 --target dc01-fix --path /C/Data/Finance   # -> /srv/msp/restore/dc01-fix
```

The daily job, per machine, on the NAS path: fails if the newest snapshot is older than 36 h (a silently dead agent); prunes to 7 daily / 4 weekly / 6 monthly (deferred while the machine is uploading, since clients do not lock); `restic check` plus a rotating 1/7 of all data re-read each day (everything verified weekly); and restores 3 random files from the newest snapshot and verifies them. Any failure leaves `msp-backup-maintain.service` failed. Restores go only to the encrypted data volume, need the customer name typed to confirm, and are logged to `generated/backup/restore-audit.log`. Delete restored data once delivered.

## Agent footprint and outage buffering

Measured on Telegraf 1.40.2 / Windows: the program is ~315 MB on disk (the agent log is capped at ~20 MB); an idle agent uses ~97 MB of RAM. Collected data is **never written to disk**: during an outage it waits in RAM (200,000 metrics, ~66 hours, ~140 MB; 5,000 event-log entries, ~85 MB), oldest dropped first when full. Both buffers completely full is ~330 MB (~500 MB allowing for Go GC slack), well inside a 1 GB ceiling. A restart or reboot during an outage loses what is buffered, and event-log entries written while the agent is stopped are not sent. Costs per item are in the comments of `agent/windows/telegraf.conf.tmpl`; re-measure before raising the limits.

## Security notes

- Secrets are Docker secrets from `./secrets` (dir mode 700), never in `.env` or the compose file. Back `./secrets` up offline; it is excluded from git.
- Data stores are on an `internal` Docker network with no published ports and no internet access.
- The gateway exposes only the two write paths agents need, rate-limits, caps body size, and never logs credentials.
- Agent credentials are per-customer and write-only; a stolen agent token cannot read anything. Rotate by re-running onboarding for a new key (revocation tooling comes with a later phase).
- The agent does **not** ship the Windows Security log (it contains sensitive data). Add specific event IDs deliberately if you need them.
- Grafana's login form is disabled; everything goes through authentik. Break-glass is the `msp-admin` API account; re-enable the form by overriding `GF_AUTH_DISABLE_LOGIN_FORM`.
- Known gaps for now: no backups yet (phase 5), no SIEM-style alerting, containers not yet hardened beyond `no-new-privileges` and a read-only gateway. Don't put real customer data on it until backups and a restore test exist.
