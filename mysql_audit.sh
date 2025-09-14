#!/usr/bin/env bash
set -euo pipefail

# MySQL / MariaDB Security Audit Helper
# Works on Ubuntu + mysql client. Supports MySQL 5.7/8.0 and MariaDB 10.x.
# Generates human-readable and CSV-ish outputs under ./mysql_audit_YYYYmmdd_HHMMSS

VERSION="1.2"

# ---------- colors ----------
bold() { printf "\033[1m%s\033[0m\n" "$*"; }
info() { printf "\033[36m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\033[33m[WARN]\033[0m %s\n" "$*"; }
err()  { printf "\033[31m[ERR ]\033[0m %s\n" "$*" >&2; }

# ---------- prereqs ----------
ensure_mysql_client() {
  if ! command -v mysql >/dev/null 2>&1; then
    warn "mysql client not found. Installing mysql-client (sudo required)."
    sudo apt-get update -y && sudo apt-get install -y mysql-client || {
      err "Failed to install mysql-client. Install it manually and re-run."
      exit 1
    }
  fi
}

# ---------- connection handling ----------
CNF_FILE=""
CLEANUP_FILES=()

make_defaults_file() {
  CNF_FILE="$(mktemp)"
  CLEANUP_FILES+=("$CNF_FILE")
  cat >"$CNF_FILE" <<EOF
[client]
user=$1
password=$2
host=$3
port=$4
ssl-mode=PREFERRED
EOF
}

probe_version() {
  mysql ${1+"$1"} -N -e "SELECT @@version, @@version_comment;" 2>/dev/null | head -n1
}

is_mysql8() {
  local ver="$1"
  [[ "$ver" =~ ^8\. ]] && return 0 || return 1
}

is_mariadb() {
  local vc="$1"
  [[ "$vc" =~ -MariaDB ]] && return 0 || return 1
}

# Default connection options (prefer socket as root if available)
HOST="localhost"
PORT="3306"
USER="root"
PASS=""
USE_SOCKET=0

detect_socket_root() {
  # Try socket auth as root first (no password)
  if mysql -u root -S /var/run/mysqld/mysqld.sock -N -e "SELECT 1" >/dev/null 2>&1; then
    USE_SOCKET=1
    info "Using socket authentication as root."
  fi
}

prompt_connection() {
  bold "Connection Setup"
  echo "We'll try socket auth first (root via /var/run/mysqld/mysqld.sock)."
  detect_socket_root
  if (( USE_SOCKET == 0 )); then
    echo
    read -r -p "MySQL host [${HOST}]: " in; HOST="${in:-$HOST}"
    read -r -p "MySQL port [${PORT}]: " in; PORT="${in:-$PORT}"
    read -r -p "MySQL admin user [${USER}]: " in; USER="${in:-$USER}"
    read -r -s -p "MySQL password for ${USER}: " PASS; echo
    make_defaults_file "$USER" "$PASS" "$HOST" "$PORT"
  fi

  # Test connection and capture version
  local VER_LINE=""
  if (( USE_SOCKET == 1 )); then
    VER_LINE="$(mysql -u root -S /var/run/mysqld/mysqld.sock -N -e "SELECT @@version, @@version_comment;")" || {
      err "Socket connection failed unexpectedly."
      exit 1
    }
  else
    VER_LINE="$(mysql --defaults-extra-file="$CNF_FILE" -N -e "SELECT @@version, @@version_comment;")" || {
      err "TCP connection failed. Check credentials/host/port."
      exit 1
    }
  fi

  DB_VERSION="$(echo "$VER_LINE" | awk '{print $1}')"
  DB_VCOMMENT="$(echo "$VER_LINE" | cut -d' ' -f2- || true)"
  info "Connected. Server version: ${DB_VERSION} ${DB_VCOMMENT}"
}

MYSQL() {
  if (( USE_SOCKET == 1 )); then
    mysql -u root -S /var/run/mysqld/mysqld.sock "$@"
  else
    mysql --defaults-extra-file="$CNF_FILE" "$@"
  fi
}

