# /usr/local/bin/backup.sh
#!/bin/sh
# POSIX shell. Backups with logging, rotation, retention, WWW/SQL, excludes, free-space guard.
# Improved: stream-compress WWW backups to avoid large intermediate tar files.

set -eu

# ----------------------------- Defaults --------------------------------------
BACKUP_DIR_DEFAULT="/home/backup"
LOG_DIR_DEFAULT="/var/log/backup"
LOG_FILE_DEFAULT="$LOG_DIR_DEFAULT/backup.log"
LOG_MAX_BYTES_DEFAULT=$((10 * 1024 * 1024)) # 10MB
RETENTION_DAYS_DEFAULT=14
ENABLE_MAIL_DEFAULT="false"
ENABLE_WWW_DEFAULT="false"
BACKUP_MIN_FREE_MB_DEFAULT=0   # 0 = disabled

# CLI flags
DRY_RUN="false"
SKIP_SQL="false"
SKIP_WWW="false"
SELF_TEST="false"
NO_MAIL="false"
CONFIG_FILE="${CONFIG_FILE:-}"   # resolved later

# Globals for cleanup
TEMP_FILES=""
PARTIAL_FILES=""

# ------------------------------ Utils ----------------------------------------
ts() { date +'%Y-%m-%d %H:%M:%S'; }
err() { printf "%s: ERROR: %s\n" "$(ts)" "$*" >&2; }
log() { printf "%s: %s\n" "$(ts)" "$*" | tee -a "$LOG_FILE" >&2; }  # why: visible+logged
die() { err "$*"; notify_mail "Backup script failure" "$*"; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."; }
mktemp_file() { f="$(mktemp)"; TEMP_FILES="$TEMP_FILES $f"; printf "%s" "$f"; }
track_partial() { PARTIAL_FILES="$PARTIAL_FILES $1"; }

cleanup() {
  set +e
  [ -n "$TEMP_FILES" ] && rm -f $TEMP_FILES 2>/dev/null || true
  # Remove partial artifacts if we exited with error
  if [ "${CLEAN_EXIT:-0}" -ne 1 ] && [ -n "$PARTIAL_FILES" ]; then
    rm -f $PARTIAL_FILES 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

rotate_logs_if_needed() {
  [ -f "$LOG_FILE" ] || return 0
  size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
  max="${LOG_MAX_BYTES:-$LOG_MAX_BYTES_DEFAULT}"
  if [ "$size" -gt "$max" ]; then
    stamp="$(date +'%Y%m%d-%H%M%S')"
    dst="$LOG_FILE.$stamp"
    mv "$LOG_FILE" "$dst" || true
    if command -v gzip >/dev/null 2>&1; then gzip -f "$dst" || true; fi
    : > "$LOG_FILE"
  fi
}

notify_mail() {
  subj=$1; msg=$2
  [ "$NO_MAIL" = "true" ] && return 0
  [ "${ENABLE_MAIL:-$ENABLE_MAIL_DEFAULT}" != "true" ] && return 0
  [ -n "${MAILGUN_API_KEY:-}" ] || return 0
  [ -n "${MAILGUN_DOMAIN:-}" ] || return 0
  [ -n "${MAILGUN_FROM:-}" ] || return 0
  [ -n "${NOTIFY_EMAIL:-}" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  curl -s --user "api:$MAILGUN_API_KEY" \
    "https://api.mailgun.net/v3/$MAILGUN_DOMAIN/messages" \
    -F "from=$MAILGUN_FROM" -F "to=$NOTIFY_EMAIL" \
    -F "subject=$subj" -F "text=$msg" >/dev/null 2>&1 || true
}

safe_mkdir() {
  d="$1"
  if [ ! -d "$d" ]; then
    [ "$DRY_RUN" = "true" ] && { log "[dry-run] mkdir -p $d"; return 0; }
    mkdir -p "$d" || die "Failed to create directory: $d"
  fi
  [ -w "$d" ] || die "Directory not writable: $d"
}

is_gnu_tar() { tar --version 2>/dev/null | head -n1 | grep -qi "gnu"; }

disk_free_mb() { df -Pm "$BACKUP_DIR" 2>/dev/null | awk 'NR==2{print $4+0}'; }

preflight_free_space() {
  need="${BACKUP_MIN_FREE_MB:-$BACKUP_MIN_FREE_MB_DEFAULT}"
  [ "$need" -gt 0 ] || return 0
  have="$(disk_free_mb || echo 0)"
  if [ "$have" -lt "$need" ]; then
    die "Insufficient free space at $(df -P "$BACKUP_DIR" | awk 'NR==2{print $6}'): have ${have}MB < need ${need}MB"
  fi
}

usage() {
  cat <<EOF
backup.sh — database + WWW backup with logging, rotation, retention
Usage: backup.sh [--config PATH] [--dry-run] [--skip-sql] [--skip-www] [--self-test] [--no-mail]
Config lookup:
  1) --config PATH
  2) CONFIG_FILE env
  3) /home/config.json
  4) \$HOME/config.json
  5) ./config.json
  6) /etc/backup/config.json
