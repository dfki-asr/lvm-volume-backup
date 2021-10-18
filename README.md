LVM Volume Backup Tools 
=======================

## Introduction

The `lvm_backup.sh` tool is designed to backup LVM volumes by using snapshots.

Running `lvm_backup.sh` with the `--help` option will output the help information below.

```
Backup LVM volumes

lvm_backup.sh [options]
options:
  -l, --list-volumes           Print list of LVM volumes
  -i, --ignore-volume=         Ignore volume specified in format VOLUME_GROUP/VOLUME_NAME
  -s, --snapshot-suffix=       Snapshot suffix used for backup snapshots (default: _xsnap)
      --                       End of options
```
