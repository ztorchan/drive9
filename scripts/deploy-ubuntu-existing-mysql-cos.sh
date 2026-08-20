#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# Quick validation deployment for Ubuntu with an existing MySQL instance:
#   - does not install or start mysql-server;
#   - installs the MySQL client, Go, and build dependencies;
#   - checks the configured metadata database and detects whether Drive9's
#     control-plane schema has been initialized;
#   - lets drive9-server perform the authoritative metadata schema migration
#     when the schema is missing or incomplete;
#   - builds drive9-server from this checkout;
#   - starts drive9-server with nohup and Tencent COS;
#   - optionally creates one initial MySQL tenant and prints its API key.
#
# The existing MySQL accounts are never created, altered, or deleted by this
# script. The metadata account must already be able to use its database. The
# MySQL provider admin account must already be able to create tenant databases,
# users, and grants.
#
# Minimal example:
#   export MYSQL_HOST='10.0.0.10'
#   export MYSQL_PORT='3306'
#   export DRIVE9_META_DB_NAME='drive9_meta'
#   export DRIVE9_META_DB_USER='drive9_meta'
#   export DRIVE9_META_DB_PASSWORD='test-meta-password'
#   export DRIVE9_MYSQL_ADMIN_USER='drive9_admin'
#   export DRIVE9_MYSQL_ADMIN_PASSWORD='test-admin-password'
#   export DRIVE9_S3_BUCKET='bucket-appid'
#   export DRIVE9_S3_REGION='ap-guangzhou'
#   export DRIVE9_S3_ACCESS_KEY_ID='...'
#   export DRIVE9_S3_SECRET_ACCESS_KEY='...'
#   export DRIVE9_MASTER_KEY="$(openssl rand -hex 32)"
#   export DRIVE9_TOKEN_SIGNING_KEY="$(openssl rand -hex 32)"
#   bash scripts/deploy-ubuntu-existing-mysql-cos.sh
#
# If the metadata database itself does not exist, the default is to stop and
# ask for it to be created by the database operator. Set
# DRIVE9_CREATE_META_DATABASE=true to let the configured provider admin account
# run CREATE DATABASE IF NOT EXISTS. This still does not create or modify users.
#
# If a password contains characters significant to a Go MySQL DSN, provide the
# complete DRIVE9_META_DSN and DRIVE9_MYSQL_ADMIN_DSN explicitly. The separate
# account variables are still used by the mysql-client preflight checks.

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

