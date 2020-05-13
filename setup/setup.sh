#!/usr/bin/env bash

# Setup script environment
set -o errexit  #Exit immediately if a pipeline returns a non-zero status
set -o errtrace #Trap ERR from shell functions, command substitutions, and commands from subshell
set -o nounset  #Treat unset variables as an error
set -o pipefail #Pipe will exit with last non-zero status if applicable
shopt -s expand_aliases
alias die='EXIT=$? LINE=$LINENO error_exit'
trap die ERR
trap 'die "Script interrupted."' INT

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

# Update container OS
msg "Updating container OS..."
apt-get update >/dev/null
apt-get -qqy upgrade &>/dev/null

# Install prerequisites
msg "Installing prerequisites..."
apt-get -qqy install \
    avahi-daemon curl jq network-manager &>/dev/null

# Customize Docker configuration
msg "Customizing Docker..."
DOCKER_CONFIG_PATH='/etc/docker/daemon.json'
mkdir -p $(dirname $DOCKER_CONFIG_PATH)
cat >$DOCKER_CONFIG_PATH <<'EOF'
{
  "log-driver": "journald"
}
EOF

# Install Docker
msg "Installing Docker..."
sh <(curl -sSL https://get.docker.com) &>/dev/null

# Install Home Assistant Supervisor
msg "Installing Home Assistant Supervisor..."
HASSIO_DOCKER=homeassistant/amd64-hassio-supervisor
HASSIO_SERVICE=hassio-supervisor.service
HASSIO_VERSION=$(curl -s https://version.home-assistant.io/stable.json | jq -e -r '.supervisor')
SYSTEMD_SERVICE_PATH=/etc/systemd/system
cat > /etc/hassio.json <<- EOF
{
    "supervisor": "${HASSIO_DOCKER}",
    "homeassistant": "homeassistant/qemux86-64-homeassistant",
    "data": "/usr/share/hassio"
}
EOF
docker pull "$HASSIO_DOCKER:$HASSIO_VERSION" > /dev/null
docker tag "$HASSIO_DOCKER:$HASSIO_VERSION" "$HASSIO_DOCKER:latest" > /dev/null
mv /setup/hassio-supervisor /usr/sbin/
mv /setup/$HASSIO_SERVICE $SYSTEMD_SERVICE_PATH

# Fix for Home Assistant Supervisor btime check
HA_PATH=$(jq --raw-output '.data' /etc/hassio.json)
mkdir -p ${SYSTEMD_SERVICE_PATH}/${HASSIO_SERVICE}.wants
mv /setup/hassio-fix-btime.service $SYSTEMD_SERVICE_PATH
ln -s ${SYSTEMD_SERVICE_PATH}/{hassio-fix-btime.service,hassio-supervisor.service.wants/}

# Start Home Assistant Supervisor service
msg "Starting Home Assistant Supervisor..."
systemctl daemon-reload
systemctl enable --now $HASSIO_SERVICE &> /dev/null

# Run Home Assistant cli when root login
msg "Changing 'root' shell to Home Assistant cli..."
HA_CLI_PATH=/usr/sbin/ha-cli
mv /setup/{ha,$(basename $HA_CLI_PATH)} $(dirname $HA_CLI_PATH)
chmod +x $HA_CLI_PATH
usermod --shell $HA_CLI_PATH root
echo "cd ${HA_PATH}" >> /root/.bashrc

# Customize container
msg "Customizing container..."
rm /etc/motd # Remove message of the day after login
rm /etc/update-motd.d/10-uname # Remove kernel information after login
touch ~/.hushlogin # Remove 'Last login: ' and mail notification after login

# Cleanup container
msg "Cleanup..."
apt-get autoremove >/dev/null
apt-get autoclean >/dev/null
rm -rf /setup /var/{cache,log}/* /var/lib/apt/lists/*
