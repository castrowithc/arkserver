#!/usr/bin/env bash
#
# Rolling, count-based retention for the ARK game log (Saved/Logs/ShooterGame*.log).
# ARK writes a fresh timestamped log per launch when -servergamelog is on
# (ENABLE_GAME_LOG=true); over many restarts these accumulate unbounded. This keeps the
# newest N and deletes older ones. Wired via cron (conf.d/crontab); a no-op when logging
# is off (nothing matches). Mirrors ark-prune-backups.sh.
#
# Usage: ark-prune-logs.sh <log-dir> <keep-count>

set -euo pipefail

DIR="${1:?log directory required}"
KEEP="${2:-20}"

# Be defensive: a non-numeric or zero/negative count disables pruning rather than
# wiping everything.
if ! [[ "${KEEP}" =~ ^[0-9]+$ ]] || (( KEEP <= 0 )); then
  echo "ark-prune-logs: invalid keep-count '${KEEP}', skipping prune" >&2
  exit 0
fi

[[ -d "${DIR}" ]] || exit 0

# Collect all game logs newest-first.
mapfile -t files < <(
  find "${DIR}" -maxdepth 1 -type f -name 'ShooterGame*.log' -printf '%T@\t%p\n' 2>/dev/null |
    sort -nr | cut -f2-
)

count=${#files[@]}
if (( count > KEEP )); then
  for (( i = KEEP; i < count; i++ )); do
    if rm -f "${files[$i]}"; then
      echo "ark-prune-logs: removed old log ${files[$i]}"
    fi
  done
fi

exit 0
