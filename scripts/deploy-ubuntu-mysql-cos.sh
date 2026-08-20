#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# Quick validation deployment for Ubuntu:
#   - installs and starts local MySQL;
#   - creates the Drive9 metadata database/user and MySQL provisioner admin user;
#   - installs Go from the Ubuntu apt repository;
#   - builds drive9-server from this checkout;
#   - starts drive9-server with Tencent COS through the S3-compatible API;
#   - optionally creates one initial tenant and prints its API key.
#
# Secrets are intentionally read from the environment and are not written to a
# configuration file. Keep DRIVE9_MASTER_KEY and DRIVE9_TOKEN_SIGNING_KEY stable
# if this script is run again against an existing metadata database.
#
# Minimal example:
#   export DRIVE9_S3_BUCKET='bucket-appid'
#   export DRIVE9_S3_REGION='ap-guangzhou'
#   export DRIVE9_S3_ACCESS_KEY_ID='...'
#   export DRIVE9_S3_SECRET_ACCESS_KEY='...'
#   export DRIVE9_META_DB_PASSWORD='test-meta-password'
#   export DRIVE9_MYSQL_ADMIN_PASSWORD='test-admin-password'
#   export DRIVE9_MASTER_KEY="$(openssl rand -hex 32)"
#   export DRIVE9_TOKEN_SIGNING_KEY="$(openssl rand -hex 32)"
#   bash scripts/deploy-ubuntu-mysql-cos.sh
#
# Optional overrides are documented in the configuration block below.

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

log() {
  printf '[drive9-deploy] %s\n' "$*"
}

warn() {
  printf '[drive9-deploy] warning: %s\n' "$*" >&2
}

