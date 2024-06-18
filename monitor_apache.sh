#!/bin/bash

# Paths to configuration files
apache_config_file='/home/monitor_apache_config.json'
mailgun_config_file='/home/config.json'

# Function to check and create the configuration file if it doesn't exist
do_credentials_config_check() {
  if [[ ! -f "$apache_config_file" ]]; then
    echo 'Apache config file does not exist - creating one'
    touch "$apache_config_file"
  fi
  if [[ ! -f "$mailgun_config_file" ]]; then
    echo 'Mailgun config file does not exist - creating one'
    touch "$mailgun_config_file"
  fi
}

# Function to send email using Mailgun
send_mailgun_email() {
  local subject="$1"
  local body="$2"
  local to_email="$3"

  local mailgun_api_key=$(jq -r '.mailgun_api_key' "$mailgun_config_file")
  local mailgun_domain=$(jq -r '.mailgun_domain' "$mailgun_config_file")
  local mailgun_from=$(jq -r '.mailgun_from' "$mailgun_config_file")

  curl -s --user "api:$mailgun_api_key" \
    https://api.mailgun.net/v3/"$mailgun_domain"/messages \
    -F from="$mailgun_from" \
    -F to="$to_email" \
    -F subject="$subject" \
    -F text="$body"
}

# Function to check the Apache PID and try to restart Apache if necessary
do_apache_check() {
    local process_id=$(jq -r '.process_id_file' "$apache_config_file")
    local server_name=$(hostname)
    local server_ip=$(jq -r '.server_ip' "$apache_config_file")
    local notification_email=$(jq -r '.notification_email' "$apache_config_file")

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
        send_mailgun_email 'Apache is down' "Apache is down on $server_name ($server_ip) and cannot be restarted" "$notification_email"
    fi
}

do_credentials_config_check
do_apache_check
