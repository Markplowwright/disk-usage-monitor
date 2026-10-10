# Design notes

## Bash 3.2

macOS still ships bash 3.2 as `/bin/bash`. The script uses `#!/usr/bin/env bash` and stays inside that version: `set -euo pipefail`, `[[` is avoided in favor of `[` and `case`, and there are no associative arrays (`declare -A`) and no `mapfile`. JSON is built with `printf` and `sed` so the script does not depend on `jq`. `df` output is still parsed with `awk`.

## Reading usage

`df -Pk` asks for POSIX output in 1024-byte blocks. On that format the capacity column is the field that looks like `33%`. The parser takes the first field matching `^[0-9]+%$` and strips the percent sign, instead of assuming a fixed column, so an extra column cannot be read as the usage percentage. A missing path, a failing `df`, or a non-integer percentage exits 2. The configured path may appear in that error. The webhook URL never does.

The default path is `/System/Volumes/Data` when `uname -s` is `Darwin`, and `/` otherwise. On a Mac, `/` is the small sealed system volume; the data volume is the disk that actually fills up. Linux and the Ubuntu image measure `/` unless `DISK_PATH` is set.

`DISK_THRESHOLD` must be an integer from 1 to 100. Values are parsed with base 10 (`$((10#…))`) so a leading zero is not treated as octal. `COOLDOWN_MIN` must be an integer greater than or equal to 0. Zero means every run over the threshold may alert.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Usage is below the threshold. |
| 1 | Usage is at or above the threshold. |
| 2 | Bad path, `df` failure, or bad configuration. |

A failed Slack POST prints `warning: Slack notification failed (curl exit N)` on stderr, where `N` is the curl exit code, and does not change the exit code. `curl` is invoked inside a conditional so `set -e` does not abort the run. A missing webhook on a real send prints a warning and also leaves the exit code unchanged.

## Alerts, cooldown, and recovery

State lives in `${XDG_STATE_HOME:-$HOME/.local/state}/disk-usage-monitor/state_<path>` (mode `600`). `<path>` is `DISK_PATH` with every character outside `A-Za-z0-9` replaced by `_`, so two paths do not share a file. Two fields are stored: `alerting` (`0` or `1`) and `last_alert_epoch` (unix time of the last successful alert).

Settings already in the environment win. For each of `DISK_PATH`, `DISK_THRESHOLD`, `COOLDOWN_MIN`, and `SLACK_WEBHOOK_URL` that is unset, the script reads that key from `${DISK_MONITOR_ENV:-<directory of this script>/.env}` when the file exists. Lines are `KEY=VALUE`. Blank lines and `#` comments are skipped, and one matching pair of surrounding quotes is stripped. The file is not sourced or eval'd. Anything still unset gets the default. `config/monitor.conf` is gitignored and is not read. Keep a local `.env` at mode `600`. Do not commit a webhook URL.

When used percent is at or above the threshold the run prints `ALERT` and exits 1.

- If `alerting` is already 1 and `now - last_alert_epoch` is inside `COOLDOWN_MIN`, the POST is skipped and the timestamp is left unchanged.
- Otherwise the script POSTs. `alerting=1` and the epoch are written only after `curl` exits 0. A failed POST, or a missing webhook, leaves the previous state, so the next run tries again.

When used percent drops below the threshold the run prints `OK` and exits 0. If `alerting` is 1, it POSTs a recovery message. Recovery is not cooldown-gated. `alerting=0` is written only after that POST succeeds, so a failed recovery is retried on the next OK run. The next time usage crosses the threshold, an alert is sent immediately.

`SLACK_WEBHOOK_URL` is used only when a message would actually be posted. If it is missing in that case, the script prints `warning: SLACK_WEBHOOK_URL not set, notification not sent` on stderr, does not write state, and continues. The exit code stays 1 for `ALERT` and 0 for `OK`. `--dry-run` does not need it and does not print that warning.

## Dry run

`--dry-run` prints the same status line. If a POST would happen, it prints the JSON body and stops. It does not call `curl` and does not create or update the state file. It still reads an existing state file, so an alert inside the cooldown produces the status line and no payload.

The payload shape is:

```json
{"text":"<hostname>: ALERT|RECOVERY <path> used <n>% (threshold <t>%)"}
```

`<hostname>` comes from `uname -n`.

## Webhook handling

The POST is `curl --max-time 10 -sS --fail`. Standard output and standard error from `curl` are discarded. Curl's own errors often include the request URL, and that URL is the secret, so the script prints a warning that includes only the curl exit code. The URL is not written to the status line, the payload, the env-file errors, or the state file. Example launchd and cron files, and `.env.example`, use the placeholder `REPLACE_WITH_SLACK_WEBHOOK_URL`.

## Scheduling

launchd `StartInterval` 900 and cron `*/15 * * * *` are the same 15-minute cadence. launchd does not expand shell variables in `ProgramArguments`, so the plist example uses `/ABSOLUTE/PATH/TO/...` placeholders. The Docker image is Ubuntu with `curl` and CA certificates, and the script is the entrypoint. Pass `DISK_PATH` into the container when the filesystem to measure is not the container's `/`.

## Not in this version

Email alerts are planned. This version notifies Slack only.
