#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

# Log function for consistent timestamped messages
log() {
  echo "$(date +'%Y-%m-%d %H:%M:%S'): $*"
}

check_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    log "ERROR: jq is not installed. Please install jq first."
    exit 1
  fi
}

send_mailgun_notification() {
  local subject="$1"
  local message="$2"
  curl -s --user "api:$mailgun_api_key" \
    https://api.mailgun.net/v3/$mailgun_domain/messages \
    -F from="$mailgun_from" \
    -F to="$notification_email" \
    -F subject="$subject" \
    -F text="$message"
}

load_config() {
  log "Attempting to read configuration file $config_file"
  if [[ -f "$config_file" ]]; then
    sql_user=$(jq -r '.sql_user' "$config_file")
    sql_pass=$(jq -r '.sql_pass' "$config_file")
    sql_port=$(jq -r '.sql_port' "$config_file")
    notification_email=$(jq -r '.notification_email' "$config_file")
    mailgun_api_key=$(jq -r '.mailgun_api_key' "$config_file")
    mailgun_domain=$(jq -r '.mailgun_domain' "$config_file")
    mailgun_from=$(jq -r '.mailgun_from' "$config_file")
    # Read www_directories as an array
    mapfile -t www_directories < <(jq -r '.www_directories[]' "$config_file")
    enable_www_backup=$(jq -r '.enable_www_backup' "$config_file")
  else
    log "ERROR: Config file $config_file does not exist or cannot be read"
    exit 1
  fi
}

do_sql_backup() {
  now="$(date +'%Y_%m_%d_%H_%M')"
  filename="db_backup_$now.sql"
  gzfilename="db_backup_$now.sql.gz"
  fullpathbackupfile="$backupfolder/$filename"
  fullpathgzbackupfile="$backupfolder/$gzfilename"

  log "Starting SQL backup..."

  if [[ -f "$fullpathgzbackupfile" ]]; then
    log "Backup file $fullpathgzbackupfile already exists. Removing old backup before proceeding."
    chattr -i "$fullpathgzbackupfile" || true
    rm -f "$fullpathgzbackupfile"
  fi

  if mysqldump --user="$sql_user" --password="$sql_pass" --port="$sql_port" --default-character-set=utf8 --all-databases > "$fullpathbackupfile"; then
    log "mysqldump completed successfully, compressing backup..."
    gzip "$fullpathbackupfile"

    # Change ownership to root or your backup user here if needed
    chown root:root "$fullpathgzbackupfile"

    # Set immutable attribute to prevent deletion/modification
    chattr +i "$fullpathgzbackupfile" || log "Warning: Failed to set immutable attribute on backup file"

    log "Database dump completed successfully - output file: $fullpathgzbackupfile"

    global_file_name="$gzfilename"
  else
    local error_message="An error occurred while executing mysqldump"
    log "$error_message"
    send_mailgun_notification 'Error with mysqldump command' "$error_message"
    exit 1
  fi
}

do_www_backup() {
  now="$(date +'%Y_%m_%d_%H_%M')"
  filename="www_backup_$now.tar"
  gzfilename="www_backup_$now.tar.gz"
  fullpathbackupfile="$backupfolder/$filename"
  fullpathgzbackupfile="$backupfolder/$gzfilename"

  log "Starting WWW backup..."

  # Remove old backup if exists
  if [[ -f "$fullpathgzbackupfile" ]]; then
    log "WWW backup file $fullpathgzbackupfile already exists. Removing old backup."
    chattr -i "$fullpathgzbackupfile" || true
    rm -f "$fullpathgzbackupfile"
  fi

  # Create empty tar file
  tar -cf "$fullpathbackupfile" --files-from /dev/null

  # Add each directory to tar
  for dir in "${www_directories[@]}"; do
    if [[ ! -d "$dir" ]]; then
      local error_message="Directory $dir does not exist."
      log "$error_message"
      send_mailgun_notification 'Error during WWW folder backup' "$error_message"
      return 1
    else
      log "Adding directory $dir to archive"
      tar -rf "$fullpathbackupfile" "$dir"
    fi
  done

  log "Compressing WWW backup..."
  gzip "$fullpathbackupfile"

  chattr +i "$fullpathgzbackupfile" || log "Warning: Failed to set immutable attribute on www backup file"

  log "WWW backup completed successfully - output file: $fullpathgzbackupfile"
}

check_if_backup_exists() {
  log "Checking if backup file ($global_file_name) exists and is not empty..."

  if [[ -s "$backupfolder/$global_file_name" ]]; then
    log "Backup file $global_file_name exists and is non-empty."
  else
    local error_message="Backup file $global_file_name was not created or is empty!"
    log "$error_message"
    send_mailgun_notification 'Error with DB backup task' "$error_message"
    exit 1
  fi
}

##########################
# Main script starts here #
##########################

config_file='./config.json'
backupfolder="/home/backup"
global_file_name=''

check_jq
load_config

do_sql_backup
check_if_backup_exists

if [[ "$enable_www_backup" == "true" ]]; then
  do_www_backup
fi

log "Backup script completed successfully."
