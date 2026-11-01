# Unified portal: design (draft for approval)

Goal: one web application that is the whole product. People sign in once, pick a company once, and do everything from
there: see computers, health and graphs, encryption, backups, alerts, and connect to a computer. Grafana, MeshCentral,
InfluxDB, Loki and authentik keep running, but as engines behind the application. Nobody has to open them directly.

Nothing here is built yet. Approve or change the shape first.

## Principles

1. **One front door.** One address, one sign-in, one navigation, one company picker, one look.
2. **The engines stay.** InfluxDB, Loki, restic, authentik, MeshCentral and Postgres are not replaced. Only what
   people look at changes.
3. **Query, never copy.** The portal reads InfluxDB and Loki directly (as it does for Computers today). Postgres keeps
   only what the portal itself owns: customers, requests, keys, audit, catalog.
4. **Isolation is enforced in the portal's data layer**, not in the screens. Every query takes the signed-in person's
   scope (see `lib/authz.ts`). A page cannot forget to filter, because there is no way to run a query without a scope.
5. **Strangler build.** The new app runs next to the old one and takes over one section at a time. The agents keep
   talking to the old portal until the very end.
6. **Everything staff do is audited**, as BitLocker key reveals are today.

## Screens

Left navigation, company picker in the top bar (carried to every page; also settable by link).

| Area | Page | Who | Replaces |
|---|---|---|---|
| Overview | Company overview: health tiles (computers up, backups ok, unencrypted, open alerts, pending requests) | all | Home, Grafana landing |
| Computers | List with health, backup, encryption, last seen, filters | all | Computers page, Grafana Windows overview table |
| Computers | **Computer detail**: header (name, site, online), tabs Health, Backup, Encryption, Events, Software/Services | all (some tabs staff only) | machine page, Grafana per-host panels, Encryption page |
| Computers | **Connect** button: remote desktop / terminal / files | staff | opening MeshCentral by hand |
| Data protection | Backups, schedule, folders, browse and restore, replace this computer | all (replace staff only) | existing backup pages (kept as they are, restyled) |
| Encryption | Fleet encryption list, request to turn on, recovery key list and reveal | staff (customers see state only) | Encryption page (already native) |
| Alerts | Open and recent alerts per company, acknowledge | staff | Grafana alert views |
| Logs | Search a company's logs (Windows event logs) | staff | Grafana Explore on Loki |
| Settings | Sites, users and groups view, monitoring-agent status, auto-deploy status | staff, admins | scripts and Mesh/Grafana admin screens |

Customers get a smaller menu: Overview, Computers (read-only health), Data protection. They never see Grafana,
MeshCentral or authentik screens.

## Where each screen's data comes from

| Data | Engine | How the portal gets it |
|---|---|---|
| Health, CPU, disk, services, BitLocker state | InfluxDB, bucket `cust_<slug>` | Flux over HTTP with the read-only org token; the scope picks the buckets |
| Event logs | Loki, tenant = customer | HTTP with the tenant header set by the portal from the scope, never from the browser |
| Backups, schedule, catalog, replacements | Postgres + restic maintenance output | as today |
| Recovery keys, BitLocker requests, audit | Postgres | as today |
| Remote control, run script, deploy agent | MeshCentral | API through a limited service account (like `svc-autodeploy`); never the person's own login |
| Who someone is, which groups | authentik | OIDC groups claim, as today |
| Alerts | Grafana alert rules, or portal-owned rules (decision below) | see open decisions |

Charts are drawn by the portal itself (one chart library, same colors as the rest of the app). The Grafana
dashboards remain available to admins during the transition and can be retired when the native pages cover them.

## Connect flow (MeshCentral)

1. Staff clicks Connect on a computer. The portal checks `isStaffFor(scope, customer)` and writes an audit entry.
2. The portal opens MeshCentral's own viewer for that one device, in a frame inside the portal page or a new tab, using
   a deep link with the interface trimmed down (side menu and header hidden).
3. Sign-in is the existing authentik session, so there is no second login.
4. MeshCentral is re-themed (title, logo, colors, login and welcome text, small stylesheet override) so the viewer looks like
   a part of the portal. The viewer's own toolbar stays MeshCentral's.
5. Requirements to verify against the running version (1.2.6) before relying on them: framing allowed for the portal's
   origin, session cookie settings that work inside a frame (portal and remote on the same parent domain), the exact
   deep-link parameters, and how the stylesheet override survives upgrades. The first build task is a one-computer proof.

Customers do not get Connect. Remote access stays staff-only, as today.

## Security rules for the new app

- Browser never sees an engine token. The portal server holds them (read-only Influx, Loki tenant header, Mesh service
  account) and every call is scoped by the person's groups.
