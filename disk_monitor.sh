#!/usr/bin/env bash
# Report one filesystem and post a Slack alert when usage stays over a threshold.
# Bash 3.2 safe: no associative arrays, no mapfile.
set -euo pipefail

DRY_RUN=0
alerting=0
last_alert_epoch=0
state_dir=""
state_file=""

die() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

json_escape() {
  # Escape \ first, then ", so the value can sit inside a JSON string.
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

load_env_file() {
  local env_file line trimmed key value
  env_file=${DISK_MONITOR_ENV:-$(dirname "$0")/.env}
  if [ ! -e "$env_file" ]; then
    return 0
  fi
  if [ ! -f "$env_file" ] || [ ! -r "$env_file" ]; then
    die "cannot read env file"
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed=${line#"${line%%[![:space:]]*}"}
    case "$trimmed" in
      ''|\#*) continue ;;
    esac
    case "$trimmed" in
      *=*) ;;
      *) continue ;;
    esac
    key=${trimmed%%=*}
    value=${trimmed#*=}
    case "$value" in
      \"*\")
        value=${value#\"}
        value=${value%\"}
        ;;
      \'*\')
        value=${value#\'}
        value=${value%\'}
        ;;
    esac
    case "$key" in
      DISK_PATH)
        if [ -z "${DISK_PATH+x}" ]; then
          DISK_PATH=$value
        fi
        ;;
      DISK_THRESHOLD)
        if [ -z "${DISK_THRESHOLD+x}" ]; then
          DISK_THRESHOLD=$value
        fi
        ;;
      COOLDOWN_MIN)
        if [ -z "${COOLDOWN_MIN+x}" ]; then
          COOLDOWN_MIN=$value
        fi
        ;;
      SLACK_WEBHOOK_URL)
        if [ -z "${SLACK_WEBHOOK_URL+x}" ]; then
          SLACK_WEBHOOK_URL=$value
        fi
        ;;
    esac
  done < "$env_file"
}

load_state() {
  local key value
  alerting=0
  last_alert_epoch=0
  if [ -z "$state_file" ] || [ ! -e "$state_file" ]; then
    return 0
  fi
  if [ ! -r "$state_file" ]; then
    die "cannot read state file"
  fi
  while IFS='=' read -r key value; do
    case "$key" in
      alerting)
        case "$value" in
          0|1) alerting=$value ;;
        esac
        ;;
      last_alert_epoch)
        case "$value" in
          ''|*[!0-9]*) ;;
          *) last_alert_epoch=$((10#$value)) ;;
        esac
        ;;
    esac
  done < "$state_file"
}

save_state() {
  local new_alerting new_epoch tmp old_umask
  new_alerting=$1
  new_epoch=$2
  if [ -z "$state_dir" ]; then
    die "HOME or XDG_STATE_HOME is required to store alert state"
  fi
  if ! mkdir -p "$state_dir"; then
    die "could not create state directory"
  fi
  tmp="${state_file}.tmp.$$"
  old_umask=$(umask)
  umask 077
  if ! printf 'alerting=%s\nlast_alert_epoch=%s\n' "$new_alerting" "$new_epoch" > "$tmp"; then
    umask "$old_umask"
    die "could not write state file"
  fi
  if ! mv -f "$tmp" "$state_file"; then
    umask "$old_umask"
    die "could not write state file"
  fi
  umask "$old_umask"
  chmod 600 "$state_file" || die "could not set state file permissions"
}

build_payload() {
  local kind host_raw host_esc path_esc
  kind=$1
  host_raw=$(uname -n)
  host_esc=$(json_escape "$host_raw")
  path_esc=$(json_escape "$DISK_PATH")
  printf '{"text":"%s: %s %s used %s%% (threshold %s%%)"}\n' \
    "$host_esc" "$kind" "$path_esc" "$used" "$threshold"
}

send_slack() {
  local payload curl_status
  payload=$1
  curl_status=0
  # stderr is discarded so a curl error cannot echo the webhook URL.
  curl --max-time 10 -sS --fail -X POST \
    -H 'Content-type: application/json' \
    --data "$payload" \
    --url "$SLACK_WEBHOOK_URL" \
    >/dev/null 2>/dev/null || curl_status=$?
  if [ "$curl_status" -ne 0 ]; then
    printf 'warning: Slack notification failed (curl exit %s)\n' "$curl_status" >&2
    return 1
  fi
  return 0
}

if [ "$#" -gt 1 ]; then
  die "usage: disk_monitor.sh [--dry-run]"
fi

if [ "$#" -eq 1 ]; then
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    *) die "usage: disk_monitor.sh [--dry-run]" ;;
  esac
