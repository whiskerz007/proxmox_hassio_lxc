#!/usr/bin/env bash

set -Eeuo pipefail
shopt -s expand_aliases
alias die='EXIT=$? LINE=$LINENO error_exit'
trap die ERR
function error_exit() {
  trap - ERR
  local DEFAULT='Unknown failure occured.'
  local REASON="\e[97m${1:-$DEFAULT}\e[39m"
  local FLAG="\e[91m[ERROR:LXC] \e[93m$EXIT@$LINE"
  msg "$FLAG $REASON"
  exit $EXIT
}
function msg() {
  local TEXT="$1"
  echo -e "$TEXT"
}

# Prepare container OS
msg "Setting up container OS..."
sed -i "/$LANG/ s/\(^# \)//" /etc/locale.gen
locale-gen >/dev/null
apt-get -y purge openssh-{client,server} >/dev/null
apt-get autoremove >/dev/null

# Update container OS
msg "Updating container OS..."
apt-get update >/dev/null
apt-get -qqy upgrade &>/dev/null

# Install prerequisites
msg "Installing prerequisites..."
apt-get -qqy install \
    avahi-daemon curl jq network-manager &>/dev/null

# Install Docker
msg "Installing Docker..."
sh <(curl -sSL https://get.docker.com) &>/dev/null

# Install Hass.io
msg "Installing Hass.io..."
bash <(curl -sL https://github.com/home-assistant/hassio-installer/raw/master/hassio_install.sh) &>/dev/null

# Fix for Hass.io Supervisor btime check
mkdir -p /etc/systemd/system/hassio-supervisor.service.wants
cat << EOF > /etc/systemd/system/hassio-fix-btime.service
[Unit]
Description=Removal of Hass.io last_boot parameter from config.json
Before=hassio-supervisor.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'sed -i -e "/last_boot/\x20s/\x5c\x22\x5c\x28\x5b0\x2d9\x5d.\x2a\x5c\x29\x5c\x22/\x5c\x22\x5c\x22/" /usr/share/hassio/config.json'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
ln -s /etc/systemd/system/{hassio-fix-btime.service,hassio-supervisor.service.wants/}

# Cleanup container
msg "Cleanup..."
rm -rf /setup.sh /var/{cache,log}/* /var/lib/apt/lists/*
