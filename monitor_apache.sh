#!/bin/bash

FILE=/run/httpd/httpd.pid
env_file='/home/monitor_config.env'

do_credentials_config_check() {
  if [[ -f "$env_file" ]]; then
    echo 'Config file does not exist - creating one'
    touch "$env_file"
  fi
}

do_apache_check() {
    server_name=`cat "$env_file" | cut -d '|' -f1`
    server_ip=`cat "$env_file" | cut -d '|' -f2`

    if ! [ -f "$FILE" ]; then
        systemctl start httpd.service
    fi

    sleep 10s
    if ! [ -f "$FILE" ]; then
        systemctl start httpd.service
    fi

    sleep 10s
    if ! [ -f "$FILE" ]; then
        systemctl start httpd.service
    fi

    sleep 10s
    if ! [ -f "$FILE" ]; then
        mail -s 'Apache is down' admin@joeygallegos.com <<< "Apache is down on $server_name ($server_ip) and cannot be restarted"
    fi
}

do_credentials_config_check
do_apache_check