fi

os_name=$(uname -s)
case "$os_name" in
  Darwin) default_path="/System/Volumes/Data" ;;
  *) default_path="/" ;;
esac

load_env_file

DISK_PATH=${DISK_PATH-$default_path}
DISK_THRESHOLD=${DISK_THRESHOLD-85}
COOLDOWN_MIN=${COOLDOWN_MIN-240}
SLACK_WEBHOOK_URL=${SLACK_WEBHOOK_URL-}

case "$DISK_THRESHOLD" in
  ''|*[!0-9]*) die "DISK_THRESHOLD must be an integer from 1 to 100" ;;
esac
threshold=$((10#$DISK_THRESHOLD))
if [ "$threshold" -lt 1 ] || [ "$threshold" -gt 100 ]; then
  die "DISK_THRESHOLD must be an integer from 1 to 100"
fi

case "$COOLDOWN_MIN" in
  ''|*[!0-9]*) die "COOLDOWN_MIN must be an integer greater than or equal to 0" ;;
esac
cooldown_min=$((10#$COOLDOWN_MIN))

if [ -z "$DISK_PATH" ]; then
  die "DISK_PATH is empty"
fi
if [ ! -e "$DISK_PATH" ]; then
  die "path does not exist: $DISK_PATH"
fi

if ! df_out=$(df -Pk -- "$DISK_PATH" 2>/dev/null); then
  die "df failed for path: $DISK_PATH"
fi

used_raw=$(printf '%s\n' "$df_out" | awk '
  NR > 1 {
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^[0-9]+%$/) {
        gsub(/%/, "", $i)
        print $i
        exit
      }
    }
  }
')

case "$used_raw" in
  ''|*[!0-9]*) die "could not parse disk usage for path: $DISK_PATH" ;;
esac
used=$((10#$used_raw))

if [ -n "${XDG_STATE_HOME:-}" ]; then
  state_dir="${XDG_STATE_HOME}/disk-usage-monitor"
elif [ -n "${HOME:-}" ]; then
  state_dir="${HOME}/.local/state/disk-usage-monitor"
else
  state_dir=""
fi

if [ -n "$state_dir" ]; then
  path_key=$(printf '%s' "$DISK_PATH" | sed 's/[^A-Za-z0-9]/_/g')
  state_file="${state_dir}/state_${path_key}"
else
  state_file=""
fi

load_state

stamp=$(date '+%Y-%m-%dT%H:%M:%S%z')
now_epoch=$(date +%s)

if [ "$used" -ge "$threshold" ]; then
  status="ALERT"
else
  status="OK"
fi

printf '%s %s path=%s used=%s%%\n' "$stamp" "$status" "$DISK_PATH" "$used"

if [ "$status" = "ALERT" ]; then
  should_send=1
  if [ "$alerting" -eq 1 ]; then
    elapsed=$((now_epoch - last_alert_epoch))
    limit=$((cooldown_min * 60))
    if [ "$elapsed" -lt "$limit" ]; then
      should_send=0
    fi
  fi
  if [ "$should_send" -eq 1 ]; then
    payload=$(build_payload "ALERT")
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '%s\n' "$payload"
    else
      if [ -z "$SLACK_WEBHOOK_URL" ]; then
        printf 'warning: SLACK_WEBHOOK_URL not set, notification not sent\n' >&2
      elif send_slack "$payload"; then
        save_state 1 "$now_epoch"
      fi
    fi
  fi
  exit 1
fi

if [ "$alerting" -eq 1 ]; then
  payload=$(build_payload "RECOVERY")
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s\n' "$payload"
  else
    if [ -z "$SLACK_WEBHOOK_URL" ]; then
      printf 'warning: SLACK_WEBHOOK_URL not set, notification not sent\n' >&2
    elif send_slack "$payload"; then
      save_state 0 "$last_alert_epoch"
    fi
  fi
fi

exit 0
