#!/usr/bin/env bash
#
# Rolling, count-based backup retention. arkmanager only prunes by total size
# (arkMaxBackupSizeMB); this keeps the newest N archives and deletes older ones.
# Wired via arkmanager's arkBackupPostCommand, so it runs after every successful
# backup (cron, pre-update, and BACKUP_ON_STOP) — see conf.d/arkmanager.cfg.
#
# Usage: ark-prune-backups.sh <backup-dir> <keep-count>

set -euo pipefail

DIR="${1:?backup directory required}"
KEEP="${2:-24}"

# Be defensive: a non-numeric or zero/negative count disables pruning rather than
# wiping everything.
if ! [[ "${KEEP}" =~ ^[0-9]+$ ]] || (( KEEP <= 0 )); then
  echo "ark-prune-backups: invalid keep-count '${KEEP}', skipping prune" >&2
  exit 0
fi

[[ -d "${DIR}" ]] || exit 0

# Backups live at <dir>/<daystamp>/<instance>.<datestamp>.tar[.bz2]; collect all
# archives newest-first.
mapfile -t files < <(
  find "${DIR}" -type f \( -name '*.tar' -o -name '*.tar.bz2' \) -printf '%T@\t%p\n' 2>/dev/null |
    sort -nr | cut -f2-
)

count=${#files[@]}
if (( count > KEEP )); then
  for (( i = KEEP; i < count; i++ )); do
    # The .savegame sidecar written by ark-tag-backup.sh goes with its archive. It is not matched
    # by the find above, so it never counts towards KEEP and never displaces a real backup.
    if rm -f "${files[$i]}" "${files[$i]}.savegame"; then
      echo "ark-prune-backups: removed old backup ${files[$i]}"
    fi
  done
fi

# Drop sidecars whose archive is gone, so a backup deleted by hand or by the size-based retention
# inside arkmanager does not leave a stamp claiming a save game for nothing.
while IFS= read -r stamp; do
  [[ -f "${stamp%.savegame}" ]] || rm -f "${stamp}"
done < <(find "${DIR}" -type f -name '*.savegame' 2>/dev/null)

# Tidy up day-stamp directories that are now empty.
find "${DIR}" -mindepth 1 -type d -empty -delete 2>/dev/null || true

exit 0