fail() {
  printf '[drive9-deploy] error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

require_env() {
  local name=$1
  [[ -n "${!name:-}" ]] || fail "environment variable ${name} is required"
}

validate_identifier() {
  local name=$1
  local value=$2
  local max_length=$3
  [[ "$value" =~ ^[a-z][a-z0-9_]*$ ]] || fail "${name} must contain only lowercase letters, digits, and underscores, and start with a letter"
  (( ${#value} <= max_length )) || fail "${name} is too long; maximum length is ${max_length}"
}

validate_hex_key() {
  local name=$1
  local value=$2
  [[ "$value" =~ ^[0-9A-Fa-f]{64}$ ]] || fail "${name} must be exactly 64 hexadecimal characters (32 bytes)"
}

validate_account_host() {
  local name=$1
  local value=$2
  [[ "$value" =~ ^[A-Za-z0-9._:%-]+$ ]] || fail "${name} contains unsupported MySQL account-host characters"
}

# Quote a value for a MySQL string literal. Identifiers are separately validated
# and never receive untrusted SQL fragments.
sql_quote() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\'/\'\'}
  printf "'%s'" "$value"
}

sql_identifier() {
  printf '`%s`' "$1"
}

if [[ ! -r /etc/os-release ]]; then
  fail 'cannot identify operating system; Ubuntu is required'
fi
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == ubuntu ]] || fail "Ubuntu is required; detected ${ID:-unknown}"

if (( EUID == 0 )); then
  SUDO=()
else
  require_command sudo
  sudo -v
  SUDO=(sudo)
fi

as_root() {
  if (( EUID == 0 )); then
    "$@"
  else
    sudo "$@"
  fi
}

# Configuration. Set these through the environment before invoking the script.
GO_BIN="${GO_BIN:-}"

MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_CONTROL_ACCOUNT_HOST="${MYSQL_CONTROL_ACCOUNT_HOST:-127.0.0.1}"

DRIVE9_META_DB_NAME="${DRIVE9_META_DB_NAME:-drive9_meta}"
DRIVE9_META_DB_USER="${DRIVE9_META_DB_USER:-drive9_meta}"
DRIVE9_MYSQL_ADMIN_USER="${DRIVE9_MYSQL_ADMIN_USER:-drive9_admin}"
DRIVE9_MYSQL_DATABASE_PREFIX="${DRIVE9_MYSQL_DATABASE_PREFIX:-drive9_t_}"
DRIVE9_MYSQL_USER_PREFIX="${DRIVE9_MYSQL_USER_PREFIX:-drive9_u_}"
DRIVE9_MYSQL_ACCOUNT_HOST="${DRIVE9_MYSQL_ACCOUNT_HOST:-127.0.0.1}"
DRIVE9_MYSQL_TLS="${DRIVE9_MYSQL_TLS:-false}"

DRIVE9_PORT="${DRIVE9_PORT:-9009}"
DRIVE9_LISTEN_ADDR="${DRIVE9_LISTEN_ADDR:-0.0.0.0:${DRIVE9_PORT}}"
DRIVE9_PUBLIC_URL="${DRIVE9_PUBLIC_URL:-http://127.0.0.1:${DRIVE9_PORT}}"
DRIVE9_HEALTH_URL="${DRIVE9_HEALTH_URL:-http://127.0.0.1:${DRIVE9_PORT}}"
DRIVE9_RUN_DIR="${DRIVE9_RUN_DIR:-${ROOT_DIR}/.drive9-run}"
DRIVE9_LOG_FILE="${DRIVE9_LOG_FILE:-${DRIVE9_RUN_DIR}/drive9-server.log}"
DRIVE9_PID_FILE="${DRIVE9_PID_FILE:-${DRIVE9_RUN_DIR}/drive9-server.pid}"
DRIVE9_BOOTSTRAP_TENANT="${DRIVE9_BOOTSTRAP_TENANT:-true}"
DRIVE9_BOOTSTRAP_TIMEOUT_SECONDS="${DRIVE9_BOOTSTRAP_TIMEOUT_SECONDS:-90}"

# Tencent COS S3-compatible settings. The bucket name normally includes the
# Tencent APPID, for example bucket-appid. Override the endpoint for a private
# or custom COS endpoint when necessary.
require_env DRIVE9_S3_BUCKET
require_env DRIVE9_S3_REGION
require_env DRIVE9_S3_ACCESS_KEY_ID
require_env DRIVE9_S3_SECRET_ACCESS_KEY
DRIVE9_S3_ENDPOINT="${DRIVE9_S3_ENDPOINT:-https://cos.${DRIVE9_S3_REGION}.myqcloud.com}"
DRIVE9_S3_PREFIX="${DRIVE9_S3_PREFIX:-drive9-quick-validation}"
DRIVE9_S3_FORCE_PATH_STYLE="${DRIVE9_S3_FORCE_PATH_STYLE:-false}"
DRIVE9_S3_ENCRYPTION_MODE="${DRIVE9_S3_ENCRYPTION_MODE:-none}"
DRIVE9_S3_BUCKET_KEY_ENABLED="${DRIVE9_S3_BUCKET_KEY_ENABLED:-true}"

require_env DRIVE9_META_DB_PASSWORD
require_env DRIVE9_MYSQL_ADMIN_PASSWORD
require_env DRIVE9_MASTER_KEY
require_env DRIVE9_TOKEN_SIGNING_KEY

validate_identifier DRIVE9_META_DB_NAME "$DRIVE9_META_DB_NAME" 64
validate_identifier DRIVE9_META_DB_USER "$DRIVE9_META_DB_USER" 32
validate_identifier DRIVE9_MYSQL_ADMIN_USER "$DRIVE9_MYSQL_ADMIN_USER" 32
validate_hex_key DRIVE9_MASTER_KEY "$DRIVE9_MASTER_KEY"
validate_hex_key DRIVE9_TOKEN_SIGNING_KEY "$DRIVE9_TOKEN_SIGNING_KEY"
validate_account_host MYSQL_CONTROL_ACCOUNT_HOST "$MYSQL_CONTROL_ACCOUNT_HOST"
validate_account_host DRIVE9_MYSQL_ACCOUNT_HOST "$DRIVE9_MYSQL_ACCOUNT_HOST"
[[ "$MYSQL_PORT" =~ ^[0-9]+$ ]] && (( MYSQL_PORT >= 1 && MYSQL_PORT <= 65535 )) || fail "MYSQL_PORT must be between 1 and 65535"
[[ "$DRIVE9_PORT" =~ ^[0-9]+$ ]] && (( DRIVE9_PORT >= 1 && DRIVE9_PORT <= 65535 )) || fail "DRIVE9_PORT must be between 1 and 65535"
[[ "$DRIVE9_BOOTSTRAP_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || fail "DRIVE9_BOOTSTRAP_TIMEOUT_SECONDS must be a positive integer"

readonly SERVER_BIN="${ROOT_DIR}/bin/drive9-server"

install_system_packages() {
  log 'installing Ubuntu dependencies'
  as_root apt-get update
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential ca-certificates curl git golang-go jq mysql-client mysql-server openssl
}

start_mysql() {
  log 'starting local MySQL'
  if ! mysql_root_sql -e 'SELECT 1' >/dev/null 2>&1; then
    if ! as_root service mysql start >/dev/null 2>&1; then
      as_root systemctl start mysql
    fi
  fi

  local attempt
  for attempt in $(seq 1 60); do
    if mysql_root_sql -e 'SELECT 1' >/dev/null 2>&1; then
      log 'local MySQL is ready'
      return
    fi
    sleep 1
  done
  fail 'local MySQL did not become ready; inspect the MySQL service logs'
}

mysql_root_sql() {
  as_root mysql --protocol=socket --user=root --batch --skip-column-names --raw "$@"
}

initialize_mysql() {
  local meta_db_ident meta_account meta_password_sql
  local admin_account admin_password_sql

  meta_db_ident="$(sql_identifier "$DRIVE9_META_DB_NAME")"
  meta_account="$(sql_quote "$DRIVE9_META_DB_USER")@$(sql_quote "$MYSQL_CONTROL_ACCOUNT_HOST")"
  meta_password_sql="$(sql_quote "$DRIVE9_META_DB_PASSWORD")"
  admin_account="$(sql_quote "$DRIVE9_MYSQL_ADMIN_USER")@$(sql_quote "$MYSQL_CONTROL_ACCOUNT_HOST")"
  admin_password_sql="$(sql_quote "$DRIVE9_MYSQL_ADMIN_PASSWORD")"

  log "initializing MySQL database ${DRIVE9_META_DB_NAME} and Drive9 control users"
  mysql_root_sql <<SQL
CREATE DATABASE IF NOT EXISTS ${meta_db_ident} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS ${meta_account} IDENTIFIED BY ${meta_password_sql};
ALTER USER ${meta_account} IDENTIFIED BY ${meta_password_sql};
GRANT ALL PRIVILEGES ON ${meta_db_ident}.* TO ${meta_account};
CREATE USER IF NOT EXISTS ${admin_account} IDENTIFIED BY ${admin_password_sql};
ALTER USER ${admin_account} IDENTIFIED BY ${admin_password_sql};
GRANT ALL PRIVILEGES ON *.* TO ${admin_account} WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
}

install_go() {
  require_command go
  GO_BIN="$(command -v go)"
  log "using Go installed by apt: $(${GO_BIN} version)"
}

build_server() {
  log 'building drive9-server from source'
  mkdir -p -- "${ROOT_DIR}/bin"
  (
    cd -- "$ROOT_DIR"
    CGO_ENABLED=0 "$GO_BIN" build -o "$SERVER_BIN" ./cmd/drive9-server
  )
}

configure_environment() {
  DRIVE9_META_DSN="${DRIVE9_META_DSN:-${DRIVE9_META_DB_USER}:${DRIVE9_META_DB_PASSWORD}@tcp(${MYSQL_HOST}:${MYSQL_PORT})/${DRIVE9_META_DB_NAME}?parseTime=true&loc=UTC}"
  DRIVE9_MYSQL_ADMIN_DSN="${DRIVE9_MYSQL_ADMIN_DSN:-${DRIVE9_MYSQL_ADMIN_USER}:${DRIVE9_MYSQL_ADMIN_PASSWORD}@tcp(${MYSQL_HOST}:${MYSQL_PORT})/mysql?parseTime=true&loc=UTC}"

  export DRIVE9_LISTEN_ADDR DRIVE9_PUBLIC_URL DRIVE9_META_DSN
  export DRIVE9_TENANT_PROVIDER=mysql
  export DRIVE9_MASTER_KEY DRIVE9_TOKEN_SIGNING_KEY
  export DRIVE9_MYSQL_ADMIN_DSN DRIVE9_MYSQL_DATABASE_PREFIX DRIVE9_MYSQL_USER_PREFIX
  export DRIVE9_MYSQL_ACCOUNT_HOST DRIVE9_MYSQL_TLS
  export DRIVE9_S3_BUCKET DRIVE9_S3_REGION DRIVE9_S3_ENDPOINT DRIVE9_S3_PREFIX
  export DRIVE9_S3_FORCE_PATH_STYLE DRIVE9_S3_ACCESS_KEY_ID DRIVE9_S3_SECRET_ACCESS_KEY
  export DRIVE9_S3_ENCRYPTION_MODE DRIVE9_S3_BUCKET_KEY_ENABLED
  export DRIVE9_LEADER_DISABLED=true
  export DRIVE9_LOG_LEVEL="${DRIVE9_LOG_LEVEL:-info}"
}

server_is_running() {
  local pid=$1
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

start_server() {
  local existing_pid server_pid
  mkdir -p -- "$DRIVE9_RUN_DIR"
  chmod 700 -- "$DRIVE9_RUN_DIR"

  if [[ -f "$DRIVE9_PID_FILE" ]]; then
    existing_pid="$(cat -- "$DRIVE9_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$existing_pid" ]] && server_is_running "$existing_pid"; then
      fail "drive9-server is already running with PID ${existing_pid}; stop it before redeploying"
    fi
    rm -f -- "$DRIVE9_PID_FILE"
  fi

  log "starting drive9-server with nohup on ${DRIVE9_LISTEN_ADDR}"
  cd -- "$ROOT_DIR"
  nohup "$SERVER_BIN" >"$DRIVE9_LOG_FILE" 2>&1 < /dev/null &
  server_pid=$!
  printf '%s\n' "$server_pid" >"$DRIVE9_PID_FILE"

  local attempt
  for attempt in $(seq 1 90); do
    if curl --fail --silent --show-error --max-time 3 "${DRIVE9_HEALTH_URL%/}/healthz" >/dev/null 2>&1; then
      log "drive9-server is ready; PID=${server_pid}"
      return
    fi
    if ! server_is_running "$server_pid"; then
      warn 'drive9-server exited during startup'
      tail -n 80 -- "$DRIVE9_LOG_FILE" >&2 || true
      fail 'drive9-server failed to start'
    fi
    sleep 1
  done
  tail -n 80 -- "$DRIVE9_LOG_FILE" >&2 || true
  fail "drive9-server did not become ready; inspect ${DRIVE9_LOG_FILE}"
}

bootstrap_tenant() {
  local response tenant_id api_key status status_response deadline now error_message
  if [[ "${DRIVE9_BOOTSTRAP_TENANT,,}" != true ]]; then
    return
  fi

  log 'creating an initial MySQL tenant for quick validation'
  response="$(curl --fail --silent --show-error --max-time 15 \
    -X POST "${DRIVE9_HEALTH_URL%/}/v1/provision" \
    -H 'Content-Type: application/json' \
    --data '{}')" || {
      tail -n 80 -- "$DRIVE9_LOG_FILE" >&2 || true
      fail 'initial tenant provisioning request failed'
    }

  tenant_id="$(jq -r '.tenant_id // empty' <<<"$response")"
  api_key="$(jq -r '.api_key // empty' <<<"$response")"
  status="$(jq -r '.status // empty' <<<"$response")"
  if [[ -z "$tenant_id" || -z "$api_key" ]]; then
    error_message="$(jq -r '.error // "unexpected provisioning response"' <<<"$response" 2>/dev/null || printf '%s' 'unexpected provisioning response')"
    fail "initial tenant provisioning failed: ${error_message}"
  fi

  deadline=$(( $(date +%s) + DRIVE9_BOOTSTRAP_TIMEOUT_SECONDS ))
  while :; do
    status_response="$(curl --fail --silent --show-error --max-time 5 \
      -H "Authorization: Bearer ${api_key}" \
      "${DRIVE9_HEALTH_URL%/}/v1/status" 2>/dev/null || true)"
    status="$(jq -r '.status // empty' <<<"$status_response" 2>/dev/null || true)"
    case "$status" in
      active) break ;;
      failed)
        error_message="$(jq -r '.error // .message // "tenant provisioning failed"' <<<"$status_response" 2>/dev/null || printf '%s' 'tenant provisioning failed')"
        fail "tenant ${tenant_id} entered failed state: ${error_message}"
        ;;
    esac
    now=$(date +%s)
    (( now < deadline )) || fail "tenant ${tenant_id} did not become active within ${DRIVE9_BOOTSTRAP_TIMEOUT_SECONDS}s"
    sleep 2
  done

  printf '\nDrive9 quick validation deployment is ready.\n'
  printf '  server:   %s\n' "${DRIVE9_PUBLIC_URL%/}"
  printf '  health:   %s/healthz\n' "${DRIVE9_HEALTH_URL%/}"
  printf '  tenant:   %s\n' "$tenant_id"
  printf '  api key:  %s\n' "$api_key"
  printf '  log:      %s\n' "$DRIVE9_LOG_FILE"
  printf '  pid file: %s\n' "$DRIVE9_PID_FILE"
  printf '\nExample request:\n'
  printf '  curl -H "Authorization: Bearer %s" "%s/v1/fs/?list=1"\n' "$api_key" "${DRIVE9_PUBLIC_URL%/}"
}

main() {
  require_command bash
  install_system_packages
  require_command mysql
  require_command mysqladmin
  require_command curl
  require_command jq
  require_command openssl
  start_mysql
  initialize_mysql
  install_go
  configure_environment
  build_server
  start_server
  bootstrap_tenant
}

main "$@"
