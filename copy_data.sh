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

# Selection menu for features to copy
CTID_FEATURES=( $(
  whiptail --title "$TITLE" --checklist \
  "\nChoose features to copy to LXC '$CTID_TO'" 15 42 6 \
  boot "Startup boot option " ON \
  memory "Amount of memory " ON \
  swap "Amount of swap " ON \
  disk "Disk size " OFF \
  hostname "Hostname " OFF \
  net "Network settings " OFF 3>&1 1>&2 2>&3
) ) || exit

# Verify container selections
for i in ${!CTID_MENU[@]}; do
  [ "${CTID_MENU[$i]}" == "$CTID_FROM" ] && \
    CTID_FROM_HOSTNAME=$(sed 's/[[:space:]]*$//' <<<${CTID_MENU[$i+1]})
  [ "${CTID_MENU[$i]}" == "$CTID_TO" ] && \
    CTID_TO_HOSTNAME=$(sed 's/[[:space:]]*$//' <<<${CTID_MENU[$i+1]})
done
whiptail --defaultno --title "$TITLE" --yesno \
"Are you sure you want to move data between the following containers with specified features?


$CTID_FROM (${CTID_FROM_HOSTNAME}) -> $CTID_TO (${CTID_TO_HOSTNAME})
Features: ${CTID_FEATURES[*]//\"}" 13 50 || exit
info "Home Assistant data from '$CTID_FROM' to '$CTID_TO'"

# Shutdown container if running
if [ $(pct status $CTID_TO | sed 's/.* //') == 'running' ]; then
  msg "Stopping '$CTID_TO'..."
  pct stop $CTID_TO
fi

# Set LXC features
for i in ${!CTID_FEATURES[@]}; do
  case ${CTID_FEATURES[$i]//\"} in
    boot)
      FEATURES+=( "-$(pct config $CTID_FROM | sed -n '/^onboot/ s/://p')" );;
    disk)
      DISK_SIZE=$(pct config $CTID_FROM | sed -n '/^rootfs/ s/.*size=\(.*\).*/\1/p')
      if [ "$(pct config $CTID_TO | sed -n '/^rootfs/ s/.*size=\(.*\).*/\1/p')" != "$DISK_SIZE" ]; then
        msg "Resizing disk..."
        pct resize $CTID_TO rootfs $DISK_SIZE >/dev/null
      fi
      ;;
    hostname)
      FEATURES+=( "-$(pct config $CTID_FROM | sed -n '/^hostname/ s/://p')" );;
    memory)
      FEATURES+=( "-$(pct config $CTID_FROM | sed -n '/^memory/ s/://p')" );;
    net)
      FEATURES+=( "-$(pct config $CTID_FROM | sed -n '/^net/ s/://p')" );;
    swap)
      FEATURES+=( "-$(pct config $CTID_FROM | sed -n '/^swap/ s/://p')" );;
  esac
done
if [[ ! -z "${!FEATURES[@]}" ]]; then
  msg "Setting features..."
  pct set $CTID_TO ${FEATURES[*]}
fi

# Mount container disks
msg "Mounting container disks..."
HA_PATH=/usr/share/hassio
CTID_FROM_PATH=$(pct mount $CTID_FROM | sed -n "s/.*'\(.*\)'/\1/p") || \
  die "There was a problem mounting the root disk of LXC '${CTID_FROM}'."
[ -d "${CTID_FROM_PATH}${HA_PATH}" ] || \
  die "Home Assistant directories in '$CTID_FROM' not found."
CTID_TO_PATH=$(pct mount $CTID_TO | sed -n "s/.*'\(.*\)'/\1/p") || \
  die "There was a problem mounting the root disk of LXC '${CTID_TO}'."
[ -d "${CTID_TO_PATH}${HA_PATH}" ] || \
  die "Home Assistant directories in '$CTID_TO' not found."

# Remove destination container's data folders
DOCKER_PATH=/var/lib/docker
rm -rf ${CTID_TO_PATH}${HA_PATH}
rm -rf ${CTID_TO_PATH}${DOCKER_PATH}

# Increase destination container's rootfs size
AVAILABLE_SPACE=$(df $CTID_TO_PATH | awk 'NR>1 {print $4}')
REQUIRED_SPACE=$(du -sc ${CTID_FROM_PATH}{$HA_PATH,$DOCKER_PATH} | grep total | awk '{print $1}')
INCREASE_SPACE="+$(($(echo $REQUIRED_SPACE 1.05 | awk '{printf "%4.0f\n",$1*$2}') - $AVAILABLE_SPACE))K"
if [ $REQUIRED_SPACE -gt $AVAILABLE_SPACE ]; then
  msg "Increasing rootdisk of '$CTID_TO' with ${INCREASE_SPACE}..."
  pct unmount $CTID_TO
  pct resize $CTID_TO rootfs ${INCREASE_SPACE} >/dev/null
  pct mount $CTID_TO >/dev/null
  warn "Review of container '$CTID_TO' disk size is encouraged to prevent running out of space."
fi

# Copy data between containers
msg "Copying data between containers..."
RSYNC_OPTIONS=(
  --archive
  --hard-links
  --sparse
  --xattrs
  --no-inc-recursive
  --info=progress2
)
msg "<==== Home Assistant Data ====>"
rsync ${RSYNC_OPTIONS[*]} ${CTID_FROM_PATH}${HA_PATH} $(dirname ${CTID_TO_PATH}${HA_PATH})
echo -en "\e[1A\e[0K\e[1A\e[0K"
msg "<======== Docker Data ========>"
rsync ${RSYNC_OPTIONS[*]} ${CTID_FROM_PATH}${DOCKER_PATH} $(dirname ${CTID_TO_PATH}${DOCKER_PATH})
echo -en "\e[1A\e[0K\e[1A\e[0K"

info "Successfully transferred data."
