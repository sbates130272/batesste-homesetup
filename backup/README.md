# batesste-homelab backups

Systemd and bash based methods for backing homelab data up to AWS S3.

## Disk backup (`batesste-s3-backup`)

A simple systemd timer runs once a day, reads a block device with `dd`,
compresses the stream with `pigz`, and writes the result to an AWS S3
bucket using [mountpoint-s3][ref-mountpoint].

### Installation

Before performing these steps use the instructions at the
[mountpoint][ref-mountpoint] site to ensure mountpoint is installed.
You also need to ensure `pigz` is installed.

Copy AWS credentials into a file in this folder called
`batesste-s3-backup.secrets` and ensure it is of the form:

```
BLK_DEVICE=<the block device you want to backup>
MOUNT_POINT=<the location for the mountpoint-s3 mount>
PRUNE_DAYS=<prune backups older than this number of days> (optional)
EXCEPT_DAY=<keep backups created on this day of the month> (optional)
AWS_ACCESS_KEY_ID=<my AWS key>
AWS_SECRET_ACCESS_KEY=<my AWS secret>
```

Note that `MOUNT_POINT` must *not* exist and the script will fail if
it does. The script deletes this folder once done. The script also
supports a `FILE_MODE` for arbitrary files instead of block devices.

Then proceed with the following steps:

1. `sudo cp batesste-s3-backup /usr/local/bin`.
1. `sudo cp batesste-s3-backup.service /etc/systemd/system/`.
1. `sudo cp batesste-s3-backup.timer /etc/systemd/system/`.
1. `sudo mkdir -p /usr/local/share/batesste-s3-backup`.
1. `sudo mv batesste-s3-backup.secrets /usr/local/share/batesste-s3-backup/`.
1. `sudo systemctl daemon-reload`
1. `sudo systemctl enable batesste-s3-backup.timer`
1. `sudo systemctl start batesste-s3-backup.timer`

## Hermes backup (`batesste-hermes-s3-backup`)

Weekly backup of the Hermes agent home directory (`~/.hermes/`) using
the built-in `hermes backup` command, followed by an upload to S3 with
the AWS CLI. This captures config, secrets, memories, skills,
sessions, and cron jobs while excluding the `hermes-agent` codebase.

The timer runs as a **user** systemd unit because Hermes itself runs
under `systemctl --user` on snoc-beelink.

### Prerequisites

- `hermes` on `PATH` (for example `~/.local/bin/hermes`)
- AWS CLI v2 (`aws`)
- An S3 bucket (default name: `batesste-hermes-backups`)

Create the bucket once:

```bash
aws s3 mb s3://batesste-hermes-backups --region us-west-2
aws s3api put-bucket-versioning \
  --bucket batesste-hermes-backups \
  --versioning-configuration Status=Enabled
```

### Installation

1. Copy `batesste-hermes-s3-backup.secrets.example` to
   `batesste-hermes-s3-backup.secrets` and fill in your AWS
   credentials. You can reuse the same key pair as the disk backup.
1. `sudo cp batesste-hermes-s3-backup /usr/local/bin/`
1. `mkdir -p ~/.config/batesste-hermes-s3-backup`
1. `cp batesste-hermes-s3-backup.secrets \
   ~/.config/batesste-hermes-s3-backup/`
1. `chmod 600 \
   ~/.config/batesste-hermes-s3-backup/batesste-hermes-s3-backup.secrets`
1. `cp batesste-hermes-s3-backup.service ~/.config/systemd/user/`
1. `cp batesste-hermes-s3-backup.timer ~/.config/systemd/user/`
1. `systemctl --user daemon-reload`
1. `systemctl --user enable batesste-hermes-s3-backup.timer`
1. `systemctl --user start batesste-hermes-s3-backup.timer`

### Manual run and restore

Run a backup immediately:

```bash
/usr/local/bin/batesste-hermes-s3-backup
```

Logs are appended to `~/.hermes/workspace/logs/hermes_s3_backup.log`.

Restore from S3 on the same or a new machine:

```bash
aws s3 cp s3://batesste-hermes-backups/<host>-hermes-backup-<timestamp>.zip ~/
systemctl --user stop hermes-gateway hermes-dashboard
hermes import ~/<host>-hermes-backup-<timestamp>.zip
systemctl --user start hermes-gateway hermes-dashboard
```

### Schedule and retention

| Setting | Default |
|---------|---------|
| Timer | Sunday 03:00 local time |
| S3 retention | 90 days (`PRUNE_DAYS`) |
| Local staging retention | 7 days under `/var/tmp/hermes-backup` |

[ref-mountpoint]: https://github.com/awslabs/mountpoint-s3
