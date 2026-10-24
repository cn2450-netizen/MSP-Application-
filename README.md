# MSP Platform

Self-hosted MSP tooling: single sign-on with MFA, per-customer monitoring, and (later) ticketing and remote access. Runs with Docker Compose behind your existing Nginx Proxy Manager.

## Status

**Phase 1 (this commit): foundation + Windows monitoring.** The config has been syntax-checked only. It has **not been started on a Docker host yet**, so expect first-boot fixes. Image tags in `.env.example` are the last versions known when written; check for newer releases before deploying.

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

### Configure authentik (once, in the UI)

1. Sign in at `https://AUTH_HOST/if/flow/initial-setup/` as `akadmin` (password printed by `init-secrets.sh`). Create your named admin user, then disable or lock down `akadmin`.
2. **MFA**: Flows & Stages → Stages → edit the default *Authenticator Validation* stage (in `default-authentication-mfa-validation`): set *Not configured action* to **Force the user to configure an authenticator**, allow TOTP and WebAuthn. Fewer options is better. Prefer WebAuthn for staff.
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

### Install the Windows agent

Download `telegraf.exe` from the vendor's release page and note its published SHA256. On the customer PC (elevated PowerShell), with `telegraf.exe` next to the scripts in `agent/windows/`:

```powershell
.\install-agent.ps1 -Customer acme -IngestHost ingest.example.com `
  -InfluxWriteToken <from credentials file> -LokiPushKey <from credentials file> `
  -TelegrafSha256 <published hash>
```

## Security notes

- Secrets are Docker secrets from `./secrets` (dir mode 700), never in `.env` or the compose file. Back `./secrets` up offline; it is excluded from git.
- Data stores are on an `internal` Docker network with no published ports and no internet access.
- The gateway exposes only the two write paths agents need, rate-limits, caps body size, and never logs credentials.
- Agent credentials are per-customer and write-only; a stolen agent token cannot read anything. Rotate by re-running onboarding for a new key (revocation tooling comes with a later phase).
- The agent does **not** ship the Windows Security log (it contains sensitive data). Add specific event IDs deliberately if you need them.
- Grafana's login form is disabled; everything goes through authentik. Break-glass is the `msp-admin` API account; re-enable the form by overriding `GF_AUTH_DISABLE_LOGIN_FORM`.
- Known gaps for now: no backups yet (phase 5), no SIEM-style alerting, containers not yet hardened beyond `no-new-privileges` and a read-only gateway. Don't put real customer data on it until backups and a restore test exist.
