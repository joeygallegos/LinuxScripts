#!/bin/bash

# Robust bash settings
set -euo pipefail
IFS=$'\n\t'

#####################################
# Configurable defaults / constants #
#####################################
config_file='./config.json'
backupfolder="/home/backup"
logfile=""       # set after we know backupfolder exists
DEBUG="${DEBUG:-0}"

#####################################
# Logging & error handling helpers  #
#####################################

# Simple logger (console + logfile once set)
log() {
  local ts
  ts="$(date +'%Y-%m-%d %H:%M:%S')"
  if [[ -n "${logfile:-}" ]]; then
    echo "$ts: $*" | tee -a "$logfile"
  else
    echo "$ts: $*"
  fi
}

# Trap errors with line numbers and the failing command
err_trap() {
  local exit_code=$?
  # $BASH_COMMAND can include sensitive info if you echo full commands. We keep it generic.
  log "ERROR: command failed on line ${BASH_LINENO[0]} (exit ${exit_code}). See log for details."
  exit "$exit_code"
}
trap err_trap ERR

# Optional bash xtrace into logfile when DEBUG=1
enable_debug() {
  if [[ "$DEBUG" == "1" ]]; then
    # Send xtrace to FD 9 which points at logfile once we set it
    export BASH_XTRACEFD=9
    set -x
  fi
}

#####################
# Preflight checks  #
#####################
require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "ERROR: required command '$cmd' not found in PATH"
    exit 1
  fi
}

check_jq() { require_cmd jq; }
check_tools() {
  require_cmd mysqldump
  require_cmd tar
  require_cmd gzip
  # mysql is optional (we use it for a quick connectivity test if present)
  command -v mysql >/dev/null 2>&1 || log "Note: 'mysql' client not found; skipping connectivity smoke test."
  command -v chattr >/dev/null 2>&1 || log "Note: 'chattr' not found; immutable flag steps will be skipped."
}

ensure_backup_dir() {
  if [[ ! -d "$backupfolder" ]]; then
    log "Backup folder '$backupfolder' does not exist. Creating..."
    mkdir -p "$backupfolder"
  fi
  if [[ ! -w "$backupfolder" ]]; then
    log "ERROR: Backup folder '$backupfolder' is not writable by $(whoami)."
    exit 1
  fi
  logfile="$backupfolder/backup_$(date +'%Y-%m-%d').log"
  # Open FD 9 for xtrace to land in logfile when DEBUG=1
  exec 9>>"$logfile"
  enable_debug
  log "Logging to $logfile"
}

check_disk_space() {
  # Require at least 100MB free in the target mount
  local avail_kb
  avail_kb=$(df -Pk "$backupfolder" | awk 'NR==2 {print $4}')
  if [[ -n "$avail_kb" && "$avail_kb" -lt 102400 ]]; then
    log "ERROR: Less than 100MB free on the filesystem hosting $backupfolder."
    exit 1
  fi
}

##################
# Mailgun helper #
##################
send_mailgun_notification() {
  local subject="$1"
  local message="$2"

  # Only attempt if all variables are set and non-empty
  if [[ -n "${mailgun_api_key:-}" && -n "${mailgun_domain:-}" && -n "${mailgun_from:-}" && -n "${notification_email:-}" ]]; then
    curl -s --fail --user "api:$mailgun_api_key" \
      "https://api.mailgun.net/v3/$mailgun_domain/messages" \
      -F from="$mailgun_from" \
      -F to="$notification_email" \
      -F subject="$subject" \
      -F text="$message" \
      || log "Warning: Mailgun notification failed to send."
  else
    log "Note: Mailgun not configured; skipping email notification for: $subject"
  fi
}

#################
# Config loader #
#################
load_config() {
  log "Reading configuration from $config_file"
  if [[ ! -f "$config_file" ]]; then
    log "ERROR: Config file $config_file does not exist."
    exit 1
  fi

  sql_user=$(jq -r '.sql_user // empty' "$config_file")
  sql_pass=$(jq -r '.sql_pass // empty' "$config_file")
  sql_port=$(jq -r '.sql_port // empty' "$config_file")
  sql_host=$(jq -r '.sql_host // empty' "$config_file")
  notification_email=$(jq -r '.notification_email // empty' "$config_file")
  mailgun_api_key=$(jq -r '.mailgun_api_key // empty' "$config_file")
  mailgun_domain=$(jq -r '.mailgun_domain // empty' "$config_file")
  mailgun_from=$(jq -r '.mailgun_from // empty' "$config_file")
  enable_www_backup=$(jq -r '.enable_www_backup // "false"' "$config_file")

  # Read www_directories as an array (or empty)
  mapfile -t www_directories < <(jq -r '.www_directories // [] | .[]' "$config_file")

  # Basic sanity
  sql_user=${sql_user:-}
  sql_pass=${sql_pass:-}
  sql_port=${sql_port:-3306}
  sql_host=${sql_host:-127.0.0.1}

  if [[ -z "$sql_user" || -z "$sql_pass" ]]; then
    log "ERROR: 'sql_user' and/or 'sql_pass' missing from config."
    exit 1
  fi

  log "Config OK. Host=$sql_host Port=$sql_port User=$sql_user (password redacted). WWW backup: $enable_www_backup"
}

