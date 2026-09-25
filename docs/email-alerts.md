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

## Queuing when the relay is unreachable (msmtpq)

`msmtp` on its own sends synchronously: if the ISP or Brevo were down at
3:15 AM, a failure alert would be lost with no retry. As of 2026-09-25,
rpi5-1's `sendmail` is [`scripts/msmtpq/msmtpq-sendmail`](../scripts/msmtpq/msmtpq-sendmail),
a thin wrapper around Debian's bundled `msmtpq`
(`/usr/libexec/msmtp/msmtpq/msmtpq`) using the same `~/.msmtprc`. A failed
send stays in `~/.msmtp.queue/` instead of being dropped, and a cron job
retries it every 15 minutes. Postfix as a local smarthost was considered and
rejected, since it would add a whole daemon to what is otherwise a jump box.

Install or reinstall (idempotent) on rpi5-1:

```bash
~/dev/homelab/scripts/msmtpq/install.sh
```

What it does:

- installs the wrapper to `/usr/local/bin/msmtpq-sendmail`
- `dpkg-divert`s `msmtp-mta`'s `/usr/sbin/sendmail` and `/usr/lib/sendmail`
  symlinks (to `*.msmtp-mta`) and points them at the wrapper, so an
  `msmtp-mta` upgrade can't silently put non-queueing `msmtp` back
- adds the flush job to the crontab:
  `*/15 * * * * /usr/local/bin/msmtpq-sendmail --q-mgmt -r > /dev/null 2>&1`.
  All output is discarded on purpose: with `MAILTO` set, any output would
  be mailed through the same queue it is failing to flush.

Wrapper details:

- **`HOME` fallback.** cron runs its mailer with `HOME` unset, and `msmtpq`
  expands `~` from it. Without the fallback, the first cron test tried to
  create `/.msmtp.queue` and the mail was lost.
- **No connectivity pre-check** (`EMAIL_CONN_TEST=x`). `msmtpq`'s default
  pings debian.org before sending, which adds an ICMP failure mode
  unrelated to SMTP. A failed `msmtp` send is queued anyway.

Queue log: `~/.msmtp.queue.log`. Successful sends are still logged in
`~/.msmtp.log`. To inspect or manage the queue:

```bash
msmtpq-sendmail --q-mgmt -d
```

```bash
msmtpq-sendmail --q-mgmt -r
```

(`-d` lists the queue, `-r` flushes it now; `-h` shows the other options.)

**Verified (2026-09-25):**

- A send through `sendmail` with `MSMTP` pointed at a stub that always
  fails was queued (exit 0). `--q-mgmt -r` then delivered it via Brevo.
- A temporary `* * * * *` crontab entry writing to stderr was delivered
  through cron's real `MAILTO` → `/usr/sbin/sendmail` path.

`scripts/unifi-gc-report.py` sends its reports through `/usr/sbin/sendmail`
too (as of 2026-09-25; it used to call `msmtp` directly), so they are
queued the same way.
