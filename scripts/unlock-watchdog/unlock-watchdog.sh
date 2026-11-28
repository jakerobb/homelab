#!/usr/bin/env bash
# Unlocks a Mac's FileVault over SSH when it is sitting at the unlock screen and its Talos worker is down.
# Usage: unlock-watchdog.sh <host>   (host = a file in hosts/: studio, mbp)
# Runs on rpi5-1 every minute, one unlock-watchdog@<host>.timer per Mac. See ../../docs/unlock-watchdog.md.
#
# How it tells "locked" from "up", without any key on the Mac: before the unlock, the Mac answers on TCP 22 (the
# pre-boot SSH server) but runs no LaunchDaemons, so Telegraf's :9273 and the Talos worker's :50000 are closed. After
# the unlock both open. The decision table, in order:
#   worker (:50000) open              -> healthy; reset all state
#   Mac :22 closed                    -> off or mid-boot; nothing to unlock; reset the locked counter
#   Mac :22 open, :9273 open          -> unlocked, but the worker is down (the VM daemon, not FileVault); alert only
#   Mac :22 open, :9273 closed        -> looks locked; after LOCKED_THRESHOLD runs in a row, try the unlock
# UNLOCK_MODE=alert (hosts/<name>.env) never tries the unlock: when the worker is down and the Mac's Telegraf isn't up,
# it alerts once that the Mac needs unlocking by hand (and says whether it answers ping and :22), then repeats the alert
# every REALERT seconds until the worker is back. Used for the MacBook Pro, which has no network at the FileVault screen.
# The unlock is a password SSH login, which the pre-boot server accepts for FileVault users; the connection is then
# closed as the Mac continues booting. Retries are rate-limited (COOLDOWN) and capped (MAX_ATTEMPTS): a wrong or
# changed password must not turn into a stream of failed logins.
set -uo pipefail

NAME="${1:?usage: unlock-watchdog.sh <host>  (a file in hosts/, e.g. studio or mbp)}"
case "$NAME" in *[!a-z0-9-]*) echo "bad host name: $NAME" >&2; exit 64 ;; esac
LIB="$(cd "$(dirname "$0")" && pwd)"
[ -f "$LIB/hosts/$NAME.env" ] || { echo "no $LIB/hosts/$NAME.env" >&2; exit 64; }
# Per-host settings: LABEL, HOST, WORKER_NAME, WORKER_HOST, SECRETS_FILE, and optionally UNLOCK_MODE.
# shellcheck source=/dev/null
. "$LIB/hosts/$NAME.env"
: "${LABEL:?}" "${HOST:?}" "${WORKER_NAME:?}" "${WORKER_HOST:?}" "${SECRETS_FILE:?}"
WORKER_PORT="${WORKER_PORT:-50000}"
TELEGRAF_PORT="${TELEGRAF_PORT:-9273}"
SSH_PORT="${SSH_PORT:-22}"
STATE_DIR="${STATE_DIR:-/var/lib/unlock-watchdog/$NAME}"
KNOWN_HOSTS="${KNOWN_HOSTS:-$STATE_DIR/known_hosts}"
ASKPASS="${ASKPASS:-$LIB/askpass.sh}"
LOCKED_THRESHOLD="${LOCKED_THRESHOLD:-3}"          # consecutive runs that look locked before acting (1 per minute)
COOLDOWN="${COOLDOWN:-900}"                        # seconds between unlock attempts
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"                  # attempts before giving up and alerting
BOOT_WAIT="${BOOT_WAIT:-240}"                      # seconds to wait for Telegraf to appear after an attempt
UNLOCK_MODE="${UNLOCK_MODE:-auto}"                 # auto: unlock it; alert: only tell me it needs unlocking by hand
DOWN_ALERT="${DOWN_ALERT:-600}"                    # alert mode: seconds the worker may be down, Mac silent, before alerting
REALERT="${REALERT:-3600}"                         # alert mode: seconds between repeats of that alert
UNLOCKED_DOWN_ALERT="${UNLOCKED_DOWN_ALERT:-900}"  # seconds the worker may be down on an unlocked Mac before alerting
NTFY_URL="${NTFY_URL:-https://ntfy.jakerobb.org/homelab-alerts}"
DRY_RUN="${DRY_RUN:-0}"

log() { echo "unlock-watchdog[$NAME]: $*"; }

notify() {  # notify <priority 1-5> <title> <message>
  log "notify: $2 - $3"
  [ "$DRY_RUN" = 1 ] && return 0
  curl -fsS -m 10 -H "Title: $2" -H "Priority: $1" -H "Tags: lock" -d "$3" "$NTFY_URL" >/dev/null 2>&1 \
    || log "(ntfy unreachable; the message is only in the journal)"
}

ping_ok() { ping -c 2 -W 2 "$1" >/dev/null 2>&1; }

port_open() { timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }

mkdir -p "${STATE_DIR:?}"
get() { cat "${STATE_DIR:?}/$1" 2>/dev/null || echo "${2:-0}"; }
put() { printf '%s\n' "$2" > "${STATE_DIR:?}/$1"; }
drop() { local f; for f in "$@"; do rm -f "${STATE_DIR:?}/$f"; done; }
clear_state() { drop locked_count attempts last_attempt gave_up worker_down_since unlocked_alerted host_down_alerted; }
now="$(date +%s)"

