#!/usr/bin/env bash
# Unlocks the Mac Studio's FileVault over SSH when it is sitting at the unlock screen and its Talos worker is down.
# Runs on rpi5-1 every minute from studio-unlock-watchdog.timer. See ../../docs/studio-unlock-watchdog.md.
#
# How it tells "locked" from "up", without any key on the Studio: before the unlock, the Mac answers on TCP 22 (the
# pre-boot SSH server) but runs no LaunchDaemons, so Telegraf's :9273 and the Talos worker's :50000 are closed. After
# the unlock both open. The decision table, in order:
#   worker (:50000) open              -> healthy; reset all state
#   Studio :22 closed                 -> off or mid-boot; nothing to unlock; reset the locked counter
#   Studio :22 open, :9273 open       -> unlocked, but the worker is down (the VM daemon, not FileVault); alert only
#   Studio :22 open, :9273 closed     -> looks locked; after LOCKED_THRESHOLD runs in a row, try the unlock
# The unlock is a password SSH login, which the pre-boot server accepts for FileVault users; the connection is then
# closed as the Mac continues booting. Retries are rate-limited (COOLDOWN) and capped (MAX_ATTEMPTS): a wrong or
# changed password must not turn into a stream of failed logins.
set -uo pipefail

STUDIO_HOST="${STUDIO_HOST:-192.168.102.22}"
WORKER_HOST="${WORKER_HOST:-192.168.102.36}"
WORKER_PORT="${WORKER_PORT:-50000}"
TELEGRAF_PORT="${TELEGRAF_PORT:-9273}"
SSH_PORT="${SSH_PORT:-22}"
SECRETS_FILE="${SECRETS_FILE:-$HOME/bin/secrets/studio-unlock.sops.yaml}"
STATE_DIR="${STATE_DIR:-/var/lib/studio-unlock-watchdog}"
KNOWN_HOSTS="${KNOWN_HOSTS:-$STATE_DIR/known_hosts}"
ASKPASS="${ASKPASS:-/usr/local/lib/studio-unlock-watchdog/askpass.sh}"
LOCKED_THRESHOLD="${LOCKED_THRESHOLD:-3}"          # consecutive runs that look locked before acting (1 per minute)
COOLDOWN="${COOLDOWN:-900}"                        # seconds between unlock attempts
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"                  # attempts before giving up and alerting
BOOT_WAIT="${BOOT_WAIT:-240}"                      # seconds to wait for Telegraf to appear after an attempt
UNLOCKED_DOWN_ALERT="${UNLOCKED_DOWN_ALERT:-900}"  # seconds the worker may be down on an unlocked Mac before alerting
NTFY_URL="${NTFY_URL:-https://ntfy.jakerobb.org/homelab-alerts}"
DRY_RUN="${DRY_RUN:-0}"

log() { echo "studio-unlock-watchdog: $*"; }

notify() {  # notify <priority 1-5> <title> <message>
  log "notify: $2 - $3"
  [ "$DRY_RUN" = 1 ] && return 0
  curl -fsS -m 10 -H "Title: $2" -H "Priority: $1" -H "Tags: lock" -d "$3" "$NTFY_URL" >/dev/null 2>&1 \
    || log "(ntfy unreachable; the message is only in the journal)"
}

port_open() { timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }

mkdir -p "${STATE_DIR:?}"
get() { cat "${STATE_DIR:?}/$1" 2>/dev/null || echo "${2:-0}"; }
put() { printf '%s\n' "$2" > "${STATE_DIR:?}/$1"; }
drop() { local f; for f in "$@"; do rm -f "${STATE_DIR:?}/$f"; done; }
clear_state() { drop locked_count attempts last_attempt gave_up worker_down_since unlocked_alerted; }
now="$(date +%s)"

if port_open "$WORKER_HOST" "$WORKER_PORT"; then
  if [ -e "$STATE_DIR/attempts" ] || [ -e "$STATE_DIR/gave_up" ]; then
    notify 3 "Studio worker is back" "talos-worker-studio answers on $WORKER_HOST:$WORKER_PORT again."
  fi
  clear_state
  log "healthy: worker answers on $WORKER_HOST:$WORKER_PORT"
  exit 0
