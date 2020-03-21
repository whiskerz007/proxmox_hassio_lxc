#!/usr/bin/env bash

# Setup script environment
set -o errexit  #Exit immediately if a pipeline returns a non-zero status
set -o errtrace #Trap ERR from shell functions, command substitutions, and commands from subshell
set -o nounset  #Treat unset variables as an error
set -o pipefail #Pipe will exit with last non-zero status if applicable
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

# Customize Docker configuration
msg "Customizing Docker..."
# Set limit to Docker container log size
cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3" 
  }
}
EOF
systemctl restart docker

# Install Home Assistant
msg "Installing Home Assistant..."
bash <(curl -sL https://github.com/home-assistant/hassio-installer/raw/master/hassio_install.sh) &>/dev/null

# Fix for Home Assistant Supervisor btime check
HASSIO_PATH=$(jq --raw-output '.data' /etc/hassio.json)
SYSTEMD_SERVICE_PATH=/etc/systemd/system
mkdir -p ${SYSTEMD_SERVICE_PATH}/hassio-supervisor.service.wants
cat << EOF > ${SYSTEMD_SERVICE_PATH}/hassio-fix-btime.service
[Unit]
Description=Removal of Home Assistant last_boot parameter from config.json
Before=hassio-supervisor.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'sed -i -e "/last_boot/\x20s/\x5c\x22\x5c\x28\x5b0\x2d9\x5d.\x2a\x5c\x29\x5c\x22/\x5c\x22\x5c\x22/" ${HASSIO_PATH}/config.json'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
ln -s ${SYSTEMD_SERVICE_PATH}/{hassio-fix-btime.service,hassio-supervisor.service.wants/}

# Install hassio-cli
msg "Installing hassio-cli..."
ARCH=$(dpkg --print-architecture)
HASSIO_CLI=homeassistant/${ARCH}-hassio-cli
HASSIO_CLI_PATH=/usr/sbin/hassio-cli
docker pull $HASSIO_CLI >/dev/null
cat << EOF > $HASSIO_CLI_PATH
#!/usr/bin/env bash

set -o errexit
TMP=\$(mktemp) && trap "rm -f \$TMP" EXIT
HASSIO_JSON=${HASSIO_PATH}/homeassistant.json
if [ ! -f \${HASSIO_JSON} ]; then
  echo "Missing '\$HASSIO_JSON', dropping to bash."
  bash && exit
fi
jq --raw-output '.access_token' \${HASSIO_JSON} > \$TMP

docker container run --rm -it --init \
  --security-opt apparmor="docker-default" \
  -v \${TMP}:/etc/machine-id:ro \
  --network=hassio \
  --add-host hassio:172.30.32.2 \
  $HASSIO_CLI \
  /bin/cli.sh || \
( [ \$? -eq 10 ] && bash )
EOF
chmod +x $HASSIO_CLI_PATH
usermod --shell $HASSIO_CLI_PATH root
echo "cd ${HASSIO_PATH}" >> /root/.bashrc

# Customize container
msg "Customizing container..."
rm /etc/motd # Remove message of the day after login
rm /etc/update-motd.d/10-uname # Remove kernel information after login
touch ~/.hushlogin # Remove 'Last login: ' and mail notification after login
GETTY_OVERRIDE="/etc/systemd/system/container-getty@1.service.d/override.conf"
mkdir -p $(dirname $GETTY_OVERRIDE)
cat << EOF > $GETTY_OVERRIDE
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%I 115200,38400,9600 \$TERM
EOF
systemctl daemon-reload
systemctl restart $(basename $(dirname $GETTY_OVERRIDE) | sed 's/\.d//')

# Cleanup container
msg "Cleanup..."
rm -rf /setup.sh /var/{cache,log}/* /var/lib/apt/lists/*
