#!/usr/bin/env bash
# Installs msmtpq-sendmail on rpi5-1 as the system sendmail and installs its
# SMTP credentials. (The queue-flush cron job is in scripts/rpi5-cron/.)
# Idempotent. Run on rpi5-1 from this directory.
# See docs/email-alerts.md.
set -euo pipefail

cd "$(dirname "$0")"

sudo install -m 0755 msmtpq-sendmail /usr/local/bin/msmtpq-sendmail

# The SMTP credentials: decrypt the SOPS secret into ~/.msmtprc (mode 600), and
# record the sha256 of the encrypted file next to it, world-readable. The
# compose-deploy cron compares that hash with the repo's file and raises an ntfy
# alert when the secret changed and this script needs re-running.
tmp="$(umask 077 && mktemp "$HOME/.msmtprc.XXXXXX")"
sops --decrypt --output-type binary ../secrets/msmtprc.sops.yaml > "$tmp"
mv "$tmp" "$HOME/.msmtprc"
sha256sum ../secrets/msmtprc.sops.yaml | cut -d' ' -f1 > "$HOME/.msmtprc.sops.sha256"
chmod 644 "$HOME/.msmtprc.sops.sha256"

# msmtp-mta owns both sendmail symlinks; divert them so package upgrades
# don't silently put the non-queueing msmtp back.
for f in /usr/sbin/sendmail /usr/lib/sendmail; do
  if ! dpkg-divert --list "$f" | grep -q .; then
    sudo dpkg-divert --local --rename --divert "$f.msmtp-mta" --add "$f"
  fi
  sudo ln -sfn /usr/local/bin/msmtpq-sendmail "$f"
done

# The queue-flush cron job lives in scripts/rpi5-cron/ (homelab-msmtpq-flush).

echo "sendmail -> $(readlink -f /usr/sbin/sendmail)"
