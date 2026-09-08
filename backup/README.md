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

Settings and credentials come from two separate files, both read by
the unit as `EnvironmentFile=`:

| File | Holds | Managed by |
|---|---|---|
| `batesste-s3-backup.conf` | `BLK_DEVICE`, `MOUNT_POINT`, `AWS_BUCKET`, `AWS_REGION`, `PRUNE_DAYS`, `EXCEPT_DAY` | this repo |
| `~/.secrets.env` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | [batesste-dotfiles][ref-dotfiles], stowed |

Credentials used to be pasted into a `.secrets` file next to the
config and copied into place by hand. They now arrive with the rest of
the dotfiles, so a new host needs `stow secrets` and nothing else. The
split also means the settings above are versioned here rather than
existing only on the host that happened to be set up first.

Two things follow from `~/.secrets.env` being the source. It is
git-crypt encrypted in the dotfiles repo, so it must be unlocked on
the host before the timer will work. And it carries every credential
in that file, not just the AWS pair, into the environment of a backup
that runs as root — narrow that to an AWS-only file, or a stowed
`~/.aws/credentials`, if that ever stops being an acceptable trade.

Note that `MOUNT_POINT` must *not* exist and the script will fail if
it does. The script deletes this folder once done. The script also
supports a `FILE_MODE` for arbitrary files instead of block devices.

If a run ever leaves `MOUNT_POINT` behind, every later run aborts on
that guard until the directory is removed by hand. The exit trap
tolerates a failed `umount` specifically so this cannot recur.

Then proceed with the following steps:

1. `sudo cp batesste-s3-backup /usr/local/bin`.
1. `sudo cp batesste-s3-backup.service /etc/systemd/system/`.
1. `sudo cp batesste-s3-backup.timer /etc/systemd/system/`.
1. `sudo mkdir -p /usr/local/share/batesste-s3-backup`.
1. `sudo cp batesste-s3-backup.conf /usr/local/share/batesste-s3-backup/`.
1. `sudo systemctl daemon-reload`
1. `sudo systemctl enable batesste-s3-backup.timer`
1. `sudo systemctl start batesste-s3-backup.timer`

## Hermes backup (`batesste-hermes-s3-backup`)

> **Disabled as of 3 Sep 2026.** The timer is installed but not
> enabled. The archive step works; the upload does not, because the
> `batesste-hermes-backups` bucket has never been created and the AWS
> key is rejected with `InvalidAccessKeyId` — the same key the disk
> backup uses, so that one fails on its next run too. CI confirms it
> independently: `backup-test` gets `The AWS Access Key Id you
> provided does not exist in our records` from the CI bucket. Rotating
> the key means updating `~/.secrets.env` in the dotfiles repo *and*
> the `AWS_KEY` / `AWS_SECRET` repository secrets, which are separate
> stores. Create the bucket and install a working key before
> re-enabling with `systemctl --user enable --now
> batesste-hermes-s3-backup.timer`. This backup has never completed
> successfully.

Weekly backup of the Hermes agent home directory (`~/.hermes/`) using
the built-in `hermes backup` command, followed by an upload to S3 with
the AWS CLI. This captures config, secrets, memories, skills,
sessions, and cron jobs while excluding the `hermes-agent` codebase.

The timer runs as a **user** systemd unit because Hermes itself runs
under `systemctl --user` on snoc-beelink. The user manager's PATH does
not include `~/.local/bin`, so the unit sets `PATH` explicitly; without
it `hermes` is not found and every run dies in the `require_command`
guard.

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

Credentials come from `~/.secrets.env` exactly as the disk backup
takes them, so there is nothing to fill in by hand; `stow secrets`
covers both.

1. `sudo cp batesste-hermes-s3-backup /usr/local/bin/`
1. `mkdir -p ~/.config/batesste-hermes-s3-backup`
1. `cp batesste-hermes-s3-backup.conf \
   ~/.config/batesste-hermes-s3-backup/`
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
[ref-dotfiles]: https://github.com/sbates130272/batesste-dotfiles
