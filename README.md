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

Creates their bucket, tokens, Loki key, Grafana org + datasources + starter dashboard, and writes agent credentials to `generated/credentials/acme.txt` (mode 600). Then create the `tech-acme` and `cust-acme-users` groups in authentik.

### Change the dashboard

Edit `dashboards/build_windows_overview.py` (house style: every percentage is a 0-100 gauge), run it to regenerate `windows-overview.json`, then `scripts/update-dashboards.sh` pushes it to every customer org.

### Install the Windows agent

Download `telegraf.exe` from the vendor's release page and note its published SHA256. On the customer PC (elevated PowerShell), with `telegraf.exe` next to the scripts in `agent/windows/`:

```powershell
.\install-agent.ps1 -Customer acme -IngestHost ingest.example.com `
  -InfluxWriteToken <from credentials file> -LokiPushKey <from credentials file> `
  -TelegrafSha256 <published hash>
```

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