# ---------- output setup ----------
TS="$(date +%Y%m%d_%H%M%S)"
OUTDIR="mysql_audit_${TS}"
mkdir -p "$OUTDIR"

tee_out() {
  local name="$1"; shift
  "$@" | tee "${OUTDIR}/${name}.txt"
}

sql2file() {
  local name="$1"; shift
  MYSQL -t -N -e "$*" | tee "${OUTDIR}/${name}.txt"
}

sql_raw2file() {
  local name="$1"; shift
  MYSQL -N -e "$*" | tee "${OUTDIR}/${name}.tsv"
}

# ---------- audit steps ----------
audit_users_inventory() {
  bold "1) User inventory"
  info "Listing users, hosts, auth plugins, lock/expiration status, password_last_changed."
  local q="
SELECT
  user,
  host,
  plugin,
  account_locked,
  password_expired,
  password_lifetime,
  password_last_changed
FROM mysql.user
ORDER BY user, host;
"
  sql2file "01_users_inventory" "$q"
}

audit_wildcards_and_empty_pw() {
  bold "2) Wildcards & empty/weak auth quick check"
  info "Flagging users with '%' hosts, blank usernames, or nullable auth_string."

  # ✅ Fixed query string – works inside bash without syntax error
  local q1="
SELECT user, host, plugin
FROM mysql.user
WHERE host LIKE '%\\%%'
   OR user=''
ORDER BY user, host;
"
  sql2file "02a_users_with_wildcard_or_blank" "$q1"

  # MySQL 8 stores hash in authentication_string; MariaDB uses Password or authentication_string depending on version.
  if is_mariadb "$DB_VCOMMENT"; then
    local q2="
SELECT user, host, IF(Password='' OR Password IS NULL,'EMPTY_OR_NULL','SET') AS pw_status
FROM mysql.user
WHERE Password='' OR Password IS NULL
ORDER BY user, host;
"
    sql2file "02b_empty_passwords" "$q2"
  else
    local q2="
SELECT user, host, IF(authentication_string IS NULL OR authentication_string='','EMPTY_OR_NULL','SET') AS pw_status
FROM mysql.user
WHERE authentication_string IS NULL OR authentication_string=''
ORDER BY user, host;
"
    sql2file "02b_empty_passwords" "$q2"
  fi
}


audit_global_privs() {
  bold "3) Global privileges"
  info "Enumerating global (mysql.user) privilege columns where 'Y'. Look for powerful perms (FILE, SUPER/ADMINs, SHUTDOWN, REPLICATION, GRANT)."
  local cols
  cols=$(MYSQL -N -e "SHOW COLUMNS FROM mysql.user;" | awk '{print $1}' | grep -E '_(priv|Priv)$' || true)
  if [[ -z "$cols" ]]; then
    warn "Could not identify global privilege columns (schema mismatch?). Dumping GRANTS instead."
    sql2file "03_global_privs_grants_fallback" "SHOW GRANTS FOR CURRENT_USER();"
    return
  fi
  local sel="user,host"
  for c in $cols; do sel="${sel}, ${c}"; done
  local q="SELECT ${sel} FROM mysql.user ORDER BY user,host;"
  sql2file "03_global_priv_columns" "$q"

  # Specific focus: GRANT OPTION & FILE & administrative
  local q2="
SELECT user, host,
       Grant_priv,
       File_priv,
       Create_user_priv,
       Repl_slave_priv,
       Repl_client_priv
FROM mysql.user
ORDER BY user, host;
"
  sql2file "03b_sensitive_global_flags" "$q2"
}