############################
# Optional connectivity ping
############################
mysql_ping() {
  if command -v mysql >/dev/null 2>&1; then
    log "Testing MySQL connectivity to $sql_host:$sql_port ..."
    if ! mysql --user="$sql_user" --password="$sql_pass" --host="$sql_host" --port="$sql_port" --connect-timeout=5 -e "SELECT 1" >/dev/null 2>&1; then
      log "ERROR: Unable to connect to MySQL with provided credentials/host/port."
      exit 1
    fi
    log "Connectivity OK."
  fi
}

##################
# SQL backup     #
##################
do_sql_backup() {
  local now filename gzfilename fullpathbackupfile fullpathgzbackupfile
  now="$(date +'%Y-%m-%d')"
  filename="db_backup_$now.sql"
  gzfilename="db_backup_$now.sql.gz"
  fullpathbackupfile="$backupfolder/$filename"
  fullpathgzbackupfile="$backupfolder/$gzfilename"

  log "Starting SQL backup..."

  # Remove yesterday’s output if present (so redirection won’t fail on immutable)
  if [[ -f "$fullpathgzbackupfile" ]]; then
    log "Previous DB backup exists. Removing immutable bit (if any) and deleting old file."
    command -v chattr >/dev/null 2>&1 && chattr -i "$fullpathgzbackupfile" || true
    rm -f "$fullpathgzbackupfile"
  fi

  # Show the *sanitized* command we're about to run
  log "Running mysqldump to $fullpathbackupfile (host=$sql_host port=$sql_port user=$sql_user; password redacted; TCP enforced)."

  # Capture mysqldump stderr and log it line-by-line
  if mysqldump \
        --user="$sql_user" \
        --password="$sql_pass" \
        --host="$sql_host" \
        --port="$sql_port" \
        --protocol=TCP \
        --default-character-set=utf8mb4 \
        --single-transaction \
        --routines --events --triggers \
        --all-databases \
        > "$fullpathbackupfile" \
        2> >(while read -r line; do log "[mysqldump] $line"; done)
  then
    log "mysqldump completed. Compressing..."
    gzip "$fullpathbackupfile"

    # Ownership only if root
    if [[ $EUID -eq 0 ]]; then
      chown root:root "$fullpathgzbackupfile" || log "Warning: chown failed (non-fatal)."
    fi

    # Try to set immutable bit
    command -v chattr >/dev/null 2>&1 && chattr +i "$fullpathgzbackupfile" || log "Note: Unable to set immutable bit (non-fatal)."

    log "Database dump created: $fullpathgzbackupfile"
    global_file_name="$gzfilename"
  else
    local error_message="mysqldump failed; see $logfile for details."
    log "ERROR: $error_message"
    send_mailgun_notification 'Error with mysqldump command' "$error_message"
    exit 1
  fi
}

##################
# WWW backup     #
##################
do_www_backup() {
  local now filename gzfilename fullpathbackupfile fullpathgzbackupfile
  now="$(date +'%Y-%m-%d')"
  filename="www_backup_$now.tar"
  gzfilename="www_backup_$now.tar.gz"
  fullpathbackupfile="$backupfolder/$filename"
  fullpathgzbackupfile="$backupfolder/$gzfilename"

  log "Starting WWW backup..."

  if [[ -f "$fullpathgzbackupfile" ]]; then
    log "Previous WWW backup exists. Removing immutable bit (if any) and deleting old file."
    command -v chattr >/dev/null 2>&1 && chattr -i "$fullpathgzbackupfile" || true
    rm -f "$fullpathgzbackupfile"
  fi

  # Create empty tar then append each dir to keep errors obvious
  tar -cf "$fullpathbackupfile" --files-from /dev/null

  for dir in "${www_directories[@]:-}"; do
    if [[ -z "$dir" ]]; then
      continue
    fi
    if [[ ! -d "$dir" ]]; then
      local error_message="Directory $dir does not exist."
      log "ERROR: $error_message"
      send_mailgun_notification 'Error during WWW folder backup' "$error_message"
      return 1
    fi
    log "Adding directory: $dir"
    tar -rf "$fullpathbackupfile" "$dir"
  done

  log "Compressing WWW backup..."
  gzip "$fullpathbackupfile"

  command -v chattr >/dev/null 2>&1 && chattr +i "$fullpathgzbackupfile" || log "Note: Unable to set immutable bit (non-fatal)."
  log "WWW backup created: $fullpathgzbackupfile"
}

#################
# Post-checks   #
#################
check_if_backup_exists() {
  log "Verifying DB backup file ($global_file_name) exists and is non-empty..."
  if [[ -n "$global_file_name" && -s "$backupfolder/$global_file_name" ]]; then
    log "OK: $global_file_name exists and is non-empty."
  else
    local error_message="Backup file $global_file_name was not created or is empty!"
    log "ERROR: $error_message"
    send_mailgun_notification 'Error with DB backup task' "$error_message"
    exit 1
  fi
}

##########################
# Main
##########################
check_jq
check_tools
load_config
ensure_backup_dir
check_disk_space
mysql_ping

global_file_name=''
do_sql_backup
check_if_backup_exists

if [[ "${enable_www_backup,,}" == "true" ]]; then
  do_www_backup
fi

log "Backup script completed successfully."