fi

[ -e "$STATE_DIR/worker_down_since" ] || put worker_down_since "$now"

if ! port_open "$STUDIO_HOST" "$SSH_PORT"; then
  put locked_count 0
  log "Studio $STUDIO_HOST:$SSH_PORT is closed (off or still booting); nothing to unlock"
  exit 0
fi

if port_open "$STUDIO_HOST" "$TELEGRAF_PORT"; then
  put locked_count 0
  down_for=$(( now - $(get worker_down_since "$now") ))
  log "Studio is unlocked (Telegraf answers) but the worker has been down for ${down_for}s"
  if [ "$down_for" -ge "$UNLOCKED_DOWN_ALERT" ] && [ ! -e "$STATE_DIR/unlocked_alerted" ]; then
    put unlocked_alerted 1
    notify 4 "Studio worker down, Mac is up" "The Studio is unlocked but talos-worker-studio has been down for $((down_for / 60)) minutes. Check the VM daemon: sudo launchctl print system/com.jakerobb.talos-worker-studio, and /var/log/talos-worker-studio.log on the Studio."
  fi
  exit 0
fi

locked_count=$(( $(get locked_count) + 1 ))
put locked_count "$locked_count"
log "Studio looks locked or still booting ($locked_count/$LOCKED_THRESHOLD)"
[ "$locked_count" -ge "$LOCKED_THRESHOLD" ] || exit 0

attempts="$(get attempts)"
if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
  if [ ! -e "$STATE_DIR/gave_up" ]; then
    put gave_up 1
    notify 5 "Studio unlock gave up" "$attempts unlock attempts did not bring the Studio up. Unlock it by hand (ssh to it with the account password, or at the keyboard), then check the stored password. State is in $STATE_DIR; it resets itself once the worker answers."
  fi
  log "giving up after $attempts attempts"
  exit 0
fi

since_last=$(( now - $(get last_attempt 0) ))
if [ "$since_last" -lt "$COOLDOWN" ]; then
  log "last attempt was ${since_last}s ago; waiting for the ${COOLDOWN}s cooldown"
  exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
  log "DRY RUN: would SSH to $STUDIO_HOST with the stored password (attempt $((attempts + 1))/$MAX_ATTEMPTS)"
  exit 0
fi

put attempts $(( attempts + 1 ))
put last_attempt "$now"

user="$(sops -d --extract '["user"]' "$SECRETS_FILE" 2>/dev/null)" || { notify 5 "Studio unlock can't read its secret" "sops could not decrypt $SECRETS_FILE on $(hostname)."; exit 1; }
notify 3 "Unlocking the Studio" "Attempt $((attempts + 1))/$MAX_ATTEMPTS: it has looked locked for $locked_count minutes."

# SSH_ASKPASS_REQUIRE=force makes ssh use the helper with no terminal. Only password auth is offered, and the host
# key must match the pinned one, so the password can't go to anything else.
SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force STUDIO_UNLOCK_SECRETS="$SECRETS_FILE" \
  ssh -o BatchMode=no -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive \
      -o NumberOfPasswordPrompts=1 -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" \
      -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
      "$user@$STUDIO_HOST" true >/dev/null 2>&1
ssh_rc=$?
log "ssh exited $ssh_rc (the connection closing as the Mac boots is normal)"

deadline=$(( $(date +%s) + BOOT_WAIT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if port_open "$STUDIO_HOST" "$TELEGRAF_PORT"; then
    put locked_count 0
    notify 3 "Studio unlocked" "Telegraf is answering on $STUDIO_HOST:$TELEGRAF_PORT. The worker VM should rejoin within a few minutes."
    exit 0
  fi
  sleep 10
done
log "no sign of Telegraf $BOOT_WAIT s after the attempt; will retry after the cooldown"
exit 0