EOF
}

# ------------------------------ CLI ------------------------------------------
while [ "${1:-}" ]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2;;
    --dry-run) DRY_RUN="true"; shift;;
    --skip-sql) SKIP_SQL="true"; shift;;
    --skip-www) SKIP_WWW="true"; shift;;
    --self-test) SELF_TEST="true"; shift;;
    --no-mail) NO_MAIL="true"; shift;;
    -h|--help) usage; exit 0;;
    *) err "Unknown arg: $1"; usage; exit 2;;
  esac
done

# ----------------------- Resolve config path ---------------------------------
resolve_config_file() {
  if [ -n "${CONFIG_FILE:-}" ] && [ -f "$CONFIG_FILE" ]; then printf "%s" "$CONFIG_FILE"; return 0; fi
  for p in /home/config.json "${HOME:-}/config.json" "./config.json" "/etc/backup/config.json"; do
    [ -f "$p" ] && { printf "%s" "$p"; return 0; }
  done
  printf "%s" ""
}
CONFIG_FILE="$(resolve_config_file || true)"

# ------------------------- Early logging setup --------------------------------
LOG_DIR="${LOG_DIR_DEFAULT}"
LOG_FILE="${LOG_FILE_DEFAULT}"
safe_mkdir "$LOG_DIR" || true
touch "$LOG_FILE" 2>/dev/null || true
rotate_logs_if_needed || true
echo "$(ts): INFO: Config: ${CONFIG_FILE:-<defaults>}" | tee -a "$LOG_FILE" >&2

# ---------------------------- jq helper --------------------------------------
jq_or_default() {
  # $1 filter, $2 default
  if [ -n "$CONFIG_FILE" ]; then
    val=$(jq -er "$1 // empty" "$CONFIG_FILE" 2>/dev/null || true)
    [ -n "$val" ] && { printf "%s" "$val"; return 0; }
  fi
  printf "%s" "$2"
}

# --------------------------- Read config -------------------------------------
SQL_USER="$(jq_or_default '.sql_user' '')"
SQL_PASS="$(jq_or_default '.sql_pass' '')"
SQL_PORT="$(jq_or_default '.sql_port' '3306')"

NOTIFY_EMAIL="$(jq_or_default '.notification_email' '')"
MAILGUN_API_KEY="$(jq_or_default '.mailgun_api_key' '')"
MAILGUN_DOMAIN="$(jq_or_default '.mailgun_domain' '')"
MAILGUN_FROM="$(jq_or_default '.mailgun_from' '')"

WWW_DIRS="$( [ -n "$CONFIG_FILE" ] && jq -r '.www_directories[]? // empty' "$CONFIG_FILE" 2>/dev/null || printf "" )"
WWW_EXCLUDES="$( [ -n "$CONFIG_FILE" ] && jq -r '.www_exclude_patterns[]? // empty' "$CONFIG_FILE" 2>/dev/null || printf "" )"

ENABLE_WWW="$(jq_or_default '.enable_www_backup' "$ENABLE_WWW_DEFAULT")"
ENABLE_MAIL="$(jq_or_default '.enable_mail' "$ENABLE_MAIL_DEFAULT")"