- Engine endpoints (Grafana, MeshCentral admin, Influx, Loki) stay unreachable from the internet except what is needed to
  display the viewer; admin screens can be limited to the admin group at the reverse proxy.
- The Mesh service account is separate from `svc-autodeploy` (different rights: remote control only, no deployment) and its
  password is a Docker secret.
- Same rules as now for escrow keys: staff only, reason required, audited, 60 second display.
- `scripts/test-isolation.sh` grows tests for the new pages: a user of company A gets nothing, and the same 404 as
  a nonexistent item, for company B on every route including Loki and chart endpoints.

## Build order (each step is usable on its own)

1. **Foundation.** New app folder next to the portal, same stack (Next.js, TypeScript), shared `lib/` for scope, audit and
   Influx. New shell: navigation, top bar, picker, theme. Runs on its own hostname on the same VM. Proof of Connect for
   one computer.
2. **Computers and Computer detail.** Move the Computers page, add the detail page with Health tab (native charts),
   Backup tab and Encryption tab, and Connect.
3. **Overview and Alerts.** Company overview tiles, alerts list, logs search.
4. **Fold in the backup pages and Encryption**, restyled; same Postgres tables, no data migration.
5. **Settings.** Sites, agent status, auto-deploy status.
6. **Cutover.** New app takes the main address; the old portal keeps only the agent endpoints (`/api/agent/*`,
   heartbeat, jobs) until they are moved, last. Grafana and MeshCentral move behind an admin-only address.

Each step ends with: isolation tests passing, deployed beside the old app, you look at it before anything switches.

## What does not change

- Agents, enrollment, the long-poll, the backup servers and every host timer.
- All data. There is no migration of metrics, logs, backups or keys.
- Groups in authentik, and the meaning of `msp-admins`, `tech-<slug>`, `cust-<slug>-users`.

## Risks

- **Rebuilding Grafana's charts is the biggest cost.** Mitigation: only rebuild what people actually use (start with
  CPU, memory, disk, services, uptime, backup age, BitLocker), keep Grafana for admins until covered.
- **MeshCentral viewer customization is limited** and tied to its version. Mitigation: small overrides only, proof first.
- **Two portals during the build** means two places for a change. Mitigation: shared `lib/`, and move sections rather than copy.
- **Alerts**: Grafana currently evaluates alert rules. If the new app is to own them, it needs its own rule evaluation
  (see decision 1).

## Branding

The product name is a placeholder: **MSP Console**. Everything that carries a name or a look lives in one place so it can be
swapped in minutes: `brand.ts` (product name, short name, tagline, support address, logo file, favicon) and a set of CSS
variables (colors, fonts, radius). No page, email or message hard-codes the name. MeshCentral's title and logo and the
authentik login page are set from the same values by one script, so a rename touches one file and one command.

## Decisions

1. **Alerts:** Grafana stays the alert engine at first; its alerts arrive in the portal by webhook, and the portal owns
   the alert records, notifications and (later) tickets. Grafana can be retired once the portal evaluates the rules itself
   (see "Do we need Grafana in the end?").
2. **Remote control:** MeshCentral Connect is for our own technicians only. Customers never connect to their computers.
3. **Hostname:** `msp.caltechnologysolutions.com` is the new app's address, during the build and after. At cutover the old
   portal's address redirects to it, and only the agent endpoints stay on the old host until they are moved.
4. **Ticketing** (roadmap phase 3) will be built in this same app once monitoring and the app screens are running. Alerts
   are designed now so that an alert can become a ticket later: one alert record, a status, an owner, and a link to the
   computer.

## Do we need Grafana in the end?

No. Grafana does three jobs: dashboards, alert evaluation, and ad-hoc exploring. A finished app can cover all three:

| Job | Native replacement | Cost |
|---|---|---|
| Dashboards | Native charts on the Computer and Overview pages | Moderate: one chart component, then one query per panel |
| Alerts | Rules (condition, duration, severity), a scheduler that evaluates them, state (ok, firing, acknowledged), de-duplication, notification channels (email, Teams, SMS), silences, alert-to-ticket | The real work: a few sessions, and it has to be trustworthy |
| Exploring | Logs search page; a query box for admins; InfluxDB's own UI remains for admins | Small |

Dropping Grafana also removes the per-customer org setup and the dashboard build scripts. But it is the one piece that
already works well and costs nothing to keep running, so there is no rush. The path keeps both options open:

1. Grafana alerts → webhook → portal stores them and shows them (small, useful immediately).
2. Portal sends the notifications and creates tickets from those alerts.
3. Portal evaluates its own rules; Grafana becomes an optional admin-only tool, then is switched off when nobody opens it.
