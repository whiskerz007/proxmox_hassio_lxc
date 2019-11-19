#!/usr/bin/env bash

set -Eeuo pipefail
shopt -s expand_aliases
alias die='EXIT=$? LINE=$LINENO error_exit'
trap die ERR
trap cleanup EXIT
function error_exit() {
  trap - ERR
  local DEFAULT='Unknown failure occured.'
  local REASON="\e[97m${1:-$DEFAULT}\e[39m"
  local FLAG="\e[91m[ERROR] \e[93m$EXIT@$LINE"
  msg "$FLAG $REASON"
  [ ! -z ${CTID-} ] && cleanup_failed
  exit $EXIT
}
function warn() {
  local REASON="\e[97m$1\e[39m"
  local FLAG="\e[93m[WARNING]\e[39m"
  msg "$FLAG $REASON"
}
function info() {
  local REASON="$1"
  local FLAG="\e[36m[INFO]\e[39m"
  msg "$FLAG $REASON"
}
function msg() {
  local TEXT="$1"
  echo -e "$TEXT"
}
function cleanup_failed() {
  if [ ! -z ${MOUNT+x} ]; then
    pct unmount $CTID
  fi
  if $(pct status $CTID &>/dev/null); then
    if [ "$(pct status $CTID | awk '{print $2}')" == "running" ]; then
      pct stop $CTID
    fi
    pct destroy $CTID
  elif [ "$(pvesm list $STORAGE --vmid $CTID)" != "" ]; then
    pvesm free $ROOTFS
  fi
}
function cleanup() {
  popd >/dev/null
  rm -rf $TEMP_DIR
}
function load_module() {
  if ! $(lsmod | grep -Fq $1); then
    modprobe $1 &>/dev/null || \
      die "Failed to load '$1' module."
  fi
  MODULES_PATH=/etc/modules
  if ! $(grep -Fxq "$1" $MODULES_PATH); then
    echo "$1" >> $MODULES_PATH || \
      die "Failed to add '$1' module to load at boot."
  fi
}
TEMP_DIR=$(mktemp -d)
pushd $TEMP_DIR >/dev/null

# Download setup script
wget -qL https://github.com/whiskerz007/proxmox_hassio_lxc/raw/master/setup.sh

# Detect modules and automatically load at boot
load_module aufs
load_module overlay

# Select storage location
STORAGE_LIST=( $(pvesm status -content rootdir | awk 'NR>1 {print $1}') )
if [ ${#STORAGE_LIST[@]} -eq 0 ]; then
  warn "'Container' needs to be selected for at least one storage location."
  die "Unable to detect valid storage location."
elif [ ${#STORAGE_LIST[@]} -eq 1 ]; then
  STORAGE=${STORAGE_LIST[0]}
else
  msg "\n\nMore than one storage locations detected.\n"
  PS3=$'\n'"Which storage location would you like to use? "
  select s in "${STORAGE_LIST[@]}"; do
    if [[ " ${STORAGE_LIST[@]} " =~ " ${s} " ]]; then
      STORAGE=$s
      break
    fi
    echo -en "\e[1A\e[K\e[1A"
  done
fi
info "Using '$STORAGE' for storage location."

# Get the next guest VM/LXC ID
CTID=$(pvesh get /cluster/nextid)
info "Container ID is $CTID."

# Download latest Debian LXC template
msg "Updating LXC template list..."
pveam update >/dev/null
msg "Downloading LXC template..."
OSTYPE=debian
OSVERSION=${OSTYPE}-10
mapfile -t TEMPLATES < <(pveam available -section system | sed -n "s/.*\($OSVERSION.*\)/\1/p" | sort -t - -k 2 -V)
TEMPLATE="${TEMPLATES[-1]}"
pveam download local $TEMPLATE >/dev/null ||
  die "A problem occured while downloading the LXC template."

# Create variables for container disk
STORAGE_TYPE=$(pvesm status -storage $STORAGE | awk 'NR>1 {print $2}')
case $STORAGE_TYPE in
  dir|nfs)
    DISK_EXT=".raw"
    DISK_REF="$CTID/"
    ;;
  zfspool)
    DISK_PREFIX="subvol"
    DISK_FORMAT="subvol"
    ;;
esac
DISK=${DISK_PREFIX:-vm}-${CTID}-disk-0${DISK_EXT-}
ROOTFS=${STORAGE}:${DISK_REF-}${DISK}

# Create LXC
msg "Creating LXC container..."
pvesm alloc $STORAGE $CTID $DISK 4G --format ${DISK_FORMAT:-raw} >/dev/null
if [ "$STORAGE_TYPE" != "zfspool" ]; then
  mke2fs $(pvesm path $ROOTFS) &>/dev/null
fi
ARCH=$(dpkg --print-architecture)
HOSTNAME=hassio
TEMPLATE_STRING="local:vztmpl/${TEMPLATE}"
pct create $CTID $TEMPLATE_STRING -arch $ARCH -cores 1 -features nesting=1 \
  -hostname $HOSTNAME -net0 name=eth0,bridge=vmbr0,ip=dhcp -onboot 1 \
  -ostype $OSTYPE -password "hassio" -rootfs $ROOTFS -storage $STORAGE >/dev/null

# Modify LXC permissions to support Docker
LXC_CONFIG=/etc/pve/lxc/${CTID}.conf
cat <<EOF >> $LXC_CONFIG
lxc.cgroup.devices.allow: a
lxc.cap.drop:
EOF

# Add access to ttyACM,ttyS,ttyUSB,net/tun devices
cat <<'EOF' >> $LXC_CONFIG
lxc.autodev: 1
lxc.hook.autodev: bash -c 'for dev in $(ls /dev/tty{ACM,S,USB}* 2>/dev/null) $([ -d "/dev/bus" ] && find /dev/bus -type c) /dev/mem /dev/net/tun; do mkdir -p $(dirname ${LXC_ROOTFS_MOUNT}${dev}); for link in $(udevadm info --query=property $dev | sed -n "s/DEVLINKS=//p"); do mkdir -p ${LXC_ROOTFS_MOUNT}$(dirname $link); cp -dR $link ${LXC_ROOTFS_MOUNT}${link}; done; cp -dR $dev ${LXC_ROOTFS_MOUNT}${dev}; done'
EOF

# Set container timezone to match host
MOUNT=$(pct mount $CTID | cut -d"'" -f 2)
ln -fs $(readlink /etc/localtime) ${MOUNT}/etc/localtime
pct unmount $CTID && unset MOUNT

# Setup container for Hass.io
msg "Starting LXC container..."
pct start $CTID
pct push $CTID setup.sh /setup.sh -perms 755
pct exec $CTID -- bash -c "/setup.sh"

# Get network details and show completion message
IP=$(pct exec $CTID ip a s dev eth0 | sed -n '/inet / s/\// /p' | awk '{print $2}')
info "Successfully created Hass.io LXC to $CTID."
msg "

Hass.io is reachable by going to the following URLs.

      http://${IP}:8123
      http://${HOSTNAME}.local:8123

"