BACKUP_DIR="$(jq_or_default '.backup_dir' "$BACKUP_DIR_DEFAULT")"
LOG_DIR="$(jq_or_default '.log_dir' "$LOG_DIR_DEFAULT")"
LOG_FILE="$(jq_or_default '.log_file' "$LOG_FILE_DEFAULT")"
LOG_MAX_BYTES="$(jq_or_default '.log_max_bytes' "$LOG_MAX_BYTES_DEFAULT")"
RETENTION_DAYS="$(jq_or_default '.retention_days' "$RETENTION_DAYS_DEFAULT")"
BACKUP_MIN_FREE_MB="$(jq_or_default '.backup_min_free_mb' "$BACKUP_MIN_FREE_MB_DEFAULT")"

# Ensure dirs/logs (final)
safe_mkdir "$BACKUP_DIR"
safe_mkdir "$LOG_DIR"
safe_mkdir "$(dirname "$LOG_FILE")"
touch "$LOG_FILE" 2>/dev/null || die "Cannot write to log file: $LOG_FILE"
rotate_logs_if_needed

# Redirect stdout/stderr to log
exec 1> >(tee -a "$LOG_FILE") 2>&1

log "Starting backup run"
log "Config: BACKUP_DIR=$BACKUP_DIR, ENABLE_WWW=$ENABLE_WWW, DRY_RUN=$DRY_RUN, MIN_FREE_MB=$BACKUP_MIN_FREE_MB"

# ----------------------------- Tool checks -----------------------------------
require_cmd jq
require_cmd gzip
require_cmd tar
require_cmd date
[ "$SKIP_SQL" = "true" ] || require_cmd mysqldump

# ------------------------------ Retention ------------------------------------
apply_retention() {
  days="$1"
  [ "$days" -gt 0 ] || return 0
  log "Retention: deleting files older than $days days in $BACKUP_DIR"
  find "$BACKUP_DIR" -maxdepth 1 -type f \( -name 'db_backup_*.gz' -o -name 'www_backup_*.gz' -o -name 'selftest.tar.gz' \) \
    -mtime +"$days" -print | while IFS= read -r f; do
      if [ "$DRY_RUN" = "true" ]; then
        log "[dry-run] delete $f"
      else
        rm -f -- "$f" || log "Failed to remove $f"
      fi
    done
}

# ------------------------------ Backups --------------------------------------
GLOBAL_DB_FILE=""

do_sql_backup() {
  [ "$SKIP_SQL" = "true" ] && { log "SQL backup skipped by flag"; return 0; }

  now="$(date +'%Y_%m_%d_%H_%M')"
  sql_file="db_backup_${now}.sql"
  sql_gz="db_backup_${now}.sql.gz"
  sql_path="$BACKUP_DIR/$sql_file"
  sql_gz_path="$BACKUP_DIR/$sql_gz"

  log "SQL backup starting"
  if [ "$DRY_RUN" = "true" ]; then
    log "[dry-run] mysqldump > $sql_path && gzip $sql_path"
    GLOBAL_DB_FILE="$sql_gz"
    return 0
  fi

  if mysqldump --user="$SQL_USER" --password="$SQL_PASS" --port="$SQL_PORT" --default-character-set=utf8 --all-databases > "$sql_path"; then
    gzip "$sql_path"
    chown root "$sql_gz_path" 2>/dev/null || true
    log "SQL backup completed: $sql_gz_path"
    GLOBAL_DB_FILE="$sql_gz"
  else
    msg="mysqldump failed"
    log "$msg"
    notify_mail "Error with mysqldump command" "$msg"
    return 1
  fi
}

# Build tar options: excludes file + GNU warning suppression if supported
prepare_tar_opts() {
  EXCLUDE_FILE="$(mktemp_file)"
  # Avoid archiving the backup target itself
  echo "$BACKUP_DIR" >> "$EXCLUDE_FILE"
  if [ -n "$WWW_EXCLUDES" ]; then
    echo "$WWW_EXCLUDES" | while IFS= read -r pat; do
      [ -n "$pat" ] && echo "$pat" >> "$EXCLUDE_FILE"
    done
  fi
  TAR_WARN_OPT=""
  if is_gnu_tar; then TAR_WARN_OPT="--warning=no-file-changed"; fi
  printf "%s|%s" "$EXCLUDE_FILE" "$TAR_WARN_OPT"
}

