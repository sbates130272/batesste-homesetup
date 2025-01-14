# batesste-s3-dyndns

A simple systemd and bash based method for backing whole disk images
up to AWS S3 via [mountpoint-s3][ref-mountpoint].

## Overview

This simple framework runs a bash script once a day and uses dd to
read a disk image, pipe it into a compression algorithm and then push
the result to a AWS S3 bucket using the mountpoint-3 FUSE.

## Installation

Before performing these steps use the instructions at the
[mountpoint][ref-mountpoint] site to ensure mountpoint is
installed. You also need to ensure pigz is installed.

Copy my AWS credentials into a file in this folder called
```batesste-s3-backup.secrets``` and ensure it is of the form:
```
BLK_DEVICE=<the block device you want to backup>
MOUNT_POINT=<the location for the mountpoint-s3 mount>
AWS_ACCESS_KEY_ID=<my AWS key>
AWS_SECRET_ACCESS_KEY=<my AWS secret>
```
Note that MOUNT_POINT must *not* exist and the script will fail if it
does. the script will delete this folder once done. Also note that a
FILE_MODE exists that can backup arbitrary files instead of block
devices.

Then proceed with the following steps:
1. ```sudo cp batesste-s3-backup /usr/local/bin```.
1. ```sudo cp batesste-s3-backup.service /etc/systemd/system/```.
1. ```sudo cp batesste-s3-backup.timer /etc/systemd/system/```.
1. ```sudo mkdir -p /usr/local/share/batesste-s3-backup```.
1. ```sudo mv batesste-s3-backup.secrets /usr/local/share/batesste-s3-backup/```.
1. ```sudo systemctl daemon-reload```
1. ```sudo systemctl enable batesste-s3-backup.timer```
1. ```sudo systemctl start batesste-s3-backup.timer```

[ref-mountpoint]: https://github.com/awslabs/mountpoint-s3
