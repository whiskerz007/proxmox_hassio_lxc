# Hass.io in Proxmox LXC container

Many benefits can be gained by using a LXC container compared to a VM. The resources needed to run a LXC container are less than running a VM. Modifing the resouces assigned to the LXC container can be done without having to reboot the container. The serial devices connected to Proxmox can be shared with multiple LXC containers simulatenously.

## Usage

***Note:*** _Before using this repo, make sure Proxmox is up to date._

To create a new LXC container on Proxmox and setup Hass.io to run inside of it, run the following in a SSH connection or the Proxmox web shell.

```
bash -c "$(wget -qLO - https://github.com/whiskerz007/proxmox_hassio_lxc/raw/master/create_container.sh)"
```

## Copy data between containers

To ease the process of updating the LXC configuration, a script has been provided. To copy Home Assistant data from one container to another, run the following in a SSH connection or the Proxmox web shell.

```
bash -c "$(wget -qLO - https://github.com/whiskerz007/proxmox_hassio_lxc/raw/master/copy_data.sh)"
```

## Known limitations

- Unable to use bluetooth devices due to the limitation of LXC
- Setting up container on a ZFS pool will cause issues with addons that use mySQL/MariaDB due to ZFS not implementing `fallocate` properly

## Console

There is no login required to access the console from the Proxmox web UI. If you are presented with a blank screen, press `CTRL + C` to generate a prompt.
