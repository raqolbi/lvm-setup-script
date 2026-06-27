# LVM Manager

Interactive Bash script for managing LVM (Logical Volume Manager) on **Ubuntu Server 24.04 LTS**.

`lvm-manager.sh` provides a guided menu to create new LVM storage, extend existing logical volumes, and inspect the current LVM layout — with confirmations, input validation, and logging suitable for production use.

## Features

- Interactive menu-driven workflow
- Automatic detection of empty, unused disks
- Create full LVM stack: partition → PV → VG → LV → filesystem → mount → `/etc/fstab`
- Extend existing LVs (optionally add a new disk to the VG)
- Automatic filesystem resize (`resize2fs` for ext4, `xfs_growfs` for xfs)
- Display LVM and disk information (`lsblk`, `pvs`, `vgs`, `lvs`, `df`, mounts)
- Colored terminal output and session logging
- Safety checks to protect the OS/root disk and existing data



## Requirements


| Item       | Details                 |
| ---------- | ----------------------- |
| OS         | Ubuntu Server 24.04 LTS |
| Shell      | Bash only               |
| Privileges | **root** (`sudo`)       |




### Packages

Install dependencies on Ubuntu 24.04:

```bash
sudo apt-get update
sudo apt-get install -y lvm2 parted e2fsprogs xfsprogs util-linux
```


| Command                                                    | Package                    |
| ---------------------------------------------------------- | -------------------------- |
| `lsblk`, `blkid`, `findmnt`                                | `util-linux`               |
| `parted`, `partprobe`                                      | `parted`                   |
| `pvcreate`, `vgcreate`, `vgextend`, `lvcreate`, `lvextend` | `lvm2`                     |
| `resize2fs`                                                | `e2fsprogs`                |
| `xfs_growfs`                                               | `xfsprogs`                 |
| `mount`, `df`                                              | `util-linux` / `coreutils` |


The script checks for missing commands at startup and prints the required package names.

## Installation

```bash
git clone <repository-url>
cd lvm-setup-script
chmod +x lvm-manager.sh
```



## Usage

```bash
sudo ./lvm-manager.sh
```



### Menu

```
========================================
LVM Manager
========================================

1. Create New LVM
2. Extend Existing LVM
3. Show LVM Information
4. Exit
```



## Workflows



### 1. Create New LVM

1. Detect and select an empty disk (auto-selected if only one is found)
2. Confirm the operation
3. Create GPT partition table and a single LVM partition
4. Create Physical Volume (PV)
5. Prompt for Volume Group (VG) name
6. Prompt for Logical Volume (LV) name and size (`100G`, `50G`, `100%FREE`, etc.)
7. Choose filesystem: `ext4` or `xfs`
8. Prompt for mount point (directory created if missing)
9. Mount the LV and append a UUID entry to `/etc/fstab`
10. Verify the mount and print a success summary



### 2. Extend Existing LVM

1. Select an existing Volume Group
2. Select a Logical Volume inside that VG
3. If an empty disk is available, optionally add it to the VG (`pvcreate` + `vgextend`)
4. Enter extension size (`+50G`, `+100G`, `+100%FREE`, etc.)
5. Run `lvextend` and resize the filesystem automatically
6. Print final size summary



### 3. Show LVM Information

Displays a formatted report of:

- `lsblk` — block devices
- `pvs` — physical volumes
- `vgs` — volume groups (including free space)
- `lvs` — logical volumes
- `df -h` — disk usage
- Active mounts and filesystem types
- Root/OS disk and available empty disks



## Empty Disk Detection

A disk is offered for use only when **all** of the following are true:

- `TYPE=disk` in `lsblk`
- Not mounted (disk or any child)
- Has no partitions
- Has no filesystem signature (`blkid`)
- Is not a Physical Volume
- Is not used by any Volume Group
- Is **not** the root/OS disk


| Disks found | Behavior                               |
| ----------- | -------------------------------------- |
| 0           | Message: `No available disk detected.` |
| 1           | Automatically selected                 |
| 2+          | Interactive selection menu             |




## Safety

The script is designed to avoid accidental data loss:

- Never offers the root/OS disk as an empty disk
- Skips disks that are mounted, partitioned, or already part of LVM
- Asks for confirmation before destructive operations
- **Double confirmation** before:
  - `mklabel` (partition table creation)
  - `pvcreate`
  - `vgcreate`
  - `lvcreate`
  - `mkfs` (filesystem format)
- Backs up `/etc/fstab` before appending new entries
- Skips duplicate `fstab` entries (same mount point or UUID)
- Aborts immediately on command failure (`set -Eeuo pipefail`)

> **Warning:** Operations on the wrong disk can destroy data. Always verify disk selection in virtualized or cloud environments where device names (`/dev/sdb`, `/dev/nvme1n1`, etc.) may differ between reboots.



## Logging

All actions are logged to:

```
/var/log/lvm-manager.log
```

Each executed command is printed to the terminal and recorded in the log file.

## Example: Create LVM on a New Disk

Assume `/dev/sdb` is a blank 500 GB data disk:

```bash
sudo ./lvm-manager.sh
# Select: 1. Create New LVM
# Confirm disk: /dev/sdb
# VG name: data-vg
# LV name: lv-storage
# LV size: 100%FREE
# Filesystem: ext4
# Mount point: /data
```

Expected summary:

```
========================================
Operation Completed Successfully
========================================

VG         : data-vg
LV         : lv-storage
Filesystem : ext4
Mount      : /data
Size       : 500G
========================================
```



## Example: Extend an Existing LV

```bash
sudo ./lvm-manager.sh
# Select: 2. Extend Existing LVM
# Select VG: data-vg
# Select LV: lv-storage
# Use new disk? yes  (if /dev/sdc is available)
# Extension size: +100%FREE
```

The script extends the LV and grows the filesystem to use the new space.

## Troubleshooting


| Issue                                 | Suggestion                                                                                    |
| ------------------------------------- | --------------------------------------------------------------------------------------------- |
| `No available disk detected`          | Attach a new disk or ensure the target disk has no partitions, filesystem, or LVM signatures  |
| `This script must be run as root`     | Run with `sudo ./lvm-manager.sh`                                                              |
| Missing command errors                | Install packages listed in [Requirements](#packages)                                          |
| Partition not found after `partprobe` | Wait a few seconds and retry; check `dmesg` for kernel errors                                 |
| `xfs_growfs requires a mount point`   | Ensure the LV is mounted before extending an XFS volume                                       |
| Operation aborted mid-way             | Check `/var/log/lvm-manager.log` and run `lsblk`, `pvs`, `vgs`, `lvs` to assess partial state |




## Script Structure

The script is organized into reusable functions:

```
check_root          print_header        print_menu
detect_empty_disks  choose_disk         create_partition
create_pv           create_vg           create_lv
format_fs           mount_lv            update_fstab
extend_vg           extend_lv           resize_filesystem
show_info           confirm_action      log
cleanup
```



## License

MIT License. 



Use at your own risk on production systems — test in a non-production environment first.