audit_db_table_column_privs() {
  bold "4) Database/Table/Column privileges"
  info "Per-DB privileges (mysql.db), per-table (mysql.tables_priv), per-column (mysql.columns_priv / information_schema.COLUMN_PRIVILEGES)."
  sql2file "04a_db_privs" "SELECT User, Host, Db, Select_priv, Insert_priv, Update_priv, Delete_priv, Create_priv, Drop_priv, Grant_priv, References_priv, Index_priv, Alter_priv FROM mysql.db ORDER BY User,Host,Db;"
  sql2file "04b_table_privs" "SELECT User, Host, Db, Table_name, Table_priv, Grantor FROM mysql.tables_priv ORDER BY User,Host,Db,Table_name;"
  # Column privs vary; try information_schema first
  sql2file "04c_column_privs" "SELECT GRANTEE, TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, PRIVILEGE_TYPE FROM information_schema.COLUMN_PRIVILEGES ORDER BY GRANTEE, TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME;"
}

audit_roles() {
  bold "5) Roles & default roles (MySQL 8+)"
  if is_mariadb "$DB_VCOMMENT"; then
    warn "MariaDB role schema differs. Dumping SHOW GRANTS for users as a fallback."
  fi

  # role_edges table exists on MySQL 8+; MariaDB uses mysql.roles_mapping
  if is_mysql8 "$DB_VERSION"; then
    sql2file "05a_roles_edges" "SELECT * FROM mysql.role_edges ORDER BY FROM_HOST, FROM_USER, TO_HOST, TO_USER;"
    sql2file "05b_default_roles" "SELECT * FROM mysql.default_roles ORDER BY HOST, USER;"
  else
    # Try MariaDB roles mapping
    sql2file "05a_roles_mapping_mariadb" "SELECT * FROM mysql.roles_mapping ORDER BY Host, User, Role, Admin_option;"
  fi
}

audit_proxy_users() {
  bold "6) PROXY privileges"
  info "Checking mysql.proxies_priv (user impersonation)."
  sql2file "06_proxy_privs" "SELECT * FROM mysql.proxies_priv ORDER BY Host, User;"
}

audit_grants_dump() {
  bold "7) Full GRANTS dump per account"
  info "Collecting SHOW GRANTS for each account for manual review."
  local accounts
  accounts=$(MYSQL -N -e "SELECT CONCAT(\"'\", user, \"'@'\", host, \"'\") FROM mysql.user ORDER BY user, host;")
  local f="${OUTDIR}/07_grants_dump.sql"
  : > "$f"
  while IFS= read -r acct; do
    echo "-- ${acct}" >> "$f"
    MYSQL -N -e "SHOW GRANTS FOR ${acct};" >> "$f" 2>/dev/null || {
      echo "-- (could not show grants for ${acct})" >> "$f"
    }
    echo >> "$f"
  done
  info "Wrote ${f}"
}

audit_security_variables() {
  bold "8) Security-relevant variables"
  info "TLS, local_infile, validate_password plugin/policy, general/slow logs, super_read_only, require_secure_transport, log_bin."
  local q="
SELECT
  @@global.require_secure_transport     AS require_secure_transport,
  @@global.have_ssl                     AS have_ssl,
  @@global.tls_version                  AS tls_version,
  @@global.ssl_ca                       AS ssl_ca,
  @@global.ssl_cipher                   AS ssl_cipher,
  @@global.local_infile                 AS local_infile,
  @@global.log_bin                      AS log_bin,
  @@global.general_log                  AS general_log,
  @@global.slow_query_log               AS slow_query_log,
  @@global.long_query_time              AS long_query_time,
  @@global.log_error_verbosity          AS log_error_verbosity,
  @@global.sql_mode                     AS sql_mode,
  @@global.super_read_only              AS super_read_only
;"
  sql2file "08_security_variables" "$q"

  # Validate password plugin/policy (names differ across variants)
  sql2file "08b_validate_password" "
SELECT PLUGIN_NAME, PLUGIN_STATUS FROM information_schema.PLUGINS WHERE PLUGIN_NAME LIKE 'validate_password%';
"

  sql2file "08c_validate_password_params" "
SELECT
  @@global.validate_password.policy     AS policy,
  @@global.validate_password.length     AS length,
  @@global.validate_password.mixed_case_count AS mixed_case_count,
  @@global.validate_password.number_count AS number_count,
  @@global.validate_password.special_char_count AS special_char_count
;"
}