# Choose compressor
pick_compressor() {
  if command -v pigz >/dev/null 2>&1; then
    printf "pigz -c"  # parallel gzip if present
  else
    printf "gzip -c"
  fi
}

do_www_backup() {
  [ "$SKIP_WWW" = "true" ] && { log "WWW backup skipped by flag"; return 0; }
  [ "$ENABLE_WWW" = "true" ] || { log "WWW backup disabled by config"; return 0; }

  now="$(date +'%Y_%m_%d_%H_%M')"
  tar_gz="www_backup_${now}.tar.gz"
  out_path="$BACKUP_DIR/$tar_gz"
  partial="$out_path.partial"
  track_partial "$partial"

  log "WWW backup starting"
  preflight_free_space

  res="$(prepare_tar_opts)"
  EXCLUDE_FILE="$(printf "%s" "$res" | cut -d'|' -f1)"
  TAR_WARN_OPT="$(printf "%s" "$res" | cut -d'|' -f2)"
  COMPRESSOR="$(pick_compressor)"

  # Build include list
  INCLUDED=""
  for d in $WWW_DIRS; do
    [ -d "$d" ] || { msg="Directory missing: $d"; log "$msg"; notify_mail "Error during WWW backup" "$msg"; return 1; }
    INCLUDED="$INCLUDED $d"
  done

  if [ "$DRY_RUN" = "true" ]; then
    log "[dry-run] tar -c -X $EXCLUDE_FILE $TAR_WARN_OPT -- $INCLUDED | $COMPRESSOR > $partial && mv $partial $out_path"
    return 0
  fi

  # Stream tar → gzip into a partial file, then atomically move
  # shellcheck disable=SC2086
  if tar $TAR_WARN_OPT -c -X "$EXCLUDE_FILE" $INCLUDED | sh -c "$COMPRESSOR > \"$partial\""; then
    mv "$partial" "$out_path"
    log "WWW backup completed: $out_path"
  else
    msg="Tar/gzip failed during WWW backup"
    log "$msg"
    notify_mail "Error during WWW backup" "$msg"
    return 1
  fi
}

check_db_backup_exists() {
  [ -n "$GLOBAL_DB_FILE" ] || { log "No DB file to check (skipped or failed)"; return 0; }
  path="$BACKUP_DIR/$GLOBAL_DB_FILE"
  if [ -s "$path" ]; then
    log "DB backup exists: $GLOBAL_DB_FILE"
  else
    msg="DB backup missing or empty: $GLOBAL_DB_FILE"
    log "$msg"
    notify_mail "Error with DB backup task" "$msg"
    return 1
  fi
}

self_test() {
  log "Running self-test"
  safe_mkdir "$BACKUP_DIR"
  safe_mkdir "$LOG_DIR"
  rotate_logs_if_needed
  tmpd="$(mktemp -d)"
  echo "hello" > "$tmpd/file.txt"
  out="$BACKUP_DIR/selftest.tar.gz"
  part="$out.partial"; track_partial "$part"
  if [ "$DRY_RUN" = "true" ]; then
    log "[dry-run] tar -c $tmpd | gzip -c > $part && mv $part $out"
  else
    if tar -c "$tmpd" | gzip -c > "$part"; then mv "$part" "$out"; else die "self-test stream failed"; fi
  fi
  rm -rf "$tmpd"
  log "Self-test complete"
}

# ------------------------------- Run -----------------------------------------
apply_retention "$RETENTION_DAYS"

if [ "$SELF_TEST" = "true" ]; then
  self_test
  log "Done (self-test)."; CLEAN_EXIT=1; exit 0
fi

do_sql_backup
check_db_backup_exists
do_www_backup

log "All tasks complete."
CLEAN_EXIT=1
exit 0
