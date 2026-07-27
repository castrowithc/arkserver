#!/usr/bin/env bash
#
# Stamp a backup with the save game it was taken from.
#
# arkmanager names every archive after its instance, which is one name for every save game, and
# nothing inside the archive says which save directory the world came from. The map is visible,
# because the world file carries it, but two save games of the same map produce archives that
# cannot be told apart. Restoring the wrong one puts a foreign world into a save game somebody is
# playing, and it looks like it worked.
#
# The missing fact is written next to the archive as <archive>.savegame rather than into it: a
# compressed tar would have to be unpacked and repacked for one line, on every backup, for a world
# that can be tens of megabytes. The sidecar leaves the archive byte for byte as arkmanager wrote
# it, so `arkmanager restore` keeps working untouched.
#
# Wired via arkmanager's arkBackupPostCommand, so it runs after every successful backup (cron,
# pre-update, and BACKUP_ON_STOP). It never fails the backup: anything unreadable is a silent
# no-op, because an unstamped backup is still a backup and a failed one is not.
#
# Usage: ark-tag-backup.sh <archive> [instance-config]

set -uo pipefail

ARCHIVE="${1:-}"
CFG="${2:-${ARK_SERVER_VOLUME:-/app}/arkmanager/instances/main.cfg}"

[[ -n "${ARCHIVE}" && -f "${ARCHIVE}" ]] || exit 0
[[ -r "${CFG}" ]] || exit 0

# Read a key the way the server reads it: commented lines do not count, a trailing comment is cut,
# the value is unquoted, and the last assignment wins.
value_of() {
  awk -v key="$1" '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      line = $0
      sub(/^[^=]*=/, "", line)
      sub(/#.*$/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      gsub(/^["'\'']|["'\'']$/, "", line)
      v = line
    }
    END { if (v != "") print v }
  ' "${CFG}"
}

SAVEDIR="$(value_of ark_AltSaveDirectoryName)"
MAP="$(value_of serverMap)"

# No alternate directory means the default one, which is what the panel calls the same save game.
[[ -n "${SAVEDIR}" ]] || SAVEDIR="SavedArks"

# serverMap may stand as a ${VAR} reference instead of a literal, in which case the environment of
# this process is the same one the server was started with and therefore the right answer.
if [[ "${MAP}" =~ ^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$ ]]; then
  MAP="${!BASH_REMATCH[1]:-}"
fi

{
  printf 'savedir=%s\n' "${SAVEDIR}"
  printf 'map=%s\n' "${MAP}"
} > "${ARCHIVE}.savegame" 2>/dev/null || exit 0

exit 0
