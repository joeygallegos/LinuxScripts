#!/bin/bash

# /var/run/apache2/apache2.pid
env_file='/home/monitor_apache_config.env'

do_credentials_config_check() {
  if [[ ! -f "$env_file" ]]; then
    echo 'Config file does not exist - creating one'
    touch "$env_file"
  fi
}

# check the apache pid three times per second
# if the pid is not found, then try to start apache three times
do_apache_check() {
    process_id=`cat "$env_file" | cut -d '|' -f1`
    server_name=`cat "$env_file" | cut -d '|' -f2`
    server_ip=`cat "$env_file" | cut -d '|' -f3`
    notification_email=`cat "$env_file" | cut -d '|' -f4`

    if ! [ -f "$process_id" ]; then
        systemctl start apache2.service
    fi

    sleep 10s
    if ! [ -f "$process_id" ]; then
        systemctl start apache2.service
    fi

    sleep 10s
    if ! [ -f "$process_id" ]; then
        systemctl start apache2.service
    fi

    sleep 10s
    if ! [ -f "$process_id" ]; then
        mail -s 'Apache is down' $notification_email <<< "Apache is down on $server_name ($server_ip) and cannot be restarted"
    fi
}

do_credentials_config_check
do_apache_check