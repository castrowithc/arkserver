#!/usr/bin/env bash

set -e

[[ -z "${DEBUG}" ]] || [[ "${DEBUG,,}" = "false" ]] || [[ "${DEBUG,,}" = "0" ]] || set -x

if [[ "$(whoami)" != "${STEAM_USER}" ]]; then
  echo "run this script as steam-user"
  exit 1
fi

# retry <max-attempts> <command...>
# Re-runs the command with exponential backoff. SteamCMD/arkmanager fail transiently
# ("Update interrupted", state 0x202, network hiccups); a single failure should not
# abort startup (#130, #84).
function retry() {
  local max="${1}"; shift
  local attempt=1
  local delay=15

  while true; do
    if "${@}"; then
      return 0
    fi
    if (( attempt >= max )); then
      echo "...command still failing after ${attempt} attempts: ${*}"
      return 1
    fi
    echo "...attempt ${attempt}/${max} failed; retrying in ${delay}s: ${*}"
    sleep "${delay}"
    attempt=$(( attempt + 1 ))
    delay=$(( delay * 2 ))
  done
}

# graceful_shutdown — runs on container stop (SIGTERM/SIGINT). Saves the world(s) and
# optionally backs up BEFORE letting arkmanager tear the server down, so a `docker stop`
# can't lose data. arkmanager's own `run` trap only SIGINTs the server without saving
# (#38); BACKUP_ON_STOP/WARN_ON_STOP were defined upstream but never wired up (#123).
# Needs a generous stop_grace_period in compose (Phase 6) to finish save + backup.
#
# Cluster-aware: each `arkmanager run @instance` is supervised in the background and its
# PID collected in INSTANCE_PIDS; `@all` fans save/backup/broadcast across every running
# instance. A plain vanilla server has exactly one instance (@main), so this behaves
# identically to the single-instance Phase 4 trap.
declare -a INSTANCE_PIDS=()
function graceful_shutdown() {
  set +e
  trap '' TERM INT   # ignore further stop signals while we shut down
  echo "Received stop signal — shutting down gracefully..."

  if [[ "${WARN_ON_STOP,,}" == "true" ]]; then
    local secs="${STOP_WARN_SECONDS:-10}"
    echo "WARN_ON_STOP: warning players, ${secs}s grace..."
    "${ARKMANAGER}" broadcast "Server is shutting down in ${secs} seconds..." @all || true
    sleep "${secs}" || true
  fi

  echo "Saving world(s) before shutdown..."
  "${ARKMANAGER}" saveworld @all || echo "saveworld failed (RCON disabled or ADMIN_PASSWORD unset?) — continuing"

  if [[ "${BACKUP_ON_STOP,,}" == "true" ]]; then
    echo "BACKUP_ON_STOP: creating shutdown backup..."
    # Include cluster transfer data in the backup only when clustering is enabled.
    "${ARKMANAGER}" backup @all ${CLUSTER_ID:+--cluster} || echo "backup on stop failed — continuing"
  fi

  echo "Stopping ${#INSTANCE_PIDS[@]} ARK instance(s)..."
  # arkmanager's run trap removes the autorestart file and SIGINTs the server group,
  # then exits — so this won't be fought by its supervisor/restart loop.
  local pid
  for pid in "${INSTANCE_PIDS[@]}"; do
    if kill -0 "${pid}" 2>/dev/null; then
      kill -TERM "${pid}" 2>/dev/null
    fi
  done
  for pid in "${INSTANCE_PIDS[@]}"; do
    wait "${pid}" 2>/dev/null
  done

  echo "Shutdown complete."
  exit 0
}

function may_update() {
  if [[ "${UPDATE_ON_START}" != "true" ]]; then
    return
  fi

  echo "\$UPDATE_ON_START is 'true'..."

  # auto checks if a update is needed, if yes, then update the server or mods
  # (otherwise it just does nothing). --validate repairs partially-written files;
  # a failed update is non-fatal — keep running on the already installed version.
  # @main: server files are shared by all instances, so update them exactly once.
  retry 5 ${ARKMANAGER} update @main --verbose --update-mods --backup --no-autostart --validate "${BETA_ARGS[@]}" ||
    echo "Update did not complete cleanly after retries; continuing with the installed version..."
}

function create_missing_dir() {
  for DIRECTORY in "${@}"; do
    [[ -n "${DIRECTORY}" ]] || return
    if [[ ! -d "${DIRECTORY}" ]]; then
      mkdir -p "${DIRECTORY}"
      echo "...successfully created ${DIRECTORY}"
    fi
  done
}

function copy_missing_file() {
  SOURCE="${1}"
  DESTINATION="${2}"

  if [[ ! -f "${DESTINATION}" ]]; then
    cp -a "${SOURCE}" "${DESTINATION}"
    echo "...successfully copied ${SOURCE} to ${DESTINATION}"
  fi
}

# add_prune_logs_cron — the crontab is copied to the volume once and then belongs to the
# operator (copy_missing_file never overwrites), so a job added by a newer image would never
# reach an existing install: it would keep the ENABLE_GAME_LOG switch but lose its retention.
# Add the job idempotently, taken from the template so the schedule isn't duplicated here and
# keyed on the script name so an operator's own schedule stays untouched.
function add_prune_logs_cron() {
  local live="${ARK_SERVER_VOLUME}/crontab"
  grep -q 'ark-prune-logs.sh' "${live}" 2>/dev/null && return 0
  echo "Adding the log-prune cron job to ${live}..."
  # An edited crontab may have lost its trailing newline; appending then glues both jobs
  # into one broken line.
  [[ -z "$(tail -c1 "${live}")" ]] || echo >> "${live}"
  grep 'ark-prune-logs.sh' "${TEMPLATE_DIRECTORY}/crontab" >> "${live}"
}

# add_backup_stamp — arkmanager.cfg is copied to the volume once and then belongs to the operator
# (copy_missing_file never overwrites), so the post-backup step added by a newer image would never
# reach an existing install: the image would carry the stamp script and nothing would ever call it,
# leaving every new archive as anonymous as the old ones. Same trap as the log-prune cron.
#
# The call goes in FRONT of whatever the command already runs, for two reasons: an operator's own
# post command keeps working, and the stamp exists before the retention step can weigh an archive
# against its neighbours.
function add_backup_stamp() {
  local live="${ARK_TOOLS_DIR}/arkmanager.cfg"
  [[ -f "${live}" ]] || return 0
  grep -q 'ark-tag-backup.sh' "${live}" 2>/dev/null && return 0

  if grep -qE "^[[:space:]]*arkBackupPostCommand='" "${live}"; then
    echo "Adding the backup stamp step to ${live}..."
    # Insert right after the opening quote of the first active assignment, so the existing command
    # simply runs second. & is the whole match, which is the key up to and including that quote.
    # The inserted "${backupfile}" is safe inside single quotes: arkmanager evaluates the value
    # later, when the variable exists.
    sed -i "0,/^[[:space:]]*arkBackupPostCommand='/s//&bash \/ark-tag-backup.sh \"\${backupfile}\"; /" "${live}"
  elif grep -qE "^[[:space:]]*arkBackupPostCommand=" "${live}"; then
    # Any other quoting is not this image's default and cannot be edited blindly: inserting a
    # double quote into a double-quoted value ends it early and silently rewrites what runs after
    # every backup. Left untouched, with a word about it, because a mangled post command is a worse
    # outcome than an unstamped backup.
    echo "arkBackupPostCommand in ${live} is not in the expected form and was left alone." >&2
    echo "Add 'bash /ark-tag-backup.sh \"\${backupfile}\";' in front of it to stamp backups with their save game." >&2
  else
    echo "Adding the backup stamp step to ${live}..."
    # No active assignment to extend, so take the template's line as it stands.
    grep "^arkBackupPostCommand=" "${TEMPLATE_DIRECTORY}/arkmanager.cfg" >> "${live}"
  fi
}