if port_open "$WORKER_HOST" "$WORKER_PORT"; then
  if [ -e "$STATE_DIR/attempts" ] || [ -e "$STATE_DIR/gave_up" ] || [ -e "$STATE_DIR/host_down_alerted" ]; then
    notify 3 "$LABEL worker is back" "$WORKER_NAME answers on $WORKER_HOST:$WORKER_PORT again."
  fi
  clear_state
  log "healthy: worker answers on $WORKER_HOST:$WORKER_PORT"
  exit 0
fi

[ -e "$STATE_DIR/worker_down_since" ] || put worker_down_since "$now"

if [ "$UNLOCK_MODE" = alert ] && ! port_open "$HOST" "$TELEGRAF_PORT"; then
  down_for=$(( now - $(get worker_down_since "$now") ))
  if ping_ok "$HOST"; then pings=yes; else pings=no; fi
  if port_open "$HOST" "$SSH_PORT"; then ssh_state=open; else ssh_state=closed; fi
  log "$LABEL isn't running its services (ping: $pings, :$SSH_PORT $ssh_state); worker down for ${down_for}s"
  last_alert="$(get host_down_alerted 0)"
  if [ "$down_for" -ge "$DOWN_ALERT" ] && [ $(( now - last_alert )) -ge "$REALERT" ]; then
    put host_down_alerted "$now"
    notify 4 "$LABEL may need unlocking" "$WORKER_NAME has been down for $((down_for / 60)) minutes and the $LABEL isn't running its services (answers ping: $pings, SSH :$SSH_PORT $ssh_state). If it was restarted or lost power, it is probably at the FileVault screen: unlock it at the keyboard."
  fi
  exit 0
fi

if ! port_open "$HOST" "$SSH_PORT"; then
  put locked_count 0
  log "$LABEL $HOST:$SSH_PORT is closed (off or still booting); nothing to unlock"
  exit 0
fi

if port_open "$HOST" "$TELEGRAF_PORT"; then
  put locked_count 0
  down_for=$(( now - $(get worker_down_since "$now") ))
  log "$LABEL is unlocked (Telegraf answers) but the worker has been down for ${down_for}s"
  if [ "$down_for" -ge "$UNLOCKED_DOWN_ALERT" ] && [ ! -e "$STATE_DIR/unlocked_alerted" ]; then
    put unlocked_alerted 1
    notify 4 "$LABEL worker down, Mac is up" "The $LABEL is unlocked but $WORKER_NAME has been down for $((down_for / 60)) minutes. Check the VM daemon: sudo launchctl print system/com.jakerobb.$WORKER_NAME, and /var/log/$WORKER_NAME.log on the Mac."
  fi
  exit 0
fi

locked_count=$(( $(get locked_count) + 1 ))
put locked_count "$locked_count"
log "$LABEL looks locked or still booting ($locked_count/$LOCKED_THRESHOLD)"
[ "$locked_count" -ge "$LOCKED_THRESHOLD" ] || exit 0

attempts="$(get attempts)"
if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
  if [ ! -e "$STATE_DIR/gave_up" ]; then
    put gave_up 1
    notify 5 "$LABEL unlock gave up" "$attempts unlock attempts did not bring the $LABEL up. Unlock it by hand (ssh to it with the account password, or at the keyboard), then check the stored password. State is in $STATE_DIR; it resets itself once the worker answers."
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
  log "DRY RUN: would SSH to $HOST with the stored password (attempt $((attempts + 1))/$MAX_ATTEMPTS)"
  exit 0
fi

put attempts $(( attempts + 1 ))
put last_attempt "$now"

user="$(sops -d --extract '["user"]' "$SECRETS_FILE" 2>/dev/null)" || { notify 5 "$LABEL unlock can't read its secret" "sops could not decrypt $SECRETS_FILE on $(hostname)."; exit 1; }
notify 3 "Unlocking the $LABEL" "Attempt $((attempts + 1))/$MAX_ATTEMPTS: it has looked locked for $locked_count minutes."

# SSH_ASKPASS_REQUIRE=force makes ssh use the helper with no terminal. Only password auth is offered, and the host
# key must match the pinned one, so the password can't go to anything else.
SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force UNLOCK_SECRETS="$SECRETS_FILE" \
  ssh -o BatchMode=no -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive \
      -o NumberOfPasswordPrompts=1 -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" \
      -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
      "$user@$HOST" true >/dev/null 2>&1
ssh_rc=$?
log "ssh exited $ssh_rc (the connection closing as the Mac boots is normal)"

deadline=$(( $(date +%s) + BOOT_WAIT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if port_open "$HOST" "$TELEGRAF_PORT"; then
    put locked_count 0
    notify 3 "$LABEL unlocked" "Telegraf is answering on $HOST:$TELEGRAF_PORT. The worker VM should rejoin within a few minutes."
    exit 0
  fi
  sleep 10
done
log "no sign of Telegraf $BOOT_WAIT s after the attempt; will retry after the cooldown"
exit 0