is_true() {
  case "${1,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
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

# Quote a value for a MySQL string literal. Identifiers are separately
# validated and never receive untrusted SQL fragments.
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
MYSQL_SSL_MODE="${MYSQL_SSL_MODE:-PREFERRED}"
MYSQL_CONNECT_TIMEOUT_SECONDS="${MYSQL_CONNECT_TIMEOUT_SECONDS:-10}"

DRIVE9_META_DB_NAME="${DRIVE9_META_DB_NAME:-drive9_meta}"
DRIVE9_META_DB_USER="${DRIVE9_META_DB_USER:-drive9_meta}"
DRIVE9_MYSQL_ADMIN_USER="${DRIVE9_MYSQL_ADMIN_USER:-drive9_admin}"
DRIVE9_MYSQL_DATABASE_PREFIX="${DRIVE9_MYSQL_DATABASE_PREFIX:-drive9_t_}"
DRIVE9_MYSQL_USER_PREFIX="${DRIVE9_MYSQL_USER_PREFIX:-drive9_u_}"
# Use % by default because the application may connect to a remote MySQL host.
# Set this to the application host/IP for a narrower account host.
DRIVE9_MYSQL_ACCOUNT_HOST="${DRIVE9_MYSQL_ACCOUNT_HOST:-%}"
DRIVE9_MYSQL_TLS="${DRIVE9_MYSQL_TLS:-false}"
DRIVE9_CREATE_META_DATABASE="${DRIVE9_CREATE_META_DATABASE:-false}"

DRIVE9_PORT="${DRIVE9_PORT:-9009}"
DRIVE9_LISTEN_ADDR="${DRIVE9_LISTEN_ADDR:-0.0.0.0:${DRIVE9_PORT}}"
DRIVE9_PUBLIC_URL="${DRIVE9_PUBLIC_URL:-http://127.0.0.1:${DRIVE9_PORT}}"
DRIVE9_HEALTH_URL="${DRIVE9_HEALTH_URL:-http://127.0.0.1:${DRIVE9_PORT}}"
DRIVE9_RUN_DIR="${DRIVE9_RUN_DIR:-${ROOT_DIR}/.drive9-run}"
DRIVE9_LOG_FILE="${DRIVE9_LOG_FILE:-${DRIVE9_RUN_DIR}/drive9-server.log}"
DRIVE9_PID_FILE="${DRIVE9_PID_FILE:-${DRIVE9_RUN_DIR}/drive9-server.pid}"
DRIVE9_BOOTSTRAP_TENANT="${DRIVE9_BOOTSTRAP_TENANT:-true}"
DRIVE9_BOOTSTRAP_COS_SMOKE="${DRIVE9_BOOTSTRAP_COS_SMOKE:-true}"
DRIVE9_BOOTSTRAP_TIMEOUT_SECONDS="${DRIVE9_BOOTSTRAP_TIMEOUT_SECONDS:-90}"

# Tencent COS S3-compatible settings. The bucket name normally includes the
# Tencent APPID, for example bucket-appid.
require_env DRIVE9_S3_BUCKET
require_env DRIVE9_S3_REGION
require_env DRIVE9_S3_ACCESS_KEY_ID
require_env DRIVE9_S3_SECRET_ACCESS_KEY
DRIVE9_S3_ENDPOINT="${DRIVE9_S3_ENDPOINT:-https://cos.${DRIVE9_S3_REGION}.myqcloud.com}"
DRIVE9_S3_PREFIX="${DRIVE9_S3_PREFIX:-drive9-quick-validation}"
DRIVE9_S3_FORCE_PATH_STYLE="${DRIVE9_S3_FORCE_PATH_STYLE:-false}"
DRIVE9_S3_ENCRYPTION_MODE="${DRIVE9_S3_ENCRYPTION_MODE:-none}"
DRIVE9_S3_KMS_KEY_ID="${DRIVE9_S3_KMS_KEY_ID:-}"
DRIVE9_S3_BUCKET_KEY_ENABLED="${DRIVE9_S3_BUCKET_KEY_ENABLED:-true}"
DRIVE9_S3_SESSION_TOKEN="${DRIVE9_S3_SESSION_TOKEN:-}"
DRIVE9_S3_ROLE_ARN="${DRIVE9_S3_ROLE_ARN:-}"

require_env DRIVE9_META_DB_PASSWORD
require_env DRIVE9_MYSQL_ADMIN_PASSWORD
require_env DRIVE9_MASTER_KEY
require_env DRIVE9_TOKEN_SIGNING_KEY

validate_identifier DRIVE9_META_DB_NAME "$DRIVE9_META_DB_NAME" 64
validate_identifier DRIVE9_META_DB_USER "$DRIVE9_META_DB_USER" 32
validate_identifier DRIVE9_MYSQL_ADMIN_USER "$DRIVE9_MYSQL_ADMIN_USER" 32
validate_account_host DRIVE9_MYSQL_ACCOUNT_HOST "$DRIVE9_MYSQL_ACCOUNT_HOST"
validate_hex_key DRIVE9_MASTER_KEY "$DRIVE9_MASTER_KEY"
validate_hex_key DRIVE9_TOKEN_SIGNING_KEY "$DRIVE9_TOKEN_SIGNING_KEY"
[[ "$MYSQL_PORT" =~ ^[0-9]+$ ]] && (( MYSQL_PORT >= 1 && MYSQL_PORT <= 65535 )) || fail 'MYSQL_PORT must be between 1 and 65535'
[[ "$MYSQL_CONNECT_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] && (( MYSQL_CONNECT_TIMEOUT_SECONDS >= 1 )) || fail 'MYSQL_CONNECT_TIMEOUT_SECONDS must be a positive integer'
[[ "$DRIVE9_PORT" =~ ^[0-9]+$ ]] && (( DRIVE9_PORT >= 1 && DRIVE9_PORT <= 65535 )) || fail 'DRIVE9_PORT must be between 1 and 65535'
[[ "$DRIVE9_BOOTSTRAP_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || fail 'DRIVE9_BOOTSTRAP_TIMEOUT_SECONDS must be a positive integer'

readonly SERVER_BIN="${ROOT_DIR}/bin/drive9-server"

MYSQL_CLIENT_SSL_ARGS=()
if [[ -n "$MYSQL_SSL_MODE" ]]; then
  MYSQL_CLIENT_SSL_ARGS=("--ssl-mode=${MYSQL_SSL_MODE}")
fi

mysql_run() {
  local user=$1
  local password=$2
  shift 2
  MYSQL_PWD="$password" mysql \
    --protocol=tcp \
    --host="$MYSQL_HOST" \
    --port="$MYSQL_PORT" \
    --user="$user" \
    "${MYSQL_CLIENT_SSL_ARGS[@]}" \
    --connect-timeout="$MYSQL_CONNECT_TIMEOUT_SECONDS" \
    --batch --skip-column-names --raw "$@"
}

mysql_admin_sql() {
  mysql_run "$DRIVE9_MYSQL_ADMIN_USER" "$DRIVE9_MYSQL_ADMIN_PASSWORD" "$@"
}

mysql_meta_sql() {
  mysql_run "$DRIVE9_META_DB_USER" "$DRIVE9_META_DB_PASSWORD" \
    --database="$DRIVE9_META_DB_NAME" "$@"
}

install_system_packages() {
  log 'installing Ubuntu dependencies without mysql-server'
  as_root apt-get update
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential ca-certificates curl git golang-go jq mysql-client openssl
}

check_mysql_connection() {
  log "checking existing MySQL at ${MYSQL_HOST}:${MYSQL_PORT}"
  mysql_admin_sql -e 'SELECT 1' >/dev/null || fail 'cannot connect to the existing MySQL with DRIVE9_MYSQL_ADMIN_USER/PASSWORD'
}

metadata_database_exists() {
  local database_literal exists
  database_literal="$(sql_quote "$DRIVE9_META_DB_NAME")"
  exists="$(mysql_admin_sql -e "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name=${database_literal}")" || \
    fail 'cannot inspect information_schema with the configured MySQL admin account'
  [[ "$exists" == 1 ]]
}

ensure_metadata_database() {
  local database_ident
  database_ident="$(sql_identifier "$DRIVE9_META_DB_NAME")"
  if metadata_database_exists; then
    log "metadata database exists: ${DRIVE9_META_DB_NAME}"
    return
  fi

  if ! is_true "$DRIVE9_CREATE_META_DATABASE"; then
    fail "metadata database ${DRIVE9_META_DB_NAME} does not exist; create it first or set DRIVE9_CREATE_META_DATABASE=true"
  fi

  log "metadata database ${DRIVE9_META_DB_NAME} does not exist; creating it with the configured MySQL admin account"
  mysql_admin_sql -e "CREATE DATABASE IF NOT EXISTS ${database_ident} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci" || \
    fail "failed to create metadata database ${DRIVE9_META_DB_NAME}"
}

metadata_schema_state() {
  local database_literal count
  database_literal="$(sql_quote "$DRIVE9_META_DB_NAME")"
  count="$(mysql_meta_sql -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=${database_literal} AND table_name IN ('tenants', 'tenant_api_keys', 'storage_namespaces')")" || \
    fail "metadata account cannot read database ${DRIVE9_META_DB_NAME}"
  case "$count" in
    3) printf 'initialized\n' ;;
    0) printf 'uninitialized\n' ;;
    *) printf 'partial\n' ;;
  esac
}

check_metadata_database() {
  local state
  mysql_meta_sql -e 'SELECT 1' >/dev/null || fail "cannot connect to metadata database ${DRIVE9_META_DB_NAME} with DRIVE9_META_DB_USER/PASSWORD"
  state="$(metadata_schema_state)"
  case "$state" in
    initialized)
      log "Drive9 metadata schema is already initialized in ${DRIVE9_META_DB_NAME}"
      ;;
    uninitialized)
      log "Drive9 metadata schema is not initialized; drive9-server startup will run the migration"
      ;;
    partial)
      log "Drive9 metadata schema is partial; drive9-server startup will validate and apply safe migrations"
      ;;
    *)
      fail "unknown metadata schema state: ${state}"
      ;;
  esac
  META_SCHEMA_STATE="$state"
}

verify_metadata_schema() {
  local state
  state="$(metadata_schema_state)"
  [[ "$state" == initialized ]] || {
    tail -n 120 -- "$DRIVE9_LOG_FILE" >&2 || true
    fail "Drive9 metadata schema is still ${state} after server startup"
  }
  if [[ "$META_SCHEMA_STATE" != initialized ]]; then
    log "Drive9 metadata schema initialization completed"
  fi
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

mysql_dsn_address() {
  if [[ "$MYSQL_HOST" == *:* && "$MYSQL_HOST" != \[*\] ]]; then
    printf '[%s]:%s' "$MYSQL_HOST" "$MYSQL_PORT"
  else
    printf '%s:%s' "$MYSQL_HOST" "$MYSQL_PORT"
  fi
}

configure_environment() {
  local dsn_address
  dsn_address="$(mysql_dsn_address)"
  DRIVE9_META_DSN="${DRIVE9_META_DSN:-${DRIVE9_META_DB_USER}:${DRIVE9_META_DB_PASSWORD}@tcp(${dsn_address})/${DRIVE9_META_DB_NAME}?parseTime=true&loc=UTC}"
  DRIVE9_MYSQL_ADMIN_DSN="${DRIVE9_MYSQL_ADMIN_DSN:-${DRIVE9_MYSQL_ADMIN_USER}:${DRIVE9_MYSQL_ADMIN_PASSWORD}@tcp(${dsn_address})/?parseTime=true&loc=UTC}"

  export DRIVE9_LISTEN_ADDR DRIVE9_PUBLIC_URL DRIVE9_META_DSN
  export DRIVE9_TENANT_PROVIDER=mysql
  export DRIVE9_MASTER_KEY DRIVE9_TOKEN_SIGNING_KEY
  export DRIVE9_MYSQL_ADMIN_DSN DRIVE9_MYSQL_DATABASE_PREFIX DRIVE9_MYSQL_USER_PREFIX
  export DRIVE9_MYSQL_ACCOUNT_HOST DRIVE9_MYSQL_TLS
  export DRIVE9_S3_BUCKET DRIVE9_S3_REGION DRIVE9_S3_ENDPOINT DRIVE9_S3_PREFIX
  export DRIVE9_S3_FORCE_PATH_STYLE DRIVE9_S3_ACCESS_KEY_ID DRIVE9_S3_SECRET_ACCESS_KEY
  export DRIVE9_S3_SESSION_TOKEN DRIVE9_S3_ROLE_ARN DRIVE9_S3_ENCRYPTION_MODE
  export DRIVE9_S3_KMS_KEY_ID DRIVE9_S3_BUCKET_KEY_ENABLED
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
  chmod 600 -- "$DRIVE9_LOG_FILE" "$DRIVE9_PID_FILE" 2>/dev/null || true

  local attempt
  for attempt in $(seq 1 90); do
    if curl --fail --silent --show-error --max-time 3 "${DRIVE9_HEALTH_URL%/}/healthz" >/dev/null 2>&1; then
      log "drive9-server is ready; PID=${server_pid}"
      return
    fi
    if ! server_is_running "$server_pid"; then
      warn 'drive9-server exited during startup'
      tail -n 120 -- "$DRIVE9_LOG_FILE" >&2 || true
      fail 'drive9-server failed to start'
    fi
    sleep 1
  done
  tail -n 120 -- "$DRIVE9_LOG_FILE" >&2 || true
  fail "drive9-server did not become ready; inspect ${DRIVE9_LOG_FILE}"
}

bootstrap_tenant() {
  local response tenant_id api_key status status_response deadline now error_message
  if ! is_true "$DRIVE9_BOOTSTRAP_TENANT"; then
    log 'skipping initial tenant bootstrap because DRIVE9_BOOTSTRAP_TENANT is disabled'
    return
  fi

  log 'creating an initial MySQL tenant for quick validation'
  response="$(curl --fail --silent --show-error --max-time 15 \
    -X POST "${DRIVE9_HEALTH_URL%/}/v1/provision" \
    -H 'Content-Type: application/json' \
    --data '{}')" || {
      tail -n 120 -- "$DRIVE9_LOG_FILE" >&2 || true
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

  if is_true "$DRIVE9_BOOTSTRAP_COS_SMOKE"; then
    log 'running tenant filesystem smoke test to initialize the COS-backed backend'
    curl --fail --silent --show-error --max-time 30 \
      -H "Authorization: Bearer ${api_key}" \
      "${DRIVE9_HEALTH_URL%/}/v1/fs/?list=1" >/dev/null || {
        tail -n 120 -- "$DRIVE9_LOG_FILE" >&2 || true
        fail 'tenant filesystem/COS smoke test failed'
      }
  fi

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
  require_command curl
  require_command jq
  require_command openssl
  check_mysql_connection
  ensure_metadata_database
  check_metadata_database
  install_go
  configure_environment
  build_server
  start_server
  verify_metadata_schema
  bootstrap_tenant
}

main "$@"
