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

Then install the monitoring, which is a separate step only because it
lives with the other node-exporter collectors:

```bash
cd ../prometheus/textfile-collectors && ./deploy-agent.sh
```

It detects `batesste-s3-backup.service` and installs `s3-backup-age`
alongside the collectors it already manages. Run it *after* the config
above is in place — it reads `batesste-s3-backup.conf` for the bucket
name and skips itself with a warning if that file is missing.

### Monitoring

Nothing watched this backup until 8 Sep 2026, and it showed:
every run from June 2025 onward was rejected with
`InvalidAccessKeyId`, and the bucket went fifteen months without a
new object while `systemctl status` looked ordinary and CI stayed
green. It was found by listing the bucket by hand.

Three things now cover it, and they are deliberately independent —
each one fails differently:

1. **`s3-backup-age` textfile collector**
   (`prometheus/textfile-collectors/`) publishes
   `batesste_s3_backup_*` hourly by querying S3 for the newest object
   under this host's prefix. It checks the *artifact*, not the unit's
   exit status.
2. **Four Grafana alert rules**
   (`grafana/provisioning/alerting/rules.yaml`) page to ntfy on a
   failed check, an empty bucket, an object older than 48h, or one
   under 5 GB.
3. **A weekly CI run** (`backup-test`) exercises the script against a
   CI bucket and now *fails* rather than warns when the AWS
   credentials are rejected, so key rot surfaces without waiting for
   someone to open a PR against `backup/`.
4. **A weekly restore test** (`backup-restore-test`) reads the newest
   backup back out of the bucket and checks it is a sound disk image.
   The first three all confirm that *an object of a plausible size
   arrived*; none of them opens it. See below.

One known gap, unmonitored:

- **The script has no `set -o pipefail`.** In `dd | pigz > file` only
  `pigz`'s status reaches the shell, so a `dd` that dies partway
  produces a complete, valid, too-small `.gz` and the unit exits 0.
  The `BackupTooSmall` rule catches the symptom, and the restore
  test's gzip-trailer check catches it exactly; the cause is still
  there.

### Restore testing

`verify-backup-image.sh` answers the question none of the monitoring
above can: does the backup actually read back? A backup nobody has
restored is a hypothesis, and until 8 Sep 2026 none of these ever had
been.

It does not restore all 238 GiB. It creates a *sparse* file the size
of the original disk, streams only the first 4 GiB of the image into
it, and checks what lands in that window — which turns out to be
everything structural:

| Checked | How |
|---|---|
| Archive is whole | gzip ISIZE trailer, read with a 4-byte ranged GET, against the true disk size |
| GPT | `sfdisk -J` on a loop device |
| EFI partition | `fsck.fat -n` |
| `/boot` | `fsck.ext4 -fn`, with a journal replay if needed |
| LVM | PV label, then the VG metadata parsed out of the first MiB |
| Root LV | ext4 superblock magic, last mount point, and size cross-checked against the LVM allocation |

The sparse full-size file is not a nicety. A plainly truncated image
has no valid GPT at all — the secondary header lives in the last
sectors of the disk, and without it the kernel falls back to the
protective MBR and reports one 4 GiB partition of type `0xee`.

Run it by hand against any object:

```bash
./verify-backup-image.sh --bucket batesste-homelab-backups \
  --key snoc-beelink-dev-sda-2026-09-08-13-00.gz
```

Roughly a gigabyte of transfer and about two and a half minutes.

Two results are expected on every healthy run and are reported as
notes rather than failures, because the image is a `dd` of a *live,
mounted* disk: the EFI partition's dirty bit is set, and `loki-lv`
starts beyond the 4 GiB window so its superblock is never read.

**What this does not prove:** that the other 234 GiB is intact. The
trailer check catches a truncated archive, which is the failure the
backup script can actually produce, but corruption in the middle of an
otherwise complete archive would pass. Only a full stream would catch
that, at roughly $3 of egress per run.

CI runs this weekly as `backup-restore-test`, which also fails if the
newest object in the bucket is more than 7 days old. That overlaps the
`BackupStale` Grafana rule deliberately: the rule depends on the
collector, node-exporter and Grafana all being alive on snoc-beelink,
and this job depends on snoc-beelink not at all.

