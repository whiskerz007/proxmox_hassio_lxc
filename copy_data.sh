#!/usr/bin/env bash

# Setup script environment
set -o errexit  #Exit immediately if a pipeline returns a non-zero status
set -o errtrace #Trap ERR from shell functions, command substitutions, and commands from subshell
set -o nounset  #Treat unset variables as an error
set -o pipefail #Pipe will exit with last non-zero status if applicable
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
function cleanup() {
  [ -d "${CTID_FROM_PATH:-}" ] && pct unmount $CTID_FROM
  [ -d "${CTID_TO_PATH:-}" ] && pct unmount $CTID_TO
  popd >/dev/null
  rm -rf $TEMP_DIR
}
TEMP_DIR=$(mktemp -d)
pushd $TEMP_DIR >/dev/null

# Generate menu of LXC containers
TITLE="Home Assistant LXC Data Copy"
while read -r line; do
  TAG=$(echo "$line" | awk '{print $1}')
  ITEM=$(echo "$line" | awk '{print substr($0,36)}')
  OFFSET=2
  if [[ $((${#ITEM} + $OFFSET)) -gt ${MSG_MAX_LENGTH:-} ]]; then
    MSG_MAX_LENGTH=$((${#ITEM} + $OFFSET))
  fi
  CTID_MENU+=( "$TAG" "$ITEM " "OFF" )
done < <(pct list | awk 'NR>1')

# Selection menus for LXC containers
while [ -z "${CTID_FROM:+x}" ]; do
  CTID_FROM=$(whiptail --title "$TITLE" --radiolist \
  "\nWhich container would you like to copy from?\n" \
  16 $(($MSG_MAX_LENGTH + 23)) 6 \
  "${CTID_MENU[@]}" 3>&1 1>&2 2>&3) || exit
done
while [ -z "${CTID_TO:+x}" ]; do
  CTID_TO=$(whiptail --title "$TITLE" --radiolist \
  "\nWhich container would you like to copy to?\n" \
  16 $(($MSG_MAX_LENGTH + 23)) 6 \
  "${CTID_MENU[@]}" 3>&1 1>&2 2>&3) || exit
done

# Verify container selections
CTID_FROM_HOSTNAME=$(pct config $CTID_FROM | grep hostname | sed -n 's/.* \(.*\)/\1/p')
CTID_TO_HOSTNAME=$(pct config $CTID_TO | grep hostname | sed -n 's/.* \(.*\)/\1/p')
whiptail --defaultno --title "$TITLE" --yesno \
"Are you sure you want to move data between the following containers?\n
\n$CTID_FROM (${CTID_FROM_HOSTNAME}) -> $CTID_TO (${CTID_TO_HOSTNAME})" 12 50 || exit
info "Home Assistant data from '$CTID_FROM' to '$CTID_TO'"

# Mount container disks
msg "Mounting container disks..."
CTID_FROM_PATH=$(pct mount $CTID_FROM | sed -n "s/.*'\(.*\)'/\1/p") || \
  die "There was a problem mounting the root disk of LXC '${CTID_FROM_PATH}'."
[ -d "${CTID_FROM_PATH}/usr/share/hassio" ] || \
  die "Home Assistant directories in '$CTID_FROM' not found."
CTID_TO_PATH=$(pct mount $CTID_TO | sed -n "s/.*'\(.*\)'/\1/p") || \
  die "There was a problem mounting the root disk of LXC '${CTID_TO_PATH}'."
[ -d "${CTID_TO_PATH}/usr/share/hassio" ] || \
  die "Home Assistant directories in '$CTID_TO' not found."

# Copy data between containers
msg "Copying data between containers..."
rm -rf ${CTID_TO_PATH}/usr/share/hassio
cp -r ${CTID_FROM_PATH}/usr/share/hassio ${CTID_TO_PATH}/usr/share/hassio

# Unmount container disks
msg "Unmounting container disks..."
pct unmount $CTID_FROM && unset CTID_FROM_PATH
pct unmount $CTID_TO && unset CTID_TO_PATH

# Reboot running LXC container
if [ $(pct status $CTID_TO | sed 's/.* //') == 'running' ]; then
  msg "Rebooting '$CTID_TO'..."
  pct reboot $CTID_TO
fi

info "Successfully transferred data."
