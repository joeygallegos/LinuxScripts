#!/bin/sh
env_file='/home/credentials.env'

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
  sql_port=`cat "$env_file" | cut -d '|' -f3`

  filename="db_backup_$now".gz
  backupfolder="/home/backup"
  fullpathbackupfile="$backupfolder/$filename"

  mysqldump --user=$sql_user --password=$sql_pass --default-character-set=utf8 --port=$sql_port --all-databases | gzip > "$fullpathbackupfile"
  chown root "$fullpathbackupfile"

  done_at="$(date +'%H:%M:%S %p')"
  echo "Database dump successfully completed at $done_at - dir: $fullpathbackupfile"
}

do_credentials_config_check
do_sql_backup