It needs `RESTORE_AWS_KEY` / `RESTORE_AWS_SECRET` repository secrets —
see the credential table below for why it does not share either of the
other two pairs.

There is also a retention hazard worth knowing about. `PRUNE_DAYS=30`
with `EXCEPT_DAY=1` keeps only 1st-of-month files long term, so a
backup taken on any other day is pruned after 30 days. The recovery
run is dated 8 Sep 2026 and is therefore due to be pruned on 8 Oct
2026. The first *durable* snapshot needs a clean run on 1 Oct
2026; until that lands, the newest permanent backup in the bucket is
still `2025-06-01`, and if the backup breaks again in the meantime the
recovery run disappears with it.

### CI credentials

Three separate AWS credential pairs touch the backups, each with its
own IAM user. They are not interchangeable, and the point of keeping
them apart is that no single leaked secret can both write the CI
bucket and reach the real backups:

| Store | Used by | IAM user | Grants |
|---|---|---|---|
| `~/.secrets.env` on snoc-beelink | the live backup | `batesste` | read/write on `batesste-homelab-backups` |
| `BACKUP_TEST_AWS_KEY` / `BACKUP_TEST_AWS_SECRET` | `backup-test` | `github-backup-test` | read/write on `batesste-homelab-backups-ci` only |
| `RESTORE_AWS_KEY` / `RESTORE_AWS_SECRET` | `backup-restore-test` | `github-restore-test` | read-only on `batesste-homelab-backups` |

`backup-test` used to use `AWS_KEY`/`AWS_SECRET`, which belong to
`batesste` — an admin user that can create IAM users and write every
bucket in the account. Those two secrets remain only because
`dyndns-test` needs them for Route53; nothing under `backup/` should
use them again.

`github-backup-test` needs no `s3:DeleteObject`, because `backup-test`
never sets `PRUNE_DAYS` and so never prunes. To recreate the user:

```bash
cat > /tmp/backup-test-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListCIBucket",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::batesste-homelab-backups-ci"
    },
    {
      "Sid": "ReadWriteCIObjects",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:AbortMultipartUpload"
      ],
      "Resource": "arn:aws:s3:::batesste-homelab-backups-ci/*"
    }
  ]
}
EOF

aws iam create-user --user-name github-backup-test
aws iam put-user-policy --user-name github-backup-test \
  --policy-name ci-bucket-readwrite \
  --policy-document file:///tmp/backup-test-policy.json
```

Then mint the key and pipe it straight into the repository secrets so
it never lands in the scrollback or the shell history:

```bash
CREDS=$(aws iam create-access-key --user-name github-backup-test --output json)
jq -rj .AccessKey.AccessKeyId <<<"${CREDS}" \
  | gh secret set BACKUP_TEST_AWS_KEY --repo sbates130272/batesste-homesetup
jq -rj .AccessKey.SecretAccessKey <<<"${CREDS}" \
  | gh secret set BACKUP_TEST_AWS_SECRET --repo sbates130272/batesste-homesetup
unset CREDS
rm -f /tmp/backup-test-policy.json
```

`jq -rj` rather than `-r`: a trailing newline becomes part of the
secret, and the resulting signature failure looks exactly like a wrong
key.

## Hermes backup (`batesste-hermes-s3-backup`)

> **Disabled as of 3 Sep 2026.** The timer is installed but not
> enabled. The archive step works; the upload does not, because the
> `batesste-hermes-backups` bucket has never been created. This backup
> has never completed successfully.
>
> The key in `~/.secrets.env` was rotated on 8 Sep 2026 and the disk
> backup now works with it, so the `InvalidAccessKeyId` half of this
> is resolved. The missing bucket is not. Note that the repository
> secrets are a *separate* store from `~/.secrets.env` — rotating one
> does not rotate the other, they have drifted apart before, and that
> drift is now a CI failure rather than a warning.
>
> Create the bucket, then re-enable with `systemctl --user enable
> --now batesste-hermes-s3-backup.timer`. Note that the backup alert
> rules deliberately do not cover Hermes while it is disabled — see
> `grafana/provisioning/alerting/rules.yaml`.

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
