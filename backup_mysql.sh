#!/bin/sh
env_file='/home/credentials.env'
global_file_name=''

# config
notification_email=`cat "$env_file" | cut -d '|' -f4`

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
  backupfolder="/home/backup"
  fullpathbackupfile="$backupfolder/$filename"

  mysqldump --user=$sql_user --password=$sql_pass --default-character-set=utf8 --all-databases | gzip > "$fullpathbackupfile"

  # change file owner
  chown root "$fullpathbackupfile"

  done_time="$(date +'%H:%M:%S %p')"
  echo "Database dump successfully completed at $done_time - dir: $fullpathbackupfile"

  # set global file name
  global_file_name=$filename
}

check_if_backup_exists() {
  echo "Checking if the backup file ($global_file_name) was created successfully"
  # check if the backup file for today exists
  # and that the file size is not 0KB
  # or check mysqldump for errors 
  # else send email saying failed to backup

  if [ -s "$global_file_name" ]; then
    echo "$global_file_name exists on disk"
  else
    mail -s 'Error with DB backup task' $notification_email <<< "DB backup file ($global_file_name) was not created successfully"
  fi
}

do_credentials_config_check
do_sql_backup
check_if_backup_exists