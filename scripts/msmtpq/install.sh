#!/usr/bin/env bash
# Installs msmtpq-sendmail on rpi5-1 as the system sendmail, and adds a cron
# job to flush the queue. Idempotent. Run on rpi5-1 from this directory.
# See docs/email-alerts.md.
set -euo pipefail

cd "$(dirname "$0")"

sudo install -m 0755 msmtpq-sendmail /usr/local/bin/msmtpq-sendmail

# msmtp-mta owns both sendmail symlinks; divert them so package upgrades
# don't silently put the non-queueing msmtp back.
for f in /usr/sbin/sendmail /usr/lib/sendmail; do
  if ! dpkg-divert --list "$f" | grep -q .; then
    sudo dpkg-divert --local --rename --divert "$f.msmtp-mta" --add "$f"
  fi
  sudo ln -sfn /usr/local/bin/msmtpq-sendmail "$f"
done

# Flush job. Output fully discarded: with MAILTO set, any output would itself
# be mailed via the queue it's failing to flush. Results go to
# ~/.msmtp.queue.log.
FLUSH='*/15 * * * * /usr/local/bin/msmtpq-sendmail --q-mgmt -r > /dev/null 2>&1'
if ! crontab -l 2>/dev/null | grep -qF -- "$FLUSH"; then
  (crontab -l 2>/dev/null; echo "$FLUSH") | crontab -
fi

echo "sendmail -> $(readlink -f /usr/sbin/sendmail)"
crontab -l | grep -F msmtpq-sendmail
