#!/bin/bash

#This script is used to stop mac from having .local in hostname which is automatically changed when bluetooth and airdrop is used

this_mac_name=$(hostname)
echo "hostname = \"$this_mac_name\""

before_last_period=$(echo "$this_mac_name" | awk -F'.' '{$NF=""; sub(/\.$/, ""); print}')
trimmed_hostname="${before_last_period%"${before_last_period##*[![:space:]]}"}"
echo "the revised hostname = \"$trimmed_hostname\""

if scutil --set HostName "$trimmed_hostname"; then
    echo "Hostname successfully set."
    exit 0  # true
else
    echo "Failed to set hostname."
    exit 1  # false
fi
