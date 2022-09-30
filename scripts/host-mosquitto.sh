#!/usr/bin/env bash

conf_path="./test-files"
conf_name="mqtt-broker.conf"
conf=$(find $conf_path -name $conf_name)

echo_dbg () {
 echo "$(tput setaf 2)host-mosquitto.sh: $1 $(tput sgr0)"
}

echo_err () {
 echo "$(tput setaf 1)host-mosquitto.sh: $1 $(tput sgr0)"
}

if [ conf ]; then
  echo_dbg "using (${conf}) as the mosquitto config."
  $(mosquitto -v -c $conf $@)
else
  echo_err "error: (${conf}) not found: cannot start mosquitto."
fi
