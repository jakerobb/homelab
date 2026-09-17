# Email alerts (Brevo relay)

Outbound email for cron/alerting, relayed through Brevo rather than
self-hosting an MTA (homelab IPs have no sending reputation and most
residential ISPs block outbound port 25 anyway). First consumer is
`scripts/etcd-snapshot-backup.sh`'s cron job on rpi5-1, which was silently
failing every night (see [`etcd-backup.md`](etcd-backup.md) history / TODO)
with no way to find out short of noticing a stale snapshot by hand.

SendGrid was the original choice, but its free tier no longer allows any
sending at all (`451 ... Maximum credits exceeded`) — the cheapest paid plan
allowing sends is ~$20/month, not worth it for a handful of emails a day.
Switched to Brevo instead (free tier: 300 emails/day, no expiry).

## Domain authentication

`jakerobb.org` is domain-authenticated in Brevo (Senders, Domains &
Dedicated IPs) as of 2026-09-17, via Brevo's own Cloudflare integration —
it created its DKIM (`brevo1`/`brevo2._domainkey`), mail-branding
(`mail`/`r.mail`/`img.mail`), and root verification TXT records directly,
and appended its DMARC reporting address (`rua=mailto:rua@dmarc.brevo.com`)
to the existing `_dmarc` TXT record. No manual DNS work needed this time.

Leftover from the abandoned SendGrid attempt (harmless but unused — added
manually via the Cloudflare API before switching providers, never cleaned
up): `23632814`, `em9710`, `s1._domainkey`, `s2._domainkey`, and `url7765`
CNAMEs under `jakerobb.org`. Safe to delete whenever, not currently
referenced by anything.

Not tracked as Terraform/IaC — one-time, unlikely-to-change zone
configuration, same reasoning as other Cloudflare-console-managed pieces.

## Secret

`scripts/secrets/msmtprc.sops.yaml` (matched by the
`scripts/secrets/.*\.sops\.(yaml|json|env)$` rule in `.sops.yaml`) holds a
complete `msmtp` config file, encrypted whole (binary mode, same pattern as
`docker-compose/secrets/nut-upsd-password.sops.yaml`) since its format isn't
YAML/JSON. Contains the Brevo SMTP key as the password, and Brevo's assigned
SMTP login (not a real mailbox — a generated identifier tied to the API
key) as the user.

Decrypt and deploy to rpi5-1:

```bash
sops -d --output-type binary scripts/secrets/msmtprc.sops.yaml > ~/.msmtprc
chmod 600 ~/.msmtprc
```

To edit in place (decrypts, opens `$EDITOR`, re-encrypts on save):

```bash
sops scripts/secrets/msmtprc.sops.yaml
```

Brevo also restricts SMTP/API access to explicitly authorized sending IPs
(SendGrid didn't have this). rpi5-1's static public IP is authorized under
Brevo's **SMTP & API → Authorized IPs**. If the home IP ever changes, mail
will start failing with `525 5.7.1 Unauthorized IP address` until the new
IP is added there.

## Wiring a cron job to mail on failure

Requires `msmtp-mta` installed on rpi5-1 (provides `/usr/sbin/sendmail`, so
cron's own mail-on-output behavior works unmodified):

```bash
sudo apt install msmtp-mta
```

Crontab needs `MAILTO` set, and the job's own stdout redirected away so only
a real failure (which lands on stderr, given `set -euo pipefail`) triggers a
mail — otherwise every successful run's normal output would also mail:

```
MAILTO=jakerobb@gmail.com
15 3 * * * /home/jakerobb/bin/etcd-snapshot-backup.sh > /dev/null
```

**Done and verified (2026-09-17):** deployed above, and tested end-to-end
with a deliberately-broken copy of the script (bad node IP) — the resulting
stderr was mailed through cron's real mechanism and arrived from
`noreply@jakerobb.org` via Brevo.

## Known gap: no queuing if the relay is unreachable

`msmtp` sends synchronously — if the ISP or Brevo is down at 3:15 AM when
the cron job runs, the alert email itself is silently lost (no retry), which
defeats the point if a failure and an outage coincide. Not fixed yet;
options considered:

- **`msmtpq`** (bundled with `msmtp`, see
  `/usr/share/doc/msmtp/examples/msmtpqueue/`) — lightweight file-based
  queue wrapper around the same `msmtp` config already in place. Swap the
  `/usr/sbin/sendmail` symlink to point at it instead, add a periodic
  (systemd timer or cron) call to flush the queue. Low effort, no new
  daemon.
- **Postfix as a local smarthost** (`relayhost` pointed at Brevo, SASL auth)
  — real MTA queue with proper retry/backoff, but a whole extra service to
  maintain on a host that's otherwise just a jump box.

`msmtpq` is the better fit here given the low stakes and desire to avoid
adding daemons to rpi5-1 — deferred rather than done, since an ISP outage
overlapping exactly with a backup failure is a narrow edge case for a
homelab. Revisit if this ever matters in practice.
