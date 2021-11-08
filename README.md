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
      --ignore-mount-error     Ignore errors when mounting volumes and continue with other volumes
  -s, --snapshot-prefix=       Snapshot prefix used for backup snapshots (default: bak_snap_)
  -w, --part-rw                Add partitions in read/write mode
      --overwrite              Overwrite backup files
  -p, --dest-prefix=           Destination path prefix (add / at the end for directory)
      --rsync                  Use rsync instead of tar
  -d, --debug                  Enable debug mode
      --log-file=              Log all output and errors to the specified log file
      --                       End of options
```
