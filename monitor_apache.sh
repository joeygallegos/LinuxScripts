#!/bin/bash

# /var/run/apache2/apache2.pid
env_file='/home/monitor_config.env'

do_credentials_config_check() {
  if [[ -f "$env_file" ]]; then
    echo 'Config file does not exist - creating one'
    touch "$env_file"
  fi
}

do_apache_check() {
    process_id=`cat "$env_file" | cut -d '|' -f1`
    server_name=`cat "$env_file" | cut -d '|' -f2`
    server_ip=`cat "$env_file" | cut -d '|' -f3`

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
        mail -s 'Apache is down' admin@joeygallegos.com <<< echo "Apache is down on $server_name ($server_ip) and cannot be restarted"
    fi
}

do_credentials_config_check
do_apache_check