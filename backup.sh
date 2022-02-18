#!/bin/sh
env_file='/home/credentials.env'
backupfolder="/home/backup"
wwwfolder="/var/www"
global_file_name=''

# config
notification_email=`cat "$env_file" | cut -d '|' -f4`

load_env() {
  local envFile="${1?Missing environment file}"
  local environmentAsArray variableDeclaration
  mapfile environmentAsArray < <(
    grep --invert-match '^#' "${envFile}" \
      | grep --invert-match '^\s*$'
  ) # Uses grep to remove commented and blank lines
  for variableDeclaration in "${environmentAsArray[@]}"; do
    export "${variableDeclaration//[$'\r\n']}" # The substitution removes the line breaks
  done
}

# load env file
load_env .env

do_credentials_config_check() {
  if [[ -f "$env_file" ]]; then
    echo 'Config file does not exist - creating one'
    touch "$env_file"
  fi
}

do_sql_backup() {
  now="$(date +'%m_%d_%Y_%H_%M')"
  now_pretty="$(date +'\%H:\%M:\%S \%p')"

  # split data from file by delimiter
  sql_user=`cat "$env_file" | cut -d '|' -f1`
  sql_pass=`cat "$env_file" | cut -d '|' -f2`

  filename="db_backup_$now".gz
  fullpathbackupfile="$backupfolder/$filename"

  # try running dump command
  if result = mysqldump --user=$sql_user --password=$sql_pass --default-character-set=utf8 --all-databases
  then
    result | gzip > "$fullpathbackupfile"

    # change file owner
    chown root "$fullpathbackupfile"

    done_time="$(date +'%H:%M:%S %p')"
    echo "Database dump successfully completed at $done_time - output file: $fullpathbackupfile"

    # set global file name
    global_file_name=$filename
  else
    mail -s 'Error with mysqldump command' $notification_email <<< "An error occoured while executing mysqldump"
  fi
}

do_www_backup() {
  now="$(date +'%m_%d_%Y_%H_%M')"
  now_pretty="$(date +'\%H:\%M:\%S \%p')"
  
  # check if www directory exists
  if [ -s "$wwwfolder" ]; then
    echo "The configured www folder exists on disk"
    
    filename="www_backup_$now".gz
    fullpathbackupfile="$backupfolder/$filename"
    
    # tar backup dir
    # might throw warning about leading slash in member names
    tar -zcf $fullpathbackupfile "$wwwfolder/"
  else
    echo "The configured www folder doesn't seem to exist, sending notification for the error"
    mail -s 'Error during www folder backup' $notification_email <<< "The configured www folder ($wwwfolder) doesn't seem to exist"
  fi
}

check_if_backup_exists() {
  echo "Checking if the backup file ($global_file_name) was created successfully"
  # check if the backup file for today exists
  # and that the file size is not 0KB
  # or check mysqldump for errors 
  # else send email saying failed to backup

  if [ -s "$backupfolder/$global_file_name" ]; then
    echo "Backup file $global_file_name exists on disk"
  else
    echo "File doesn't seem to exist, sending notification for the error"
    mail -s 'Error with DB backup task' $notification_email <<< "DB backup file ($global_file_name) was not created successfully"
  fi
}

do_credentials_config_check
do_sql_backup
check_if_backup_exists
do_www_backup