audit_activity_hints() {
  bold "9) Activity hints (optional)"
  info "Listing accounts seen by performance_schema (may be empty if P_S disabled)."
  sql2file "09_accounts_activity_hint" "
SELECT USER, HOST, SUM(TOTAL_CONNECTIONS) AS total_conns
FROM performance_schema.accounts
GROUP BY USER, HOST
ORDER BY total_conns DESC;
"
}

quick_findings() {
  bold "10) Quick Findings (heuristics)"
  {
    echo "== Users with wildcard hosts =="
    MYSQL -N -e "SELECT user, host FROM mysql.user WHERE host LIKE '%\\%%' ESCAPE '\\' ORDER BY user,host;"

    echo
    echo "== Users with GRANT OPTION globally =="
    MYSQL -N -e "SELECT user, host FROM mysql.user WHERE Grant_priv='Y' ORDER BY user,host;"

    echo
    echo "== Users with FILE privilege globally =="
    MYSQL -N -e "SELECT user, host FROM mysql.user WHERE File_priv='Y' ORDER BY user,host;"

    echo
    echo "== Accounts locked or expired =="
    MYSQL -N -e "SELECT user, host, account_locked, password_expired FROM mysql.user WHERE account_locked='Y' OR password_expired='Y' ORDER BY user,host;"

    echo
    echo "== DB-level GRANT OPTION present =="
    MYSQL -N -e "SELECT User, Host, Db FROM mysql.db WHERE Grant_priv='Y' ORDER BY User,Host,Db;"
  } | tee "${OUTDIR}/10_quick_findings.txt"
  info "Review ${OUTDIR}/10_quick_findings.txt"
}

run_all() {
  audit_users_inventory
  audit_wildcards_and_empty_pw
  audit_global_privs
  audit_db_table_column_privs
  audit_roles
  audit_proxy_users
  audit_grants_dump
  audit_security_variables
  audit_activity_hints
  quick_findings
  bold "All audit steps completed. Outputs in ${OUTDIR}/"
}

menu() {
  while true; do
    echo
    bold "MySQL Security Audit Menu (v${VERSION})"
    cat <<MENU
1) User inventory
2) Wildcards & empty passwords
3) Global privileges
4) DB/Table/Column privileges
5) Roles (and default roles)
6) Proxy users
7) Full GRANTS dump (per account)
8) Security variables (TLS, local_infile, logs, password policy)
9) Activity hints (performance_schema)
10) Quick findings rollup
A) Run ALL
Q) Quit
MENU
    read -r -p "Choose: " choice
    case "${choice^^}" in
      1) audit_users_inventory ;;
      2) audit_wildcards_and_empty_pw ;;
      3) audit_global_privs ;;
      4) audit_db_table_column_privs ;;
      5) audit_roles ;;
      6) audit_proxy_users ;;
      7) audit_grants_dump ;;
      8) audit_security_variables ;;
      9) audit_activity_hints ;;
      10) quick_findings ;;
      A) run_all ;;
      Q) break ;;
      *) warn "Invalid choice" ;;
    esac
  done
}

# ---------- main ----------
trap '[[ ${#CLEANUP_FILES[@]} -gt 0 ]] && rm -f "${CLEANUP_FILES[@]}" || true' EXIT

ensure_mysql_client
prompt_connection
menu

bold "Done. Reports in: ${OUTDIR}"
echo "Next actions are suggested below."
cat <<'NEXT'
- Lock or remove unused accounts; tighten '%' hosts to specific CIDRs/hosts.
- Enforce strong auth plugin and password policy; expire/reset stale passwords.
- Remove GRANT OPTION from non-admins; minimize FILE/PROCESS/SHUTDOWN/RELOAD use.
- Require TLS (require_secure_transport=ON); disable local_infile unless justified.
- Enable slow log with sane long_query_time; centralize logs; review general_log usage.
- Use roles to bundle privileges; audit proxies; avoid blank usernames.
- Put this script in CI/CD or cron for periodic baselines (diff the output directories).

Tip: Create /root/.my.cnf with [client] + socket or strong creds to avoid typing passwords.
NEXT
