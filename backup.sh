#!/bin/sh

# Function to check if jq is installed
check_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "$(date +'%Y-%m-%d %H:%M:%S'): Error: jq is not installed. Please install jq first."
    exit 1
  fi
}

# Call the function to check for jq
check_jq

config_file='config.json'
backupfolder="/home/backup"
global_file_name=''

# Function to send error notifications via Mailgun
send_mailgun_notification() {
  subject=$1
  message=$2
  curl -s --user "api:$mailgun_api_key" \
    https://api.mailgun.net/v3/$mailgun_domain/messages \
    -F from="$mailgun_from" \
    -F to="$notification_email" \
    -F subject="$subject" \
    -F text="$message"
}

# Read config values
echo "$(date +'%Y-%m-%d %H:%M:%S'): Attempting to read configuration file"
load_config() {
  if [[ -f "$config_file" ]]; then
    sql_user=$(jq -r '.sql_user' "$config_file")
    sql_pass=$(jq -r '.sql_pass' "$config_file")
    sql_port=$(jq -r '.sql_port' "$config_file")
    notification_email=$(jq -r '.notification_email' "$config_file")
    mailgun_api_key=$(jq -r '.mailgun_api_key' "$config_file")
    mailgun_domain=$(jq -r '.mailgun_domain' "$config_file")
    mailgun_from=$(jq -r '.mailgun_from' "$config_file")
    www_directories=$(jq -r '.www_directories[]' "$config_file")
    enable_www_backup=$(jq -r '.enable_www_backup' "$config_file")
  else
    echo "$(date +'%Y-%m-%d %H:%M:%S'): Error: Config file does not exist or problem reading file - exiting"
    exit 1
  fi
}

load_config

do_sql_backup() {
  now="$(date +'%Y_%m_%d_%H_%M')"
  filename="db_backup_$now.sql"
  gzfilename="db_backup_$now.sql.gz"
  fullpathbackupfile="$backupfolder/$filename"
  fullpathgzbackupfile="$backupfolder/$gzfilename"
  
  echo "$(date +'%Y-%m-%d %H:%M:%S'): Starting SQL backup"
  
  # try running dump command
  if mysqldump --user=$sql_user --password=$sql_pass --port=$sql_port --default-character-set=utf8 --all-databases > "$fullpathbackupfile"; then
    # compress the sql file
    gzip "$fullpathbackupfile"
    
    # change file owner
    chown root "$fullpathgzbackupfile"
    
    echo "$(date +'%Y-%m-%d %H:%M:%S'): Database dump successfully completed - output file: $fullpathgzbackupfile"
    
    # set global file name
    global_file_name=$gzfilename
  else
    error_message="An error occurred while executing mysqldump"
    echo "$(date +'%Y-%m-%d %H:%M:%S'): $error_message"
    send_mailgun_notification 'Error with mysqldump command' "$error_message"
  fi
}

do_www_backup() {
  now="$(date +'%Y_%m_%d_%H_%M')"
  filename="www_backup_$now.tar"
  gzfilename="www_backup_$now.tar.gz"
  fullpathbackupfile="$backupfolder/$filename"
  fullpathgzbackupfile="$backupfolder/$gzfilename"

  echo "$(date +'%Y-%m-%d %H:%M:%S'): Starting WWW backup"
  
  # check if directories exist and add them to the tar file
  for dir in $www_directories; do
    if [ ! -d "$dir" ]; then
      error_message="The directory $dir doesn't seem to exist"
      echo "$(date +'%Y-%m-%d %H:%M:%S'): $error_message"
      send_mailgun_notification 'Error during WWW folder backup' "$error_message"
      return  # exit function if any directory is missing
    else
      tar -rf "$fullpathbackupfile" "$dir"
    fi
  done

  # compress the tar file
  gzip "$fullpathbackupfile"

  echo "$(date +'%Y-%m-%d %H:%M:%S'): Directories backed up successfully - output file: $fullpathgzbackupfile"
}
``
check_if_backup_exists() {
  echo "$(date +'%Y-%m-%d %H:%M:%S'): Checking if the backup file ($global_file_name) was created successfully"
  
  if [ -s "$backupfolder/$global_file_name" ]; then
    echo "$(date +'%Y-%m-%d %H:%M:%S'): Backup file $global_file_name exists on disk"
  else
    error_message="DB backup file ($global_file_name) was not created successfully"
    echo "$(date +'%Y-%m-%d %H:%M:%S'): $error_message"
    send_mailgun_notification 'Error with DB backup task' "$error_message"
  fi
}

do_sql_backup
check_if_backup_exists

# Call the WWW backup function if the feature flag is set to true
if [[ "$enable_www_backup" == "true" ]]; then
  do_www_backup
fi
