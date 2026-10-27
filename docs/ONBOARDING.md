# Onboarding a customer

Use this for every new customer. Commands run on the VM from the app directory (`/srv/msp/app`), with `sudo` where shown.

## Before you start (once per customer)

- [ ] Signed agreement is in place. If they hold patient data: **a BAA is signed** and your compliance review is done. Do not install anything before that.
- [ ] You know the customer's slug (2-31 characters, `a-z 0-9 -`), display name and locations.
- [ ] You decided what to back up (usually the file server and any PC with local data) and how long to keep monitoring data (default 90 days).
- [ ] You can reach the customer's PCs through an installer link or MeshCentral invitation, and you know who to ask at the customer.

## 1. Create the customer and its first site

```bash
scripts/mesh-token.sh set          # paste a login token (MeshCentral -> My Account -> Create login token), username line 1, password line 2
scripts/add-customer.sh acme "Acme Corp" 90
```

This creates the data bucket, log tenant, Grafana org, authentik groups `tech-acme` and `cust-acme-users`, the first site `main`, and (with a token stored) its MeshCentral device group with notify-and-toolbar consent. Extra locations: `scripts/add-site.sh acme branch "Branch office"`.

## 2. People

- [ ] In authentik add your technicians to `tech-acme`.
- [ ] Add the customer's own users to `cust-acme-users`. Each enrols a TOTP authenticator at first sign-in.
- [ ] After a technician first signs in, run `scripts/mesh-grant.sh` so they can reach the customer's device group.

## 3. Get the PCs under management

```bash
scripts/mesh-invite.sh acme main 24     # link valid 24 hours; send it privately
```

When a PC shows up online in MeshCentral:

```bash
scripts/mesh-deploy-monitoring.sh acme main --yes     # install the monitoring agent on every online PC of the site
```

Check the customer's Grafana dashboard fills in (within a minute or two).

## 4. Back up the computers that matter

```bash
scripts/mesh-deploy-backup.sh acme main --device DC01 --register --run-now
```

This registers the machine (server login, repository, portal token), builds its installer, installs it through MeshCentral and starts the first backup. Then:

- [ ] Open the portal, find the computer, and confirm the first backup completes.
- [ ] **Choose the schedule with the customer** (Schedule page). Avoid 06:00 (NAS snapshot) and 10:00 (maintenance).
- [ ] Copy the repository password from `generated/backup/credentials/acme/main/<host>.txt` into your vault. Without it the backups cannot be read.
- [ ] Do a **test restore** of a few files with the customer watching. This is the proof, not the green tick.
- [ ] `sudo scripts/backup-list.sh acme main` shows each computer as protected, stale, or not backed up.

## 5. First-week watch list (internet and capacity)

The first full backup of a site is the biggest load you will see. Note these per customer:

| Item | Where to look | Worry if |
|---|---|---|
| First backup duration and size | Portal computer page | Several nights without finishing |
| Upload speed | Duration against data added | The line is saturated during business hours (move the schedule) |
| Failed or partial backups | Portal dashboard, Backups panel | Anything other than ok |
| Maintenance verdicts | `systemctl status msp-backup-maintain` | Failed (stale, check, or restore test) |
| Agent memory | Task Manager on a PC | Telegraf over ~300 MB |
| NAS space | `df -h /srv/msp-backups` | Over 70 percent of the dataset quota |

## 6. Hand-over

- [ ] Tell the customer how to restore a file and who to call.
- [ ] Record the customer in your documentation: sites, computers, schedule, contacts, vault entries.
- [ ] `scripts/mesh-token.sh clear` when you finish.

## Ending a customer

```bash
scripts/offboard-customer.sh acme                         # report what exists
scripts/offboard-customer.sh acme --suspend               # cut every credential and all access, keep the data
scripts/offboard-customer.sh acme --purge --confirm acme  # later, after your retention period: delete the data permanently
```

Every run is logged to `generated/offboard-audit.log`. Also remove the customer's vault entries and any off-site copies yourself.
