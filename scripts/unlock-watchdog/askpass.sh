#!/usr/bin/env bash
# SSH_ASKPASS helper for unlock-watchdog.sh: prints the stored password, and only when ssh is asking for one
# (so a host-key or other prompt never receives it).
set -euo pipefail
case "${1:-}" in
  *[Pp]assword*) exec sops -d --extract '["password"]' "${UNLOCK_SECRETS:?}" ;;
  *) exit 1 ;;
esac