function needs_install() {
  local SERVER_DIR="${ARK_SERVER_VOLUME}/server"
  if [ ! -d "${SERVER_DIR}" ]; then
    echo "${SERVER_DIR} not found ..."
    return 0
  fi

  # Backwards compatibility
  local VERSION_FILE="${SERVER_DIR}/version.txt"
  if [ -f "${VERSION_FILE}" ]; then
    echo "Already installed. (found ${VERSION_FILE})"
    return 1
  fi

  local INSTALLED_FILES=(
    "${SERVER_DIR}/steamapps/appmanifest_376030.acf"
    "${SERVER_DIR}/ShooterGame/Binaries/Linux/ShooterGameServer"
  )
  for FILE in "${INSTALLED_FILES[@]}"; do
    if [ ! -s "${FILE}" ]; then
      echo "${FILE} is not complete ..."
      return 0
    fi
  done

  echo "Already installed."
  return 1
}

# --- Cluster support (Phase 5, gated) -------------------------------------------------
# Everything below is opt-in: cluster settings activate only when CLUSTER_ID is set,
# sub-instances only when SUB_INSTANCE_KEYS is set. With neither, the server runs a
# single @main instance exactly like the Phase 4 vanilla case (no regression).

# add_cluster_to_arkmanager_cfg — idempotently append the cluster block to the LIVE
# arkmanager.cfg (the copy on the volume). Done at runtime instead of baking it into the
# template so vanilla installs stay clean AND existing volumes pick it up (copy_missing_file
# never overwrites an existing cfg — the config-persistence gotcha).
function add_cluster_to_arkmanager_cfg() {
  [[ -n "${CLUSTER_ID}" ]] || return 0
  local config="${ARK_TOOLS_DIR}/arkmanager.cfg"
  if ! grep -q '^arkopt_ClusterDirOverride=' "${config}" 2>/dev/null; then
    echo "Enabling cluster settings in arkmanager.cfg (CLUSTER_ID='${CLUSTER_ID}')..."
    cat >> "${config}" <<EOF

# Cluster settings (added by steam-entrypoint.sh because CLUSTER_ID is set)
arkflag_NoTransferFromFiltering=true
arkopt_ClusterDirOverride="/cluster"
arkopt_clusterid="\${CLUSTER_ID}"
EOF
  fi
}

# remake_sub_instances_cfg — (re)generate one instance config per SUB_INSTANCE_KEYS entry
# from the template, assigning each a port block offset from the main instance:
# game +2*i, query +i, rcon +i (i = 1..N). Sub-instances share the server files but use a
# distinct save dir, so multiple maps run in one container against the shared /cluster.
function remake_sub_instances_cfg() {
  local instances_dir="${ARK_TOOLS_DIR}/instances"
  # Always clear previously generated sub configs so removed keys don't linger.
  rm -f "${instances_dir}"/sub.*.cfg

  [[ -n "${SUB_INSTANCE_KEYS}" ]] || return 0

  local key
  local -i i=1
  for key in ${SUB_INSTANCE_KEYS//,/ }; do
    [[ -n "${key}" ]] || continue
    echo "Generating sub-instance config: sub.${key} (game $((GAME_CLIENT_PORT+i*2)), query $((SERVER_LIST_PORT+i)), rcon $((RCON_PORT+i)))"
    sed -r \
      -e "s/^# Template configuration.*$/# DO NOT EDIT - auto-generated from arkmanager-sub.cfg.template/i" \
      -e "s/<KEY>/${key}/g" \
      -e "s/<NUMBER_SUFFIX>/$((i+1))/g" \
      -e "s/<GAME_CLIENT_PORT>/$((GAME_CLIENT_PORT+i*2))/g" \
      -e "s/<SERVER_LIST_PORT>/$((SERVER_LIST_PORT+i))/g" \
      -e "s/<RCON_PORT>/$((RCON_PORT+i))/g" \
      "${TEMPLATE_DIRECTORY}/arkmanager-sub.cfg.template" \
      > "${instances_dir}/sub.${key}.cfg"
    (( i++ ))
  done
}

# get_all_mod_ids — the complete, de-duplicated set of workshop items that must be present
# before any instance starts: the main map mod, GAME_MOD_IDS, plus each sub-instance's map
# mod and mod list. Emits one id per line.
function get_all_mod_ids() {
  local key mod_id var_name
  local -a collected=()

  [[ -n "${SERVER_MAP_MOD_ID}" ]] && collected+=("${SERVER_MAP_MOD_ID}")
  for mod_id in ${GAME_MOD_IDS//,/ }; do
    [[ -n "${mod_id}" ]] && collected+=("${mod_id}")
  done

  for key in ${SUB_INSTANCE_KEYS//,/ }; do
    var_name="SUB_${key}_SERVER_MAP_MOD_ID"
    [[ -n "${!var_name}" ]] && collected+=("${!var_name}")
    var_name="SUB_${key}_GAME_MOD_IDS"
    for mod_id in ${!var_name//,/ }; do
      [[ -n "${mod_id}" ]] && collected+=("${mod_id}")
    done
  done

  [[ ${#collected[@]} -gt 0 ]] || return 0
  printf '%s\n' "${collected[@]}" | sort -u
}

# install_mods — install every required workshop item, then a pre-flight pass that verifies
# each one actually landed. SteamCMD mod downloads fail partially (ANSI-corrupted parsing,
# transient errors — #97/#91); the steamcmd-stripansi wrapper handles ANSI, retry handles
# transients, and this verification turns a silent half-install into a loud warning.
function install_mods() {
  local -a mod_ids=()
  mapfile -t mod_ids < <(get_all_mod_ids)
  [[ ${#mod_ids[@]} -gt 0 ]] || return 0

  echo "Installing mods: '${mod_ids[*]}' ..."
  local mod mod_dir
  for mod in "${mod_ids[@]}"; do
    mod_dir="${ARK_SERVER_VOLUME}/server/ShooterGame/Content/Mods/${mod}"
    if [[ -d "${mod_dir}" && -n "$(ls -A "${mod_dir}" 2>/dev/null)" ]]; then
      echo "...mod ${mod} already present"
      continue
    fi
    echo "...installing mod ${mod}"
    retry 3 "${ARKMANAGER}" installmod "${mod}" --verbose ||
      echo "...mod ${mod} install command still failing after retries"
  done

  # Pre-flight: confirm every expected mod is on disk before we start the server.
  local -a missing=()
  for mod in "${mod_ids[@]}"; do
    mod_dir="${ARK_SERVER_VOLUME}/server/ShooterGame/Content/Mods/${mod}"
    if [[ ! -d "${mod_dir}" || -z "$(ls -A "${mod_dir}" 2>/dev/null)" ]]; then
      missing+=("${mod}")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "WARNING: ${#missing[@]} of ${#mod_ids[@]} mod(s) did not install completely: ${missing[*]}"
    echo "         The server may fail to load these mods. Check connectivity/disk and restart."
  else
    echo "Mod pre-flight OK: all ${#mod_ids[@]} mod(s) present."
  fi
}

# validate_cluster — when clustering is enabled, make sure the shared transfer directory is
# actually mounted and writable, otherwise transfers silently fail to persist.
function validate_cluster() {
  [[ -n "${CLUSTER_ID}" ]] || return 0
  echo "Cluster enabled (CLUSTER_ID='${CLUSTER_ID}'); checking shared dir /cluster ..."
  if [[ ! -d "/cluster" ]]; then
    echo "WARNING: /cluster does not exist — cross-server transfers will not persist."
    echo "         Mount a volume at /cluster (shared across cluster members)."
    return 0
  fi
  if ! ( : > "/cluster/.write-test" ) 2>/dev/null; then
    echo "WARNING: /cluster is not writable by $(id -un) — cross-server transfers will fail."
  else
    rm -f "/cluster/.write-test"
    echo "...cluster dir /cluster is present and writable."
  fi
}
# --- end cluster support --------------------------------------------------------------

args=("$@")
if [[ "${ENABLE_CROSSPLAY}" == "true" ]]; then
  args=('--arkopt,-crossplay' "${args[@]}")
fi
if [[ "${DISABLE_BATTLEYE}" == "true" ]]; then
  args=('--arkopt,-NoBattlEye' "${args[@]}")
fi
# Game log is OFF by default: without -servergamelog ShooterGame.log stays 0 B. Opt in
# with ENABLE_GAME_LOG=true; the log is then pruned count-based via cron (ark-prune-logs.sh).
if [[ "${ENABLE_GAME_LOG}" == "true" ]]; then
  args=('--arkopt,-servergamelog' "${args[@]}")
fi
BETA_ARGS=(${BETA:+--beta=${BETA}} ${BETA_ACCESSCODE:+--betapassword=${BETA_ACCESSCODE}})

echo "_______________________________________"
echo ""
echo "# Ark Server - $(date)"
echo "# IMAGE_VERSION: '${IMAGE_VERSION}'"
echo "# RUNNING AS USER '${STEAM_USER}' - '$(id -u)'"
echo "# ARGS: ${args[*]}"
if [ -n "${BETA}" ]; then
  echo "# BETA: ${BETA}"
fi
echo "_______________________________________"

if [[ -z "${ADMIN_PASSWORD}" ]]; then
  echo "WARNING: ADMIN_PASSWORD is not set — RCON/admin access will be insecure."
  echo "         Set ADMIN_PASSWORD via your .env / -e before exposing this server."
fi

ARKMANAGER="$(command -v arkmanager)"
[[ -x "${ARKMANAGER}" ]] || (
  echo "Arkmanager is missing"
  exit 1
)

cd "${ARK_SERVER_VOLUME}"

echo "Setting up folder and file structure..."
create_missing_dir "${ARK_SERVER_VOLUME}/log" "${ARK_SERVER_VOLUME}/backup" "${ARK_SERVER_VOLUME}/staging"

# copy from template to server volume
copy_missing_file "${TEMPLATE_DIRECTORY}/arkmanager.cfg" "${ARK_TOOLS_DIR}/arkmanager.cfg"
copy_missing_file "${TEMPLATE_DIRECTORY}/arkmanager-user.cfg" "${ARK_TOOLS_DIR}/instances/main.cfg"
copy_missing_file "${TEMPLATE_DIRECTORY}/crontab" "${ARK_SERVER_VOLUME}/crontab"
add_prune_logs_cron
add_backup_stamp

# Cluster wiring (gated): inject cluster settings into the live cfg and (re)generate
# sub-instance configs. Both are no-ops unless CLUSTER_ID / SUB_INSTANCE_KEYS are set.
add_cluster_to_arkmanager_cfg
remake_sub_instances_cfg
validate_cluster

# Ensure the config dir exists so the INI symlinks resolve and edits land even before
# the server has run once (#135).
create_missing_dir "${ARK_SERVER_VOLUME}/server/ShooterGame/Saved/Config/LinuxServer"

[[ -L "${ARK_SERVER_VOLUME}/Game.ini" ]] ||
  ln -s ./server/ShooterGame/Saved/Config/LinuxServer/Game.ini Game.ini
[[ -L "${ARK_SERVER_VOLUME}/GameUserSettings.ini" ]] ||
  ln -s ./server/ShooterGame/Saved/Config/LinuxServer/GameUserSettings.ini GameUserSettings.ini

if needs_install; then
  echo "No game files found. Installing..."

  create_missing_dir \
    "${ARK_SERVER_VOLUME}/server/ShooterGame/Saved/SavedArks" \
    "${ARK_SERVER_VOLUME}/server/ShooterGame/Content/Mods" \
    "${ARK_SERVER_VOLUME}/server/ShooterGame/Binaries/Linux"

  touch "${ARK_SERVER_VOLUME}/server/ShooterGame/Binaries/Linux/ShooterGameServer"
  chmod +x "${ARK_SERVER_VOLUME}/server/ShooterGame/Binaries/Linux/ShooterGameServer"

  if ! retry 5 ${ARKMANAGER} install @main --verbose "${BETA_ARGS[@]}"; then
    echo "Installation failed after retries"
    exit 1
  fi
fi

# Install the crontab with the runtime environment cron jobs need: cron runs jobs
# with an almost-empty environment, but the arkmanager config files reference these
# vars. Secrets (passwords) are intentionally omitted from the cron spool (#9).
{
  echo "SHELL=/bin/bash"
  echo "PATH=/usr/local/bin:/usr/bin:/bin"
  echo "ARK_SERVER_VOLUME=${ARK_SERVER_VOLUME}"
  echo "ARK_TOOLS_DIR=${ARK_TOOLS_DIR}"
  echo "STEAM_HOME=${STEAM_HOME}"
  echo "STEAM_USER=${STEAM_USER}"
  echo "STEAM_LOGIN=${STEAM_LOGIN}"
  echo "SESSION_NAME=${SESSION_NAME}"
  echo "SERVER_MAP=${SERVER_MAP}"
  echo "MAX_PLAYERS=${MAX_PLAYERS}"
  echo "GAME_MOD_IDS=${GAME_MOD_IDS}"
  echo "GAME_CLIENT_PORT=${GAME_CLIENT_PORT}"
  echo "SERVER_LIST_PORT=${SERVER_LIST_PORT}"
  echo "RCON_PORT=${RCON_PORT}"
  echo "UPDATE_ON_START=${UPDATE_ON_START}"
  echo "PRE_UPDATE_BACKUP=${PRE_UPDATE_BACKUP}"
  # Cluster-aware cron (e.g. `arkmanager backup @all --cluster`) needs these resolvable.
  echo "CLUSTER_ID=${CLUSTER_ID}"
  echo "SERVER_MAP_MOD_ID=${SERVER_MAP_MOD_ID}"
  # Pass through SUB_INSTANCE_KEYS + every SUB_<KEY>_* override so sub-instance configs
  # resolve under cron too (prefix expansion covers SUB_INSTANCE_KEYS itself).
  for __sub_var in ${!SUB_@}; do
    echo "${__sub_var}=${!__sub_var}"
  done
  echo ""
  cat "${ARK_SERVER_VOLUME}/crontab"
} | crontab -

install_mods

may_update

# Linux-binary guard: refuse to start arkmanager if SteamCMD never delivered a
# runnable Linux server binary (the install step leaves a 0-byte placeholder), so we
# fail with a clear message instead of an opaque arkmanager error (#103).
SERVER_BINARY="${ARK_SERVER_VOLUME}/server/ShooterGame/Binaries/Linux/ShooterGameServer"
if [[ ! -s "${SERVER_BINARY}" ]]; then
  echo "ERROR: ARK Linux server binary is missing or empty:"
  echo "       ${SERVER_BINARY}"
  echo "       SteamCMD did not deliver a runnable server (App-ID 376030, Survival Evolved)."
  echo "       Check free disk space and connectivity, then restart the container."
  exit 1
fi

# Clear pid/autorestart state left behind if a previous container died before its trap
# finished — otherwise arkmanager may think an instance is still running.
rm -f "${ARK_SERVER_VOLUME}"/server/ShooterGame/Saved/.arkmanager*.pid \
      "${ARK_SERVER_VOLUME}"/server/ShooterGame/Saved/.arkserver*.pid \
      "${ARK_SERVER_VOLUME}"/server/ShooterGame/Saved/.autorestart 2>/dev/null || true

# Supervise arkmanager ourselves so a stop signal triggers graceful_shutdown (save +
# optional backup) instead of an abrupt kill. One background `run` per instance config:
# just @main for a vanilla server, plus every sub.<KEY> when clustering is enabled.
trap graceful_shutdown TERM INT

for config in "${ARK_TOOLS_DIR}"/instances/*.cfg; do
  [[ -e "${config}" ]] || continue
  instance="$(basename "${config%.cfg}")"
  echo "Starting instance @${instance} ..."
  "${ARKMANAGER}" run "@${instance}" --verbose ${args[@]} &
  INSTANCE_PIDS+=("$!")
done

if [[ ${#INSTANCE_PIDS[@]} -eq 0 ]]; then
  echo "ERROR: no instance configs found in ${ARK_TOOLS_DIR}/instances — nothing to start."
  exit 1
fi

wait "${INSTANCE_PIDS[@]}"
