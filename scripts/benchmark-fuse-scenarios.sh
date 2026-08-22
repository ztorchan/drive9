#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$' \n\t'
umask 077

sudo apt-get update
sudo apt-get install -y build-essential autoconf automake libtool m4 pkg-config perl ca-certificates fuse3 fio jq python3 git mysql-client psmisc coreutils util-linux openmpi-bin libopenmpi-dev

# Drive9 FUSE benchmark suite for an already running deployment.
#
# Scenarios:
#   1. base      - ordinary filesystem FUSE mount
#   2. layer     - writable LayerFS FUSE mount
#   3. git       - coding-agent Git workspace FUSE mount
#
# Every benchmark case gets a newly provisioned MySQL tenant. The case is
# allowed to finish only after its tenant database/user has been deprovisioned,
# its storage namespace DeletePrefix job has completed, and benchmark-only
# metadata/GC rows have been purged. Cases remain strictly sequential.
# Each benchmark process is started with nohup ... & and then waited on.
#
# Required environment:
#   DRIVE9_SERVER           live server URL, for example http://127.0.0.1:9009
#   MYSQL_HOST              existing MySQL host used by the metadata database
#   DRIVE9_TENANT_PROVIDER  must be mysql, matching the running server
#   DRIVE9_META_DB_NAME     Drive9 metadata database name
#   DRIVE9_META_DB_USER     metadata database user
#   DRIVE9_META_DB_PASSWORD metadata database password
#
# Optional environment:
#   MYSQL_PORT             metadata MySQL port (default: 3306)
#   MYSQL_SSL_MODE         mysql-client SSL mode (default: PREFERRED)
#   MYSQL_CONNECT_TIMEOUT_SECONDS (default: 10)
#   BENCH_OUTPUT_DIR       output root (default: /tmp/drive9-fuse-benchmark-<UTC>)
#   RUN_CORRECTNESS_GATES  run repository FUSE/layer/git smoke gates (default: 1)
#   TENANT_PROVISION_TIMEOUT_S (default: 900)
#   TENANT_DELETE_TIMEOUT_S    (default: 3600)
#   TENANT_POLL_INTERVAL_S     (default: 5)
#   MOUNT_STOP_TIMEOUT_S       local FUSE/process cleanup wait (default: 120)
#   DRIVE9_CLI_TIMEOUT_S       Drive9 CLI operation timeout (default: 900)
#   GATE_TIMEOUT_S             total timeout for each correctness gate (default: 7200)
#   SMALL_CASE_TIMEOUT_S       total timeout for each small-file case (default: 86400)
#   LARGE_CASE_TIMEOUT_S       total timeout for each large-file case (default: 43200)
#   KIMI_CASE_TIMEOUT_S        total timeout for each Kimi case (default: 86400)
#   GIT_FEATURE_TIMEOUT_S      per Git feature command timeout (default: 600)
#   GIT_FEATURE_RUN_OVERSIZED  run oversized Git overlay case (default: 1)
#   SMALL_SIZES            fio file sizes in bytes, whitespace separated (default: 1024 20480 102400)
#   SMALL_CONCURRENCY      fio worker counts (default: 1 4 16 64)
#   SMALL_OPS              legacy alias for FIO_SMALL_TOTAL_FILES (default: 1000000)
#   FIO_BIN                existing fio executable (required; no network auto-fetch)
#   FIO_RUNS               fio repetitions per workload (default: 5)
#   FIO_SMALL_TOTAL_FILES  total files per small-file case, split across workers (default: 1000000)
#   FIO_SMALL_FILES_PER_JOB legacy alias interpreted as the total file count
#   Counts are rounded up when they are not divisible by the worker count; the
#   actual count is recorded in each JSON result.
#   FIO_LARGE_CONCURRENCY  whitespace-separated fio worker matrix for large cases (default: 1 2 4 8 16)
#   FIO_LARGE_FILES_PER_JOB files per fio job in large cases (default: 100)
#   FIO_LARGE_NUMJOBS      legacy alias for FIO_LARGE_CONCURRENCY
#   RUN_MDTEST             run mdtest metadata matrix (default: 1)
#   INSTALL_MDTEST        build/install mdtest automatically when missing (default: 1)
#   IOR_REF               IOR git tag/ref used to build mdtest (default: 4.0.0)
#   MDTEST_BUILD_DIR      IOR source/build directory (default: under BENCH_OUTPUT_DIR)
#   MDTEST_INSTALL_DIR    mdtest install directory (default: /usr/local/bin)
#   MDTEST_BUILD_JOBS     mdtest build parallelism (default: nproc)
#   MPICC                 MPI C compiler path/name used to build mdtest
#   MDTEST_BIN             existing mdtest executable; skips build when set
#   MDTEST_LAUNCHER       existing mpirun/mpiexec executable (auto-detected when enabled)
#   MDTEST_TOTAL_ENTRIES  total files/dirs per mdtest case, split across MPI ranks (default: 1000000)
#   MDTEST_FILES_PER_RANK  legacy alias interpreted as the total entry count
#   MDTEST_NUMPROCS        whitespace-separated MPI process matrix (default: 1 4 16 64)
#   MDTEST_ITERATIONS      mdtest iterations per case (default: 1)
#   MDTEST_CASE_TIMEOUT_S  total timeout per mdtest case (default: 43200)
#   FIO_SEQ_BS_BYTES       sequential fio block size (default: 1048576)
#   FIO_RANDOM_BS_BYTES    random fio block size, capped by file size (default: 4096)
#   GIT_FIO_FIXTURE_TREE_FILES committed local Git fixture files (default: 256)
#   LARGE_MIBS             fio large-file sizes (default: 64 256 1024)
#   LARGE_RUNS             legacy alias for FIO_RUNS (default: 5)
#   LAYER_CLI_LARGE_MB     layer smoke large-file size (default: 32)
#   RUN_KIMI_PERF          run customer.kimi_perf at the end (default: 1)
#   KIMI_RUNS              Kimi benchmark runs (default: 3)
#   KIMI_SCALES            namespace scales, comma-separated (default: S,M,L)
#   KIMI_LAYOUTS           namespace layouts (default: single,tree)
#   KIMI_SMALL_SIZES       small/persistence sizes in bytes (default: 1024,20480,102400,1048576,4194304)
#   KIMI_SMALL_CONCURRENCY small-file worker counts (default: 1,4,16,64)
#   KIMI_SMALL_OPS         total operations per small-file case (default: 1000000)
#   KIMI_FLUSH_SIZES       fsync sizes in bytes (default: same as small sizes)
#   KIMI_FLUSH_CONCURRENCY fsync worker counts (default: 1,4,16,64)
#   KIMI_FLUSH_OPS         fsync operations per case (default: 200; native module runs all flush modes)
#   KIMI_STAT_SAMPLES      namespace stat samples (default: 1000)
#   KIMI_PERSISTENCE_SAMPLES remount samples (default: 20; native module runs both persistence modes)
#   KIMI_MOUNT_COUNTS      same-host mount counts (default: 1,2,5,10)
#   KIMI_VISIBILITY_SAMPLES close/fsync visibility samples (default: 50)
#   KIMI_VISIBILITY_TIMEOUT_S (default: 30)
#   KIMI_NAMESPACE_CMD_TIMEOUT_S (default: 1800)
#   KIMI_DATASET_TIMEOUT_S namespace dataset timeout (default: 7200)
#   KIMI_NAMESPACE_CMD_TIMEOUTS scale overrides (default: S=1800,M=3600,L=7200)
#   KIMI_DATASET_TIMEOUTS scale overrides (default: S=7200,M=7200,L=14400)
#   KIMI_SOAK              enable soak section (default: 1)
#   KIMI_SOAK_MINUTES      soak duration (default: 10)
#   KIMI_DURABILITY        Kimi mount durability (default: write-sync)
#   KIMI_PROFILE            Kimi FUSE profile (default: coding-agent)
#   KIMI_REMOTE_ROOT_PREFIX remote root prefix (default: /bench-kimi)
#
# Ubuntu prerequisites are installed automatically at startup. When
# RUN_MDTEST=1, the script also clones/builds IOR mdtest automatically if no
# local mdtest is found; set INSTALL_MDTEST=0 to disable that behavior.
#   sudo modprobe fuse
#   test -e /dev/fuse
#
# Example:
#   export DRIVE9_SERVER=http://127.0.0.1:9009
#   export MYSQL_HOST='127.0.0.1'
#   export DRIVE9_TENANT_PROVIDER='mysql'
#   export DRIVE9_META_DB_NAME='drive9_meta'
#   export DRIVE9_META_DB_USER='drive9_meta'
#   export DRIVE9_META_DB_PASSWORD='metadata-password'
#   nohup bash scripts/benchmark-fuse-scenarios.sh \
#     > /tmp/drive9-fuse-benchmark-suite.log 2>&1 &
#   echo $! > /tmp/drive9-fuse-benchmark-suite.pid

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CLI="${DRIVE9_CLI:-${ROOT_DIR}/bin/drive9}"

DRIVE9_SERVER="${DRIVE9_SERVER:-}"
MYSQL_HOST="${MYSQL_HOST:-}"
DRIVE9_TENANT_PROVIDER="${DRIVE9_TENANT_PROVIDER:-}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_SSL_MODE="${MYSQL_SSL_MODE:-PREFERRED}"
MYSQL_CONNECT_TIMEOUT_SECONDS="${MYSQL_CONNECT_TIMEOUT_SECONDS:-10}"
DRIVE9_META_DB_NAME="${DRIVE9_META_DB_NAME:-}"
DRIVE9_META_DB_USER="${DRIVE9_META_DB_USER:-}"
DRIVE9_META_DB_PASSWORD="${DRIVE9_META_DB_PASSWORD:-}"
BENCH_OUTPUT_DIR="${BENCH_OUTPUT_DIR:-/tmp/drive9-fuse-benchmark-$(date -u +%Y%m%dT%H%M%SZ)}"
BENCH_OUTPUT_DIR="$(mkdir -p -- "$BENCH_OUTPUT_DIR" && cd -- "$BENCH_OUTPUT_DIR" && pwd -P)"
RUN_CORRECTNESS_GATES="${RUN_CORRECTNESS_GATES:-1}"
TENANT_PROVISION_TIMEOUT_S="${TENANT_PROVISION_TIMEOUT_S:-900}"
TENANT_DELETE_TIMEOUT_S="${TENANT_DELETE_TIMEOUT_S:-3600}"
TENANT_POLL_INTERVAL_S="${TENANT_POLL_INTERVAL_S:-5}"
MOUNT_STOP_TIMEOUT_S="${MOUNT_STOP_TIMEOUT_S:-120}"
DRIVE9_CLI_TIMEOUT_S="${DRIVE9_CLI_TIMEOUT_S:-900}"
GATE_TIMEOUT_S="${GATE_TIMEOUT_S:-7200}"
SMALL_CASE_TIMEOUT_S="${SMALL_CASE_TIMEOUT_S:-86400}"
LARGE_CASE_TIMEOUT_S="${LARGE_CASE_TIMEOUT_S:-43200}"
KIMI_CASE_TIMEOUT_S="${KIMI_CASE_TIMEOUT_S:-86400}"
GIT_FEATURE_TIMEOUT_S="${GIT_FEATURE_TIMEOUT_S:-600}"
GIT_FEATURE_RUN_OVERSIZED="${GIT_FEATURE_RUN_OVERSIZED:-1}"
SMALL_SIZES="${SMALL_SIZES:-1024 20480 102400}"
SMALL_CONCURRENCY="${SMALL_CONCURRENCY:-1 4 16 64}"
SMALL_OPS="${SMALL_OPS:-1000000}"
FIO_BIN="${FIO_BIN:-}"
LARGE_MIBS="${LARGE_MIBS:-64 256 1024}"
LARGE_RUNS="${LARGE_RUNS:-5}"
FIO_RUNS="${FIO_RUNS:-$LARGE_RUNS}"
FIO_SMALL_TOTAL_FILES="${FIO_SMALL_TOTAL_FILES:-${FIO_SMALL_FILES_PER_JOB:-$SMALL_OPS}}"
FIO_LARGE_CONCURRENCY="${FIO_LARGE_CONCURRENCY:-${FIO_LARGE_NUMJOBS:-1 2 4 8 16}}"
FIO_LARGE_FILES_PER_JOB="${FIO_LARGE_FILES_PER_JOB:-100}"
FIO_LARGE_NUMJOBS="${FIO_LARGE_NUMJOBS:-$FIO_LARGE_CONCURRENCY}"
FIO_SEQ_BS_BYTES="${FIO_SEQ_BS_BYTES:-1048576}"
FIO_RANDOM_BS_BYTES="${FIO_RANDOM_BS_BYTES:-4096}"
GIT_FIO_FIXTURE_TREE_FILES="${GIT_FIO_FIXTURE_TREE_FILES:-256}"
RUN_MDTEST="${RUN_MDTEST:-1}"
INSTALL_MDTEST="${INSTALL_MDTEST:-1}"
IOR_REF="${IOR_REF:-4.0.0}"
MDTEST_BIN="${MDTEST_BIN:-}"
MDTEST_BUILD_DIR="${MDTEST_BUILD_DIR:-${BENCH_OUTPUT_DIR}/deps/ior-${IOR_REF}}"
MDTEST_INSTALL_DIR="${MDTEST_INSTALL_DIR:-/usr/local/bin}"
MDTEST_BUILD_JOBS="${MDTEST_BUILD_JOBS:-}"
MDTEST_LAUNCHER="${MDTEST_LAUNCHER:-}"
MDTEST_TOTAL_ENTRIES="${MDTEST_TOTAL_ENTRIES:-${MDTEST_FILES_PER_RANK:-1000000}}"
MDTEST_NUMPROCS="${MDTEST_NUMPROCS:-1 4 16 64}"
MDTEST_MODES="${MDTEST_MODES:-files,dirs}"
MDTEST_ITERATIONS="${MDTEST_ITERATIONS:-1}"
MDTEST_CASE_TIMEOUT_S="${MDTEST_CASE_TIMEOUT_S:-43200}"
LAYER_CLI_LARGE_MB="${LAYER_CLI_LARGE_MB:-32}"
MOUNT_READY_TIMEOUT_S="${MOUNT_READY_TIMEOUT_S:-60}"
UMOUNT_TIMEOUT="${UMOUNT_TIMEOUT:-60s}"
RUN_KIMI_PERF="${RUN_KIMI_PERF:-1}"
KIMI_RUNS="${KIMI_RUNS:-3}"
KIMI_SCALES="${KIMI_SCALES:-S,M,L}"
KIMI_LAYOUTS="${KIMI_LAYOUTS:-single,tree}"
KIMI_SMALL_SIZES="${KIMI_SMALL_SIZES:-1024,20480,102400,1048576,4194304}"
KIMI_SMALL_CONCURRENCY="${KIMI_SMALL_CONCURRENCY:-1,4,16,64}"
KIMI_SMALL_OPS="${KIMI_SMALL_OPS:-1000000}"
KIMI_FLUSH_SIZES="${KIMI_FLUSH_SIZES:-1024,20480,102400,1048576,4194304}"
KIMI_FLUSH_CONCURRENCY="${KIMI_FLUSH_CONCURRENCY:-1,4,16,64}"
KIMI_FLUSH_OPS="${KIMI_FLUSH_OPS:-200}"
KIMI_STAT_SAMPLES="${KIMI_STAT_SAMPLES:-1000}"
KIMI_PERSISTENCE_SAMPLES="${KIMI_PERSISTENCE_SAMPLES:-20}"
KIMI_MOUNT_COUNTS="${KIMI_MOUNT_COUNTS:-1,2,5,10}"
KIMI_VISIBILITY_SAMPLES="${KIMI_VISIBILITY_SAMPLES:-50}"
KIMI_VISIBILITY_TIMEOUT_S="${KIMI_VISIBILITY_TIMEOUT_S:-30}"
KIMI_NAMESPACE_CMD_TIMEOUT_S="${KIMI_NAMESPACE_CMD_TIMEOUT_S:-1800}"
KIMI_DATASET_TIMEOUT_S="${KIMI_DATASET_TIMEOUT_S:-7200}"
KIMI_NAMESPACE_CMD_TIMEOUTS="${KIMI_NAMESPACE_CMD_TIMEOUTS:-S=1800,M=3600,L=7200}"
KIMI_DATASET_TIMEOUTS="${KIMI_DATASET_TIMEOUTS:-S=7200,M=7200,L=14400}"
KIMI_SOAK="${KIMI_SOAK:-1}"
KIMI_SOAK_MINUTES="${KIMI_SOAK_MINUTES:-10}"
KIMI_PROFILE="${KIMI_PROFILE:-coding-agent}"
KIMI_DURABILITY="${KIMI_DURABILITY:-write-sync}"
KIMI_REMOTE_ROOT_PREFIX="${KIMI_REMOTE_ROOT_PREFIX:-/bench-kimi}"

LOG_DIR="${BENCH_OUTPUT_DIR}/logs"
RESULT_DIR="${BENCH_OUTPUT_DIR}/results"
WORK_DIR="${BENCH_OUTPUT_DIR}/work"
mkdir -p -- "$LOG_DIR" "$RESULT_DIR" "$WORK_DIR"

ACTIVE_REMOTE_ROOT=""
ACTIVE_LAYER_ID=""
ACTIVE_MOUNT_POINT=""
ACTIVE_MOUNT_PID=""
ACTIVE_MOUNT_PGID=""
ACTIVE_MOUNT_LOG=""
ACTIVE_CACHE_DIR=""
ACTIVE_LOCAL_ROOT=""
ACTIVE_CASE_DIR=""
ACTIVE_EXTRA_CASE_DIR=""
ACTIVE_TENANT_ID=""
ACTIVE_TENANT_API_KEY=""
ACTIVE_PROCESS_CLEANUP_FAILED=0
ACTIVE_TENANT_DELETE_REQUESTED=0
ACTIVE_CHILD_PID=""
ACTIVE_CHILD_PGID=""
ACTIVE_CHILD_NAME=""
ACTIVE_CHILD_LOG=""
ACTIVE_CASE_DEADLINE=0

log() {
  printf '[drive9-bench] %s\n' "$*"
}

warn() {
  printf '[drive9-bench] warning: %s\n' "$*" >&2
}

fail() {
  printf '[drive9-bench] error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

is_true() {
  case "${1,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

require_positive_int() {
  local name=$1
  local value=$2
  [[ "$value" =~ ^[0-9]+$ ]] && (( value > 0 )) || fail "${name} must be a positive integer: ${value}"
}

require_nonnegative_number() {
  local name=$1
  local value=$2
  [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "${name} must be a non-negative number: ${value}"
}

probe_tool() {
  local binary=$1
  local option=$2
  local output rc=0
  # mdtest prints its help and exits non-zero for unsupported options such as
  # --version. Treat non-empty diagnostic/help output as a valid probe result.
  output="$(timeout --signal=TERM --kill-after=5s 15s "$binary" "$option" 2>&1)" || rc=$?
  [[ -n "$output" ]] || return "$rc"
  printf '%s\n' "$output" | awk 'NF { print; exit }'
}

install_mdtest_if_needed() {
  is_true "$RUN_MDTEST" || return 0

  if [[ -n "$MDTEST_BIN" ]]; then
    [[ -x "$MDTEST_BIN" ]] || fail "MDTEST_BIN is not executable: ${MDTEST_BIN}"
    return 0
  fi

  local found
  found="$(command -v mdtest || true)"
  if [[ -n "$found" ]]; then
    MDTEST_BIN="$found"
    log "using existing mdtest: ${MDTEST_BIN}"
    return 0
  fi
  is_true "$INSTALL_MDTEST" || \
    fail 'mdtest is missing and INSTALL_MDTEST is disabled; set MDTEST_BIN or INSTALL_MDTEST=1'

  local source_dir="$MDTEST_BUILD_DIR"
  local jobs="${MDTEST_BUILD_JOBS:-}"
  local mpicc_bin="${MPICC:-}"
  local built_mdtest=""
  local candidate
  [[ -n "$jobs" ]] || jobs="$(nproc)"
  require_positive_int MDTEST_BUILD_JOBS "$jobs"
  if [[ -n "$mpicc_bin" && ! -x "$mpicc_bin" ]]; then
    mpicc_bin="$(command -v "$mpicc_bin" || true)"
  elif [[ -z "$mpicc_bin" ]]; then
    mpicc_bin="$(command -v mpicc || true)"
  fi
  [[ -x "$mpicc_bin" ]] || fail 'mpicc is required to build mdtest; install libopenmpi-dev or set MPICC'

  mkdir -p -- "$(dirname -- "$source_dir")"
  if [[ -e "$source_dir" ]]; then
    [[ -d "$source_dir/.git" ]] || \
      fail "MDTEST_BUILD_DIR exists but is not an IOR git checkout: ${source_dir}"
    log "reusing IOR source directory: ${source_dir}"
  else
    log "cloning IOR ${IOR_REF} to build mdtest: ${source_dir}"
    GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$IOR_REF" -- \
      https://github.com/hpc/ior.git "$source_dir"
  fi

  if [[ -f "$source_dir/src/option.c" ]]; then
    python3 - "$source_dir/src/option.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = "void(*fp)() = o->variable;\n                  fp(arg);"
new = "void(*fp)(char *) = o->variable;\n                  fp(arg);"
if old in text:
    path.write_text(text.replace(old, new), encoding="utf-8")
PY
  fi

  if [[ ! -f "$source_dir/configure" ]]; then
    if [[ -f "$source_dir/bootstrap" ]]; then
      log 'bootstrapping IOR build system'
      (cd -- "$source_dir" && bash ./bootstrap)
    elif [[ -f "$source_dir/autogen.sh" ]]; then
      log 'generating IOR configure script'
      (cd -- "$source_dir" && bash ./autogen.sh)
    fi
  fi
  [[ -f "$source_dir/configure" ]] || fail "IOR configure script was not generated: ${source_dir}"

  log "configuring IOR mdtest with MPI compiler: ${mpicc_bin}"
  (
    cd -- "$source_dir"
    MPICC="$mpicc_bin" ./configure \
      --with-mpiio=no \
      --with-hdf5=no \
      --with-ncmpi=no
  )
  log "building IOR mdtest with ${jobs} parallel jobs"
  (cd -- "$source_dir" && make -j"$jobs")

  for candidate in "$source_dir/src/mdtest" "$source_dir/mdtest"; do
    if [[ -x "$candidate" ]]; then
      built_mdtest="$candidate"
      break
    fi
  done
  [[ -n "$built_mdtest" ]] || fail "mdtest binary was not produced by IOR: ${source_dir}"

  if mkdir -p -- "$MDTEST_INSTALL_DIR" 2>/dev/null && [[ -w "$MDTEST_INSTALL_DIR" ]]; then
    install -m 0755 -- "$built_mdtest" "${MDTEST_INSTALL_DIR}/mdtest"
  else
    sudo install -d -m 0755 -- "$MDTEST_INSTALL_DIR"
    sudo install -m 0755 -- "$built_mdtest" "${MDTEST_INSTALL_DIR}/mdtest"
  fi
  MDTEST_BIN="${MDTEST_INSTALL_DIR}/mdtest"
  [[ -x "$MDTEST_BIN" ]] || fail "mdtest installation failed: ${MDTEST_BIN}"
  log "installed mdtest: ${MDTEST_BIN}"
}

for required_env in DRIVE9_SERVER MYSQL_HOST DRIVE9_TENANT_PROVIDER DRIVE9_META_DB_NAME DRIVE9_META_DB_USER DRIVE9_META_DB_PASSWORD; do
  [[ -n "${!required_env}" ]] || fail "${required_env} is required for per-case tenant cleanup"
done
[[ "${DRIVE9_TENANT_PROVIDER,,}" == mysql ]] || \
  fail "DRIVE9_TENANT_PROVIDER must be mysql; the running server must use the MySQL tenant provider"

require_command bash
require_command curl
require_command git
require_command jq
require_command make
require_command findmnt
require_command fuser
require_command mountpoint
require_command mysql
require_command setsid
require_command timeout
require_command python3
[[ -e /dev/fuse ]] || fail '/dev/fuse is unavailable; enable FUSE on this Ubuntu host first'
if [[ -n "$FIO_BIN" ]]; then
  [[ -x "$FIO_BIN" ]] || fail "FIO_BIN is not executable: ${FIO_BIN}"
else
  FIO_BIN="$(command -v fio || true)"
  [[ -n "$FIO_BIN" ]] || fail 'fio is required; install it locally or set FIO_BIN (network auto-fetch is disabled)'
fi
FIO_VERSION="$("$FIO_BIN" --version 2>/dev/null || true)"
[[ "$FIO_VERSION" == fio-* ]] || fail "FIO_BIN is not a usable fio executable: ${FIO_BIN}"

install_mdtest_if_needed

MDTEST_VERSION='disabled'
MDTEST_LAUNCHER_VERSION='disabled'
if is_true "$RUN_MDTEST"; then
  if [[ -n "$MDTEST_BIN" ]]; then
    [[ -x "$MDTEST_BIN" ]] || fail "MDTEST_BIN is not executable: ${MDTEST_BIN}"
  else
    MDTEST_BIN="$(command -v mdtest || true)"
    [[ -n "$MDTEST_BIN" ]] || fail 'mdtest is required when RUN_MDTEST=1; automatic IOR build did not produce a binary'
  fi
  if MDTEST_VERSION="$(probe_tool "$MDTEST_BIN" --version)"; then
    :
  elif MDTEST_VERSION="$(probe_tool "$MDTEST_BIN" -h)"; then
    :
  else
    fail "MDTEST_BIN did not respond successfully to --version or -h: ${MDTEST_BIN}"
  fi

  if [[ -n "$MDTEST_LAUNCHER" ]]; then
    [[ -x "$MDTEST_LAUNCHER" ]] || fail "MDTEST_LAUNCHER is not executable: ${MDTEST_LAUNCHER}"
  else
    MDTEST_LAUNCHER="$(command -v mpirun || command -v mpiexec || true)"
    [[ -n "$MDTEST_LAUNCHER" ]] || fail 'mpirun/mpiexec is required when RUN_MDTEST=1; set MDTEST_LAUNCHER'
  fi
  MDTEST_LAUNCHER_VERSION="$(probe_tool "$MDTEST_LAUNCHER" --version)" || \
    fail "MDTEST_LAUNCHER did not respond successfully to --version: ${MDTEST_LAUNCHER}"
fi

log 'building the Drive9 CLI from source'
make -C "$ROOT_DIR" build-cli
[[ -x "$CLI" ]] || fail "Drive9 CLI was not produced: ${CLI}"

require_positive_int MYSQL_PORT "$MYSQL_PORT"
require_positive_int MYSQL_CONNECT_TIMEOUT_SECONDS "$MYSQL_CONNECT_TIMEOUT_SECONDS"
require_positive_int TENANT_PROVISION_TIMEOUT_S "$TENANT_PROVISION_TIMEOUT_S"
require_positive_int TENANT_DELETE_TIMEOUT_S "$TENANT_DELETE_TIMEOUT_S"
require_positive_int TENANT_POLL_INTERVAL_S "$TENANT_POLL_INTERVAL_S"
require_positive_int MOUNT_STOP_TIMEOUT_S "$MOUNT_STOP_TIMEOUT_S"
require_positive_int DRIVE9_CLI_TIMEOUT_S "$DRIVE9_CLI_TIMEOUT_S"
require_positive_int GATE_TIMEOUT_S "$GATE_TIMEOUT_S"
require_positive_int SMALL_CASE_TIMEOUT_S "$SMALL_CASE_TIMEOUT_S"
require_positive_int LARGE_CASE_TIMEOUT_S "$LARGE_CASE_TIMEOUT_S"
require_positive_int KIMI_CASE_TIMEOUT_S "$KIMI_CASE_TIMEOUT_S"
require_positive_int MDTEST_CASE_TIMEOUT_S "$MDTEST_CASE_TIMEOUT_S"
require_positive_int GIT_FEATURE_TIMEOUT_S "$GIT_FEATURE_TIMEOUT_S"
require_positive_int SMALL_OPS "$SMALL_OPS"
require_positive_int FIO_RUNS "$FIO_RUNS"
require_positive_int FIO_SMALL_TOTAL_FILES "$FIO_SMALL_TOTAL_FILES"
require_positive_int FIO_LARGE_FILES_PER_JOB "$FIO_LARGE_FILES_PER_JOB"
require_positive_int MDTEST_TOTAL_ENTRIES "$MDTEST_TOTAL_ENTRIES"
require_positive_int MDTEST_ITERATIONS "$MDTEST_ITERATIONS"
require_positive_int FIO_SEQ_BS_BYTES "$FIO_SEQ_BS_BYTES"
require_positive_int FIO_RANDOM_BS_BYTES "$FIO_RANDOM_BS_BYTES"
require_positive_int GIT_FIO_FIXTURE_TREE_FILES "$GIT_FIO_FIXTURE_TREE_FILES"
require_positive_int LARGE_RUNS "$LARGE_RUNS"
require_positive_int LAYER_CLI_LARGE_MB "$LAYER_CLI_LARGE_MB"
require_positive_int MOUNT_READY_TIMEOUT_S "$MOUNT_READY_TIMEOUT_S"
require_positive_int KIMI_RUNS "$KIMI_RUNS"
require_positive_int KIMI_SMALL_OPS "$KIMI_SMALL_OPS"
require_positive_int KIMI_FLUSH_OPS "$KIMI_FLUSH_OPS"
require_positive_int KIMI_STAT_SAMPLES "$KIMI_STAT_SAMPLES"
require_positive_int KIMI_PERSISTENCE_SAMPLES "$KIMI_PERSISTENCE_SAMPLES"
require_positive_int KIMI_VISIBILITY_SAMPLES "$KIMI_VISIBILITY_SAMPLES"
require_positive_int KIMI_VISIBILITY_TIMEOUT_S "$KIMI_VISIBILITY_TIMEOUT_S"
require_positive_int KIMI_NAMESPACE_CMD_TIMEOUT_S "$KIMI_NAMESPACE_CMD_TIMEOUT_S"
require_positive_int KIMI_DATASET_TIMEOUT_S "$KIMI_DATASET_TIMEOUT_S"
require_nonnegative_number KIMI_SOAK_MINUTES "$KIMI_SOAK_MINUTES"
(( MYSQL_PORT >= 1 && MYSQL_PORT <= 65535 )) || fail "MYSQL_PORT must be between 1 and 65535: ${MYSQL_PORT}"

validate_positive_csv() {
  local name=$1
  local value=$2
  local item
  local -a items
  IFS=',' read -r -a items <<< "$value"
  for item in "${items[@]}"; do
    item="$(printf '%s' "$item" | tr -d '[:space:]')"
    [[ "$item" =~ ^[0-9]+$ ]] && (( item > 0 )) || fail "${name} contains a non-positive integer: ${item}"
  done
}

validate_whitespace_positive_ints() {
  local name=$1
  local value=$2
  local item
  local -a items
  read -r -a items <<< "$value"
  for item in "${items[@]}"; do
    require_positive_int "$name" "$item"
  done
}

validate_enum_csv() {
  local name=$1
  local value=$2
  local allowed=$3
  local item
  local -a items
  IFS=',' read -r -a items <<< "$value"
  for item in "${items[@]}"; do
    item="$(printf '%s' "$item" | tr -d '[:space:]')"
    case ",$allowed," in
      *,"$item",*) ;;
      *) fail "${name} contains unsupported value: ${item}" ;;
    esac
  done
}

validate_whitespace_positive_ints LARGE_MIBS "$LARGE_MIBS"
validate_whitespace_positive_ints FIO_LARGE_CONCURRENCY "$FIO_LARGE_CONCURRENCY"
validate_whitespace_positive_ints MDTEST_NUMPROCS "$MDTEST_NUMPROCS"
validate_enum_csv MDTEST_MODES "$MDTEST_MODES" 'files,dirs,all'
validate_positive_csv KIMI_SMALL_SIZES "$KIMI_SMALL_SIZES"
validate_positive_csv KIMI_SMALL_CONCURRENCY "$KIMI_SMALL_CONCURRENCY"
validate_positive_csv KIMI_FLUSH_SIZES "$KIMI_FLUSH_SIZES"
validate_positive_csv KIMI_FLUSH_CONCURRENCY "$KIMI_FLUSH_CONCURRENCY"
validate_positive_csv KIMI_MOUNT_COUNTS "$KIMI_MOUNT_COUNTS"
validate_whitespace_positive_ints SMALL_SIZES "$SMALL_SIZES"
validate_whitespace_positive_ints SMALL_CONCURRENCY "$SMALL_CONCURRENCY"
validate_enum_csv KIMI_SCALES "$KIMI_SCALES" 'S,M,L'
validate_enum_csv KIMI_LAYOUTS "$KIMI_LAYOUTS" 'single,tree'

MYSQL_CLIENT_SSL_ARGS=()
if [[ -n "$MYSQL_SSL_MODE" ]]; then
  MYSQL_CLIENT_SSL_ARGS=("--ssl-mode=${MYSQL_SSL_MODE}")
fi

sql_quote() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\'/\'\'}
  printf "'%s'" "$value"
}

sql_identifier() {
  local value=$1
  value=${value//\`/\`\`}
  printf '`%s`' "$value"
}

mysql_meta_sql() {
  MYSQL_PWD="$DRIVE9_META_DB_PASSWORD" mysql \
    --protocol=tcp \
    --host="$MYSQL_HOST" \
    --port="$MYSQL_PORT" \
    --user="$DRIVE9_META_DB_USER" \
    "${MYSQL_CLIENT_SSL_ARGS[@]}" \
    --connect-timeout="$MYSQL_CONNECT_TIMEOUT_SECONDS" \
    --database="$DRIVE9_META_DB_NAME" \
    --batch --skip-column-names --raw "$@"
}

# Keep all CLI calls explicit and bound to the current case tenant. Every CLI
# operation is bounded so a stalled FUSE/backend request cannot block cleanup.
drive9() {
  [[ -n "$ACTIVE_TENANT_API_KEY" ]] || fail 'no active benchmark tenant API key'
  timeout --signal=TERM --kill-after="${MOUNT_STOP_TIMEOUT_S}s" "${DRIVE9_CLI_TIMEOUT_S}s" \
    env DRIVE9_SERVER="$DRIVE9_SERVER" DRIVE9_API_KEY="$ACTIVE_TENANT_API_KEY" "$CLI" "$@"
}

curl_config_escape() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\r'/\\r}
  value=${value//$'\n'/\\n}
  printf '%s' "$value"
}

curl_tenant_request() {
  local api_key=$1
  local method=$2
  local url=$3
  local timeout_s=$4
  shift 4
  local escaped_url escaped_method escaped_header
  escaped_url="$(curl_config_escape "$url")"
  escaped_method="$(curl_config_escape "$method")"
  escaped_header="$(curl_config_escape "Authorization: Bearer ${api_key}")"
  # Use curl's config stream so the tenant API key is not placed in argv.
  curl --silent --show-error \
    --connect-timeout "$MYSQL_CONNECT_TIMEOUT_SECONDS" \
    --max-time "$timeout_s" \
    --write-out $'\n%{http_code}' \
    --config - "$@" <<EOF
url = "$escaped_url"
request = "$escaped_method"
header = "$escaped_header"
EOF
}

parse_http_response() {
  local response=$1
  HTTP_STATUS_CODE="${response##*$'\n'}"
  HTTP_RESPONSE_BODY="${response%$'\n'*}"
}

log 'checking metadata database connectivity'
mysql_meta_sql -e 'SELECT 1' >/dev/null

pid_is_running() {
  local pid=${1:-} stat
  [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1 || return 1
  stat="$(ps -o stat= -p "$pid" 2>/dev/null)" || return 1
  [[ -n "$stat" && "$stat" != Z* ]]
}

process_group_has_live_members() {
  local pgid=$1
  local output group stat
  [[ "$pgid" =~ ^[0-9]+$ ]] || return 1
  output="$(ps -eo pgid=,stat= 2>/dev/null)" || return 2
  while read -r group stat; do
    [[ "$group" == "$pgid" ]] || continue
    [[ "$stat" == Z* ]] && continue
    return 0
  done <<< "$output"
  return 1
}

wait_for_pid_exit() {
  local pid=$1
  local elapsed=0
  while (( elapsed < MOUNT_STOP_TIMEOUT_S )); do
    pid_is_running "$pid" || return 0
    sleep 1
    elapsed=$((elapsed + 1))
  done
  ! pid_is_running "$pid"
}

is_mounted() {
  findmnt -rn --mountpoint "$1" >/dev/null 2>&1
}

wait_for_unmounted() {
  local mount_point=$1
  local elapsed=0
  while (( elapsed < MOUNT_STOP_TIMEOUT_S )); do
    is_mounted "$mount_point" || return 0
    sleep 1
    elapsed=$((elapsed + 1))
  done
  ! is_mounted "$mount_point"
}

force_unmount_path() {
  local mount_point=$1
  if command -v fusermount3 >/dev/null 2>&1; then
    fusermount3 -uz "$mount_point" >/dev/null 2>&1 && return 0
  fi
  if command -v fusermount >/dev/null 2>&1; then
    fusermount -uz "$mount_point" >/dev/null 2>&1 && return 0
  fi
  umount -l "$mount_point" >/dev/null 2>&1 || true
}

mount_user_pids() {
  local mount_point=$1 output rc
  command -v fuser >/dev/null 2>&1 || return 1
  if output="$(fuser -m "$mount_point" 2>/dev/null)"; then
    :
  else
    rc=$?
    # fuser returns 1 when no process references the mount; that is success
    # for cleanup purposes. Other failures remain fail-closed.
    if (( rc != 1 )); then
      return "$rc"
    fi
    output=""
  fi
  [[ -n "$output" ]] || return 0
  printf '%s\n' "$output" | \
    awk '{for (i = 2; i <= NF; i++) { token = $i; sub(/[^0-9].*$/, "", token); if (token ~ /^[0-9]+$/) print token }}' | \
    sort -nu
}

terminate_mount_users() {
  local mount_point=$1
  local pid pid_output
  local -a pids remaining
  if ! pid_output="$(mount_user_pids "$mount_point")"; then
    return 1
  fi
  pids=()
  if [[ -n "$pid_output" ]]; then
    mapfile -t pids <<< "$pid_output" || return 1
  fi
  for pid in "${pids[@]}"; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    (( pid == $$ || pid == PPID )) && continue
    log "stopping process using FUSE mount: pid=${pid} mount=${mount_point}"
    kill -TERM "$pid" >/dev/null 2>&1 || true
  done
  ((${#pids[@]} == 0)) || sleep 2
  if ! pid_output="$(mount_user_pids "$mount_point")"; then
    return 1
  fi
  remaining=()
  if [[ -n "$pid_output" ]]; then
    mapfile -t remaining <<< "$pid_output" || return 1
  fi
  for pid in "${remaining[@]}"; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    (( pid == $$ || pid == PPID )) && continue
    warn "force-stopping process using FUSE mount: pid=${pid} mount=${mount_point}"
    kill -KILL "$pid" >/dev/null 2>&1 || true
  done
  ((${#remaining[@]} == 0)) || sleep 1
  if ! pid_output="$(mount_user_pids "$mount_point")"; then
    return 1
  fi
  [[ -z "$pid_output" ]]
}

stop_active_child() {
  local pid="${ACTIVE_CHILD_PID:-}"
  local pgid="${ACTIVE_CHILD_PGID:-}"
  local rc=0 group_rc=0
  [[ -n "$pid" || -n "$pgid" ]] || return 0

  if [[ -n "$pgid" && "$pgid" =~ ^[0-9]+$ && "$pgid" -gt 1 && "$pgid" != "$$" ]]; then
    if kill -0 -- "-$pgid" >/dev/null 2>&1; then
      log "stopping active child process group: ${ACTIVE_CHILD_NAME:-unknown} pgid=${pgid}"
      kill -TERM -- "-$pgid" >/dev/null 2>&1 || true
      sleep 1
    fi
  elif [[ -n "$pid" ]] && pid_is_running "$pid"; then
    log "stopping active child: ${ACTIVE_CHILD_NAME:-unknown} pid=${pid}"
    kill -TERM "$pid" >/dev/null 2>&1 || true
  fi

  if [[ -n "$pid" ]] && ! wait_for_pid_exit "$pid"; then
    warn "child did not stop after SIGTERM: ${ACTIVE_CHILD_NAME:-unknown} pid=${pid}"
    if [[ -n "$pgid" && "$pgid" =~ ^[0-9]+$ && "$pgid" -gt 1 && "$pgid" != "$$" ]]; then
      kill -KILL -- "-$pgid" >/dev/null 2>&1 || true
    else
      kill -KILL "$pid" >/dev/null 2>&1 || true
    fi
    wait_for_pid_exit "$pid" || rc=1
  fi
  [[ -n "$pid" ]] && wait "$pid" >/dev/null 2>&1 || true
  if [[ -n "$pgid" && "$pgid" =~ ^[0-9]+$ && "$pgid" -gt 1 && "$pgid" != "$$" ]]; then
    if process_group_has_live_members "$pgid"; then
      warn "process group remains active: ${ACTIVE_CHILD_NAME:-unknown} pgid=${pgid}"
      kill -KILL -- "-$pgid" >/dev/null 2>&1 || true
      sleep 1
      if process_group_has_live_members "$pgid"; then
        rc=1
      else
        group_rc=$?
        (( group_rc == 1 )) || rc=1
      fi
    else
      group_rc=$?
      (( group_rc == 1 )) || rc=1
    fi
  fi
  if [[ -n "$pid" ]] && pid_is_running "$pid"; then
    rc=1
  fi
  if (( rc == 0 )); then
    ACTIVE_CHILD_PID=""
    ACTIVE_CHILD_PGID=""
    ACTIVE_CHILD_NAME=""
    ACTIVE_CHILD_LOG=""
  fi
  return "$rc"
}

run_nohup() {
  local name=$1
  local timeout_seconds=$2
  shift 2
  local log_file="${LOG_DIR}/${name}.log"
  local pid_file="${LOG_DIR}/${name}.pid"
  local pid rc=0 cleanup_rc=0
  local -a command
  if [[ ! "$timeout_seconds" =~ ^[0-9]+$ ]] || (( timeout_seconds <= 0 )); then
    fail "invalid timeout for ${name}: ${timeout_seconds}"
  fi
  command=(timeout --signal=TERM --kill-after="${MOUNT_STOP_TIMEOUT_S}s" "${timeout_seconds}s" "$@")
  log "nohup start: ${name} (timeout=${timeout_seconds}s, process-group=1)"
  log "  log: ${log_file}"
  DRIVE9_SERVER="$DRIVE9_SERVER" DRIVE9_BASE="$DRIVE9_SERVER" DRIVE9_API_KEY="$ACTIVE_TENANT_API_KEY" \
    nohup setsid "${command[@]}" >"$log_file" 2>&1 &
  pid=$!
  ACTIVE_CHILD_PID="$pid"
  ACTIVE_CHILD_PGID="$pid"
  ACTIVE_CHILD_NAME="$name"
  ACTIVE_CHILD_LOG="$log_file"
  printf '%s\n' "$pid" >"$pid_file"
  log "  pid: ${pid} pgid=${pid}"
  if wait "$pid"; then
    rc=0
  else
    rc=$?
  fi
  if ! stop_active_child; then
    cleanup_rc=1
  fi
  if (( cleanup_rc != 0 && rc == 0 )); then
    rc=1
  fi
  if (( rc == 0 )); then
    log "nohup done: ${name}"
    return 0
  fi
  if (( rc == 124 || rc == 125 || rc == 137 )); then
    warn "nohup command timed out or was killed: ${name}, exit=${rc}"
  else
    warn "nohup command failed: ${name}, exit=${rc}"
  fi
  tail -n 120 -- "$log_file" >&2 || true
  return "$rc"
}

case_timeout_remaining() {
  local requested=$1
  local now remaining
  require_positive_int fio_timeout "$requested"
  if (( ACTIVE_CASE_DEADLINE <= 0 )); then
    printf '%s\n' "$requested"
    return 0
  fi
  now="$(date +%s)"
  remaining=$((ACTIVE_CASE_DEADLINE - now))
  if (( remaining <= 0 )); then
    warn "case deadline exceeded"
    return 124
  fi
  if (( remaining < requested )); then
    printf '%s\n' "$remaining"
  else
    printf '%s\n' "$requested"
  fi
}

stop_mount() {
  local mount_point="${1:-${ACTIVE_MOUNT_POINT:-}}"
  local mount_pid="${2:-${ACTIVE_MOUNT_PID:-}}"
  local mount_pgid="${ACTIVE_MOUNT_PGID:-}"
  local rc=0 group_rc=0
  if [[ -n "$mount_point" ]] && is_mounted "$mount_point"; then
    if [[ -n "${ACTIVE_TENANT_API_KEY:-}" ]]; then
      timeout --signal=TERM --kill-after="${MOUNT_STOP_TIMEOUT_S}s" "${DRIVE9_CLI_TIMEOUT_S}s" \
        env DRIVE9_SERVER="$DRIVE9_SERVER" DRIVE9_API_KEY="$ACTIVE_TENANT_API_KEY" \
        "$CLI" umount --timeout "$UMOUNT_TIMEOUT" "$mount_point" >/dev/null 2>&1 || true
    fi
    if is_mounted "$mount_point"; then
      terminate_mount_users "$mount_point" || rc=1
      force_unmount_path "$mount_point"
      wait_for_unmounted "$mount_point" || true
    fi
  fi
  if [[ -n "$mount_pgid" && "$mount_pgid" =~ ^[0-9]+$ && "$mount_pgid" -gt 1 && "$mount_pgid" != "$$" ]] && \
    kill -0 -- "-$mount_pgid" >/dev/null 2>&1; then
    kill -TERM -- "-$mount_pgid" >/dev/null 2>&1 || true
  elif [[ -n "$mount_pid" ]] && pid_is_running "$mount_pid"; then
    kill -TERM "$mount_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$mount_pid" ]] && ! wait_for_pid_exit "$mount_pid"; then
    warn "FUSE mount process did not stop after SIGTERM: pid=${mount_pid} mount=${mount_point}"
    if [[ -n "$mount_pgid" && "$mount_pgid" =~ ^[0-9]+$ && "$mount_pgid" -gt 1 && "$mount_pgid" != "$$" ]]; then
      kill -KILL -- "-$mount_pgid" >/dev/null 2>&1 || true
    else
      kill -KILL "$mount_pid" >/dev/null 2>&1 || true
    fi
    wait_for_pid_exit "$mount_pid" || rc=1
  fi
  [[ -n "$mount_pid" ]] && wait "$mount_pid" >/dev/null 2>&1 || true
  if [[ -n "$mount_pgid" && "$mount_pgid" =~ ^[0-9]+$ && "$mount_pgid" -gt 1 && "$mount_pgid" != "$$" ]]; then
    if process_group_has_live_members "$mount_pgid"; then
      warn "FUSE mount process group remains active: pgid=${mount_pgid} mount=${mount_point}"
      kill -KILL -- "-$mount_pgid" >/dev/null 2>&1 || true
      sleep 1
      if process_group_has_live_members "$mount_pgid"; then
        rc=1
      else
        group_rc=$?
        (( group_rc == 1 )) || rc=1
      fi
    else
      group_rc=$?
      (( group_rc == 1 )) || rc=1
    fi
  fi
  if [[ -n "$mount_point" ]] && is_mounted "$mount_point"; then
    warn "FUSE mount remains active: ${mount_point}"
    rc=1
  fi
  if [[ -n "$mount_pid" ]] && pid_is_running "$mount_pid"; then
    warn "FUSE mount process remains active: pid=${mount_pid} mount=${mount_point}"
    rc=1
  fi
  if [[ "$mount_point" == "${ACTIVE_MOUNT_POINT:-}" ]] && (( rc == 0 )); then
    ACTIVE_MOUNT_POINT=""
    ACTIVE_MOUNT_PID=""
    ACTIVE_MOUNT_PGID=""
    ACTIVE_MOUNT_LOG=""
  fi
  return "$rc"
}

mounted_paths_under_root() {
  local root=$1 target output
  if ! output="$(findmnt -rn -o TARGET 2>/dev/null)"; then
    return 1
  fi
  while IFS= read -r target; do
    case "$target" in
      "$root"|"$root"/*) printf '%s\n' "$target" ;;
    esac
  done <<< "$output" | sort -r
}

processes_under_root() {
  local root=$1 pid args output
  if ! output="$(ps -eo pid=,args= 2>/dev/null)"; then
    return 1
  fi
  while read -r pid args; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    (( pid != $$ )) || continue
    case "$args" in
      *"$root"*) printf '%s\n' "$pid" ;;
    esac
  done <<< "$output"
}

cleanup_external_mounts() {
  local root=$1
  local target pid mount_output pid_output
  local rc=0
  local -a mount_points=() pids=() remaining_mounts=() remaining_pids=()

  # The mount can outlive the gate script even if the gate already removed its
  # temporary directory. Discover it by findmnt regardless of directory state.
  if ! mount_output="$(mounted_paths_under_root "$root")"; then
    warn "cannot inspect mounts under case root: ${root}"
    return 1
  fi
  if [[ -n "$mount_output" ]]; then
    mapfile -t mount_points <<< "$mount_output" || return 1
  fi
  for target in "${mount_points[@]}"; do
    [[ -n "$target" ]] || continue
    log "cleaning FUSE mount discovered under case root: ${target}"
    if [[ -n "${ACTIVE_TENANT_API_KEY:-}" ]]; then
      timeout --signal=TERM --kill-after="${MOUNT_STOP_TIMEOUT_S}s" "${DRIVE9_CLI_TIMEOUT_S}s" \
        env DRIVE9_SERVER="$DRIVE9_SERVER" DRIVE9_API_KEY="$ACTIVE_TENANT_API_KEY" \
        "$CLI" umount --timeout "$UMOUNT_TIMEOUT" "$target" >/dev/null 2>&1 || true
    fi
    if is_mounted "$target"; then
      terminate_mount_users "$target" || rc=1
      force_unmount_path "$target"
      wait_for_unmounted "$target" || true
    fi
    if is_mounted "$target"; then
      warn "FUSE mount remains after cleanup: ${target}"
      rc=1
    fi
  done

  if ! pid_output="$(processes_under_root "$root")"; then
    warn "cannot inspect processes under case root: ${root}"
    return 1
  fi
  if [[ -n "$pid_output" ]]; then
    mapfile -t pids <<< "$pid_output" || return 1
  fi
  for pid in "${pids[@]}"; do
    [[ -n "$pid" ]] || continue
    log "stopping FUSE-related process under case root: pid=${pid} root=${root}"
    kill -TERM "$pid" >/dev/null 2>&1 || true
  done
  if ((${#pids[@]} > 0)); then
    sleep 2
  fi
  if ! pid_output="$(processes_under_root "$root")"; then
    warn "cannot re-check processes under case root: ${root}"
    return 1
  fi
  remaining_pids=()
  if [[ -n "$pid_output" ]]; then
    mapfile -t remaining_pids <<< "$pid_output" || return 1
  fi
  for pid in "${remaining_pids[@]}"; do
    [[ -n "$pid" ]] || continue
    warn "force-stopping process under case root: pid=${pid} root=${root}"
    kill -KILL "$pid" >/dev/null 2>&1 || true
  done
  if ((${#remaining_pids[@]} > 0)); then
    sleep 1
  fi

  # A supervisor can recreate a worker after the first unmount attempt. Check
  # once more after process termination and only report success when findmnt is
  # clear.
  if ! mount_output="$(mounted_paths_under_root "$root")"; then
    warn "cannot perform final mount inspection under case root: ${root}"
    return 1
  fi
  remaining_mounts=()
  if [[ -n "$mount_output" ]]; then
    mapfile -t remaining_mounts <<< "$mount_output" || return 1
  fi
  for target in "${remaining_mounts[@]}"; do
    [[ -n "$target" ]] || continue
    terminate_mount_users "$target" || rc=1
    force_unmount_path "$target"
    wait_for_unmounted "$target" || true
    if is_mounted "$target"; then
      warn "FUSE mount still present after final cleanup: ${target}"
      rc=1
    fi
  done
  if ! pid_output="$(processes_under_root "$root")"; then
    warn "cannot perform final process inspection under case root: ${root}"
    return 1
  fi
  remaining_pids=()
  if [[ -n "$pid_output" ]]; then
    mapfile -t remaining_pids <<< "$pid_output" || return 1
  fi
  if ((${#remaining_pids[@]} > 0)); then
    warn "processes still reference case root after cleanup: ${remaining_pids[*]}"
    rc=1
  fi
  return "$rc"
}

wait_tenant_active() {
  local tenant_id=$1
  local api_key=$2
  local elapsed=0 response status_code body status message
  log "waiting for tenant to become active: ${tenant_id}"
  while (( elapsed <= TENANT_PROVISION_TIMEOUT_S )); do
    if response="$(curl_tenant_request "$api_key" GET "${DRIVE9_SERVER%/}/v1/status" "$TENANT_PROVISION_TIMEOUT_S")"; then
      parse_http_response "$response"
      status_code="$HTTP_STATUS_CODE"
      body="$HTTP_RESPONSE_BODY"
      if [[ "$status_code" == 200 ]]; then
        status="$(printf '%s' "$body" | jq -r '.status // empty' 2>/dev/null || true)"
        case "$status" in
          active)
            log "tenant active: ${tenant_id}"
            return 0
            ;;
          failed|suspended|deleted)
            message="$(printf '%s' "$body" | jq -r '.message // .error // empty' 2>/dev/null || true)"
            fail "tenant ${tenant_id} entered unexpected status ${status}: ${message}"
            ;;
        esac
      fi
    fi
    sleep "$TENANT_POLL_INTERVAL_S"
    elapsed=$((elapsed + TENANT_POLL_INTERVAL_S))
  done
  fail "tenant ${tenant_id} did not become active within ${TENANT_PROVISION_TIMEOUT_S}s"
}

create_case_tenant() {
  [[ -z "$ACTIVE_TENANT_ID" && -z "$ACTIVE_TENANT_API_KEY" ]] || \
    fail "cannot create a new case tenant while ${ACTIVE_TENANT_ID} is active"
  local response status_code body tenant_id api_key
  log 'provisioning isolated MySQL tenant for next benchmark case'
  response="$(curl --silent --show-error \
    --connect-timeout "$MYSQL_CONNECT_TIMEOUT_SECONDS" \
    --max-time "$TENANT_PROVISION_TIMEOUT_S" \
    --request POST \
    --write-out $'\n%{http_code}' \
    "${DRIVE9_SERVER%/}/v1/provision")"
  parse_http_response "$response"
  status_code="$HTTP_STATUS_CODE"
  body="$HTTP_RESPONSE_BODY"
  [[ "$status_code" =~ ^2[0-9][0-9]$ ]] || \
    fail "tenant provisioning failed with HTTP ${status_code}: ${body}"
  tenant_id="$(printf '%s' "$body" | jq -r '.tenant_id // empty' 2>/dev/null || true)"
  api_key="$(printf '%s' "$body" | jq -r '.api_key // empty' 2>/dev/null || true)"
  [[ -n "$tenant_id" && -n "$api_key" ]] || \
    fail "tenant provisioning response did not contain tenant_id/api_key: ${body}"
  [[ "$tenant_id" =~ ^[A-Za-z0-9._:-]+$ ]] || fail "unexpected tenant ID format: ${tenant_id}"
  ACTIVE_TENANT_ID="$tenant_id"
  ACTIVE_TENANT_API_KEY="$api_key"
  ACTIVE_TENANT_DELETE_REQUESTED=0
  ACTIVE_PROCESS_CLEANUP_FAILED=0
  log "isolated tenant provisioned: ${ACTIVE_TENANT_ID}"
  wait_tenant_active "$ACTIVE_TENANT_ID" "$ACTIVE_TENANT_API_KEY"
}

tenant_delete_state() {
  local tenant_id=$1
  local tenant_literal
  tenant_literal="$(sql_quote "$tenant_id")"
  mysql_meta_sql -e "SELECT CONCAT(
    COALESCE(t.status, 'missing'), '|',
    COALESCE(ns.state, 'none'), '|',
    COALESCE(j.state, 'none'), '|',
    COALESCE(j.deleted_objects, 0), '|',
    COALESCE((SELECT COUNT(*) FROM object_gc_candidates og WHERE og.namespace_id = ns.namespace_id), 0)
  )
  FROM tenants t
  LEFT JOIN storage_namespaces ns ON ns.namespace_id = t.storage_namespace_id
  LEFT JOIN tenant_delete_jobs j ON j.tenant_id = t.id
  WHERE t.id = ${tenant_literal}"
}

wait_tenant_deleted() {
  local tenant_id=$1
  local elapsed=0 row status ns_state job_state deleted_objects gc_rows
  log "waiting for tenant deletion and namespace object GC: ${tenant_id}"
  while (( elapsed <= TENANT_DELETE_TIMEOUT_S )); do
    if row="$(tenant_delete_state "$tenant_id" 2>/dev/null)"; then
      IFS='|' read -r status ns_state job_state deleted_objects gc_rows <<< "$row"
      if [[ "$status" == deleted && ( "$ns_state" == deleted || "$ns_state" == none ) && ( "$job_state" == deleted || "$job_state" == none ) ]]; then
        log "tenant deletion complete: ${tenant_id}; DeletePrefix_objects_deleted=${deleted_objects:-0}; residual_gc_rows_before_metadata_purge=${gc_rows:-0}"
        return 0
      fi
      log "tenant cleanup pending: id=${tenant_id} status=${status:-unknown} namespace=${ns_state:-unknown} job=${job_state:-unknown}"
    else
      warn "unable to query tenant deletion state yet: ${tenant_id}"
    fi
    sleep "$TENANT_POLL_INTERVAL_S"
    elapsed=$((elapsed + TENANT_POLL_INTERVAL_S))
  done
  warn "tenant ${tenant_id} deletion/object GC did not complete within ${TENANT_DELETE_TIMEOUT_S}s"
  return 1
}

metadata_tables_with_column() {
  local column=$1
  local column_literal
  column_literal="$(sql_quote "$column")"
  mysql_meta_sql -e "SELECT DISTINCT c.table_name
    FROM information_schema.columns c
    JOIN information_schema.tables t
      ON t.table_schema = c.table_schema AND t.table_name = c.table_name
    WHERE c.table_schema = DATABASE()
      AND c.column_name = ${column_literal}
      AND t.table_type = 'BASE TABLE'
    ORDER BY c.table_name"
}

purge_rows_by_metadata_column() {
  local column=$1
  local value_literal=$2
  local column_identifier table table_identifier tables
  column_identifier="$(sql_identifier "$column")"
  tables="$(metadata_tables_with_column "$column")" || return 1
  while IFS= read -r table; do
    [[ -n "$table" ]] || continue
    [[ "$table" =~ ^[A-Za-z0-9_]+$ ]] || return 1
    table_identifier="$(sql_identifier "$table")"
    mysql_meta_sql -e "DELETE FROM ${table_identifier} WHERE ${column_identifier} = ${value_literal}" || return 1
  done <<< "$tables"
}

count_rows_by_metadata_column() {
  local column=$1
  local value_literal=$2
  local column_identifier table table_identifier tables count total=0
  column_identifier="$(sql_identifier "$column")"
  tables="$(metadata_tables_with_column "$column")" || return 1
  while IFS= read -r table; do
    [[ -n "$table" ]] || continue
    [[ "$table" =~ ^[A-Za-z0-9_]+$ ]] || return 1
    table_identifier="$(sql_identifier "$table")"
    count="$(mysql_meta_sql -e "SELECT COUNT(*) FROM ${table_identifier} WHERE ${column_identifier} = ${value_literal}")" || return 1
    [[ "$count" =~ ^[0-9]+$ ]] || return 1
    total=$((total + count))
  done <<< "$tables"
  printf '%s\n' "$total"
}

purge_case_tenant_metadata() {
  local tenant_id=$1
  local tenant_literal namespace_ids namespace_id namespace_literal
  local remaining_tenant remaining_tenant_id remaining_parent remaining_source remaining_owner remaining_namespace remaining_storage remaining_gc count
  tenant_literal="$(sql_quote "$tenant_id")"
  namespace_ids="$(mysql_meta_sql -e "SELECT namespace_id FROM storage_namespaces WHERE owner_tenant_id = ${tenant_literal}")" || return 1

  # The official tenant-delete job has already completed DeletePrefix. Any
  # remaining candidate belongs to this deleted namespace and must not be left
  # for the normal worker, which intentionally postpones candidates owned by a
  # non-active tenant. DeletePrefix already removed the physical object.
  while IFS= read -r namespace_id; do
    [[ -n "$namespace_id" ]] || continue
    namespace_literal="$(sql_quote "$namespace_id")"
    mysql_meta_sql -e "DELETE FROM object_gc_candidates WHERE namespace_id = ${namespace_literal}" || return 1
  done <<< "$namespace_ids"

  # Remove every central row carrying exact tenant ownership. Table names come
  # from information_schema and are identifier-quoted; all values are bound as
  # escaped SQL literals, so no caller-controlled SQL is executed.
  purge_rows_by_metadata_column tenant_id "$tenant_literal" || return 1
  purge_rows_by_metadata_column parent_tenant_id "$tenant_literal" || return 1
  purge_rows_by_metadata_column source_tenant_id "$tenant_literal" || return 1
  purge_rows_by_metadata_column owner_tenant_id "$tenant_literal" || return 1
  while IFS= read -r namespace_id; do
    [[ -n "$namespace_id" ]] || continue
    namespace_literal="$(sql_quote "$namespace_id")"
    purge_rows_by_metadata_column namespace_id "$namespace_literal" || return 1
    purge_rows_by_metadata_column storage_namespace_id "$namespace_literal" || return 1
  done <<< "$namespace_ids"
  mysql_meta_sql -e "DELETE FROM tenants WHERE id = ${tenant_literal}" || return 1

  # Verify that no metadata or object-GC candidate remains for this case. This
  # is deliberately strict: the next parameter case must not inherit central
  # rows, namespace rows, delete jobs, or deferred object-GC work.
  remaining_tenant_id="$(mysql_meta_sql -e "SELECT COUNT(*) FROM tenants WHERE id = ${tenant_literal}")" || return 1
  remaining_tenant="$(count_rows_by_metadata_column tenant_id "$tenant_literal")" || return 1
  remaining_parent="$(count_rows_by_metadata_column parent_tenant_id "$tenant_literal")" || return 1
  remaining_source="$(count_rows_by_metadata_column source_tenant_id "$tenant_literal")" || return 1
  remaining_owner="$(count_rows_by_metadata_column owner_tenant_id "$tenant_literal")" || return 1
  remaining_namespace=0
  remaining_storage=0
  remaining_gc=0
  while IFS= read -r namespace_id; do
    [[ -n "$namespace_id" ]] || continue
    namespace_literal="$(sql_quote "$namespace_id")"
    count="$(count_rows_by_metadata_column namespace_id "$namespace_literal")" || return 1
    remaining_namespace=$((remaining_namespace + count))
    count="$(count_rows_by_metadata_column storage_namespace_id "$namespace_literal")" || return 1
    remaining_storage=$((remaining_storage + count))
    count="$(mysql_meta_sql -e "SELECT COUNT(*) FROM object_gc_candidates WHERE namespace_id = ${namespace_literal}")" || return 1
    [[ "$count" =~ ^[0-9]+$ ]] || return 1
    remaining_gc=$((remaining_gc + count))
  done <<< "$namespace_ids"
  if (( remaining_tenant_id + remaining_tenant + remaining_parent + remaining_source + remaining_owner + remaining_namespace + remaining_storage + remaining_gc != 0 )); then
    warn "tenant metadata purge incomplete: tenant=${tenant_id} tenants=${remaining_tenant_id} parent_rows=${remaining_parent} tenant_column_rows=${remaining_tenant} source_rows=${remaining_source} owner_rows=${remaining_owner} namespace_rows=${remaining_namespace} storage_namespace_rows=${remaining_storage} object_gc_rows=${remaining_gc}"
    return 1
  fi
  log "benchmark tenant metadata purged and object-GC work drained: ${tenant_id}"
}

delete_case_tenant() {
  [[ -n "$ACTIVE_TENANT_ID" ]] || return 0
  local tenant_id="$ACTIVE_TENANT_ID"
  local api_key="$ACTIVE_TENANT_API_KEY"
  local response status_code body
  if ! is_true "$ACTIVE_TENANT_DELETE_REQUESTED"; then
    log "requesting deletion of benchmark tenant: ${tenant_id}"
    if [[ -n "$api_key" ]]; then
      ACTIVE_TENANT_DELETE_REQUESTED=1
      if ! response="$(curl_tenant_request "$api_key" DELETE "${DRIVE9_SERVER%/}/v1/tenant" "$TENANT_DELETE_TIMEOUT_S")"; then
        ACTIVE_TENANT_DELETE_REQUESTED=0
        warn "tenant deletion request could not be completed: tenant=${tenant_id}"
        return 1
      fi
      if [[ -z "$response" ]]; then
        ACTIVE_TENANT_DELETE_REQUESTED=0
        warn "tenant deletion request returned no response: tenant=${tenant_id}"
        return 1
      fi
      parse_http_response "$response"
      status_code="$HTTP_STATUS_CODE"
      body="$HTTP_RESPONSE_BODY"
      if [[ ! "$status_code" =~ ^2[0-9][0-9]$ && "$status_code" != 404 ]]; then
        ACTIVE_TENANT_DELETE_REQUESTED=0
        warn "tenant deletion request failed: tenant=${tenant_id} http=${status_code} body=${body}"
        return 1
      fi
    else
      warn "tenant ${tenant_id} has no API key; cannot request official deletion"
      return 1
    fi
  else
    log "tenant deletion was already requested; resuming cleanup: ${tenant_id}"
  fi
  wait_tenant_deleted "$tenant_id"
  purge_case_tenant_metadata "$tenant_id" || return 1
  ACTIVE_TENANT_ID=""
  ACTIVE_TENANT_API_KEY=""
  ACTIVE_TENANT_DELETE_REQUESTED=0
  ACTIVE_PROCESS_CLEANUP_FAILED=0
  return 0
}

begin_case_tenant() {
  cleanup_active || return 1
  if [[ -n "$ACTIVE_TENANT_ID" ]]; then
    warn "cannot start a new case while tenant cleanup is incomplete: ${ACTIVE_TENANT_ID}"
    return 1
  fi
  create_case_tenant
}

finalize_case_after_tenant_delete() {
  local rc=0

  # Tenant deletion is authoritative for remote namespace, layer and object
  # data. Clear those handles before removing local artifacts so a retry cannot
  # accidentally issue Drive9 commands without an active tenant key.
  ACTIVE_REMOTE_ROOT=""
  ACTIVE_LAYER_ID=""
  if [[ -n "${ACTIVE_CASE_DIR:-}" ]]; then
    rm -rf -- "$ACTIVE_CASE_DIR" >/dev/null 2>&1 || rc=1
  fi
  if [[ -n "${ACTIVE_EXTRA_CASE_DIR:-}" && "${ACTIVE_EXTRA_CASE_DIR}" != "${ACTIVE_CASE_DIR:-}" ]]; then
    rm -rf -- "$ACTIVE_EXTRA_CASE_DIR" >/dev/null 2>&1 || rc=1
  fi
  if (( rc == 0 )); then
    ACTIVE_MOUNT_POINT=""
    ACTIVE_MOUNT_PID=""
    ACTIVE_MOUNT_PGID=""
    ACTIVE_MOUNT_LOG=""
    ACTIVE_CACHE_DIR=""
    ACTIVE_LOCAL_ROOT=""
    ACTIVE_CASE_DIR=""
    ACTIVE_EXTRA_CASE_DIR=""
    ACTIVE_PROCESS_CLEANUP_FAILED=0
  fi
  return "$rc"
}

end_case_tenant() {
  local cleanup_rc=0
  cleanup_active || cleanup_rc=1
  if [[ -n "$ACTIVE_TENANT_ID" ]]; then
    if (( ACTIVE_PROCESS_CLEANUP_FAILED == 0 )); then
      delete_case_tenant || cleanup_rc=1
      if [[ -z "$ACTIVE_TENANT_ID" ]]; then
        finalize_case_after_tenant_delete || cleanup_rc=1
      fi
    else
      warn "not deleting tenant until process/FUSE cleanup succeeds: ${ACTIVE_TENANT_ID}"
      cleanup_rc=1
    fi
  fi
  return "$cleanup_rc"
}

cleanup_active() {
  local rc=0 process_rc=0
  ACTIVE_PROCESS_CLEANUP_FAILED=0

  if [[ -n "${ACTIVE_CHILD_PID:-}" ]]; then
    if ! stop_active_child; then
      rc=1
      process_rc=1
    fi
  fi
  if [[ -n "${ACTIVE_MOUNT_POINT:-}" || -n "${ACTIVE_MOUNT_PID:-}" ]]; then
    if ! stop_mount; then
      rc=1
      process_rc=1
    fi
  fi
  if [[ -n "${ACTIVE_CASE_DIR:-}" ]]; then
    if ! cleanup_external_mounts "$ACTIVE_CASE_DIR"; then
      rc=1
      process_rc=1
    fi
  fi
  if [[ -n "${ACTIVE_EXTRA_CASE_DIR:-}" ]]; then
    if ! cleanup_external_mounts "$ACTIVE_EXTRA_CASE_DIR"; then
      rc=1
      process_rc=1
    fi
  fi

  # Never remove remote state or delete the tenant while any FUSE client or
  # child benchmark still references this case. Preserve the case directory so
  # a later cleanup pass can retry and the failure remains diagnosable.
  if (( process_rc != 0 )); then
    ACTIVE_PROCESS_CLEANUP_FAILED=1
    warn 'case process or FUSE mount cleanup is incomplete; refusing remote/tenant deletion'
    return 1
  fi

  if [[ -n "${ACTIVE_LAYER_ID:-}" ]]; then
    if ! drive9 fs layer rollback "$ACTIVE_LAYER_ID" >/dev/null 2>&1; then
      warn "LayerFS rollback failed: ${ACTIVE_LAYER_ID}"
      rc=1
    fi
    if drive9 fs layer delete "$ACTIVE_LAYER_ID" >/dev/null 2>&1; then
      ACTIVE_LAYER_ID=""
    elif drive9 fs layer delete --cascade "$ACTIVE_LAYER_ID" >/dev/null 2>&1; then
      ACTIVE_LAYER_ID=""
    else
      warn "LayerFS delete failed: ${ACTIVE_LAYER_ID}"
      rc=1
    fi
  fi
  if [[ -n "${ACTIVE_REMOTE_ROOT:-}" ]]; then
    if drive9 fs rm -r ":${ACTIVE_REMOTE_ROOT}" >/dev/null 2>&1; then
      ACTIVE_REMOTE_ROOT=""
    else
      warn "remote case root cleanup failed; tenant deletion will be authoritative: ${ACTIVE_REMOTE_ROOT}"
      rc=1
    fi
  fi

  if (( rc == 0 )) && [[ -n "${ACTIVE_CASE_DIR:-}" ]]; then
    if ! rm -rf -- "$ACTIVE_CASE_DIR" >/dev/null 2>&1; then
      warn "local case directory cleanup failed: ${ACTIVE_CASE_DIR}"
      rc=1
    fi
  fi
  if (( rc == 0 )); then
    ACTIVE_MOUNT_POINT=""
    ACTIVE_MOUNT_PID=""
    ACTIVE_MOUNT_PGID=""
    ACTIVE_MOUNT_LOG=""
    ACTIVE_CACHE_DIR=""
    ACTIVE_LOCAL_ROOT=""
    ACTIVE_CASE_DIR=""
    ACTIVE_EXTRA_CASE_DIR=""
  fi
  return "$rc"
}

cleanup_all() {
  local rc=$?
  local cleanup_rc=0
  trap - EXIT INT TERM
  set +e
  stop_active_child || cleanup_rc=1
  cleanup_active || cleanup_rc=1
  if [[ -n "$ACTIVE_TENANT_ID" ]]; then
    if (( ACTIVE_PROCESS_CLEANUP_FAILED == 0 )); then
      delete_case_tenant || cleanup_rc=1
      if [[ -z "$ACTIVE_TENANT_ID" ]]; then
        finalize_case_after_tenant_delete || cleanup_rc=1
      fi
    else
      warn "not deleting tenant until process/FUSE cleanup succeeds: ${ACTIVE_TENANT_ID}"
      cleanup_rc=1
    fi
  fi
  if [[ -n "$ACTIVE_TENANT_ID" ]]; then
    warn "tenant remains for manual cleanup because case cleanup did not complete: ${ACTIVE_TENANT_ID}"
    cleanup_rc=1
  fi
  (( rc == 0 && cleanup_rc != 0 )) && rc=1
  exit "$rc"
}

trap cleanup_all EXIT
trap 'exit 130' INT TERM

start_mount() {
  local scenario=$1
  local profile=$2
  local remote_root=$3
  local mount_point=$4
  local cache_dir=$5
  local local_root=$6
  local layer_id=${7:-}
  local log_file="${LOG_DIR}/mount-${scenario}-$(date -u +%Y%m%dT%H%M%S)-$$.log"
  local -a args
  local pid

  mkdir -p -- "$mount_point" "$cache_dir"
  if [[ "$profile" != none ]]; then
    mkdir -p -- "$local_root"
  fi

  args=(
    "$CLI" mount
    --foreground
    --mode=fuse
    --profile "$profile"
    --durability write-sync
    --flush-debounce 0
    --read-cache-ttl 1s
    --cache-dir "$cache_dir"
  )
  if [[ "$profile" != none ]]; then
    args+=(--local-root "$local_root")
  fi
  if [[ -n "$layer_id" ]]; then
    args+=(--layer "$layer_id")
  fi
  args+=(":${remote_root}" "$mount_point")

  log "starting FUSE mount: scenario=${scenario} remote=${remote_root} mount=${mount_point} tenant=${ACTIVE_TENANT_ID}"
  DRIVE9_SERVER="$DRIVE9_SERVER" DRIVE9_API_KEY="$ACTIVE_TENANT_API_KEY" \
    nohup setsid "${args[@]}" >"$log_file" 2>&1 &
  pid=$!

  ACTIVE_MOUNT_POINT="$mount_point"
  ACTIVE_MOUNT_PID="$pid"
  ACTIVE_MOUNT_PGID="$pid"
  ACTIVE_MOUNT_LOG="$log_file"
  ACTIVE_CACHE_DIR="$cache_dir"
  ACTIVE_LOCAL_ROOT="$local_root"

  for _ in $(seq 1 "$MOUNT_READY_TIMEOUT_S"); do
    if is_mounted "$mount_point"; then
      log "FUSE mount ready: ${mount_point} (pid=${pid})"
      return 0
    fi
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      tail -n 120 -- "$log_file" >&2 || true
      return 1
    fi
    sleep 1
  done
  tail -n 120 -- "$log_file" >&2 || true
  return 1
}

create_layer() {
  local remote_root=$1
  local layer_name=$2
  local layer_json
  layer_json="$(drive9 fs layer create --name "$layer_name" --durability restore-safe --json ":${remote_root}")"
  ACTIVE_LAYER_ID="$(printf '%s' "$layer_json" | jq -r '.layer_id // empty')"
  [[ -n "$ACTIVE_LAYER_ID" ]] || fail "layer create returned no layer_id: ${layer_json}"
  log "LayerFS layer created: ${ACTIVE_LAYER_ID}"
}

prepare_git_workspace() {
  local repo_root="${ACTIVE_MOUNT_POINT}/repo"
  local fixture_root="${ACTIVE_CASE_DIR}/git-fixture"
  local fixture_json file_url bare_repo

  [[ ! -e "$repo_root" ]] || fail "Git workspace target already exists: ${repo_root}"
  log "creating local Git fixture: ${fixture_root} (tree_files=${GIT_FIO_FIXTURE_TREE_FILES})"
  fixture_json="$(python3 "${ROOT_DIR}/e2e/tools/git_fixture.py" "$fixture_root" \
    --tree-files "$GIT_FIO_FIXTURE_TREE_FILES")"
  file_url="$(printf '%s' "$fixture_json" | jq -er '.file_url | select(startswith("file://"))')"
  bare_repo="$(printf '%s' "$fixture_json" | jq -er '.bare_repo')"
  log "cloning local fixture into Drive9 Git workspace: ${bare_repo} -> ${repo_root}"
  GIT_TERMINAL_PROMPT=0 drive9 git clone --fast "$file_url" "$repo_root"
  git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null
  log "Drive9 Git workspace ready: ${repo_root}"
}

fio_block_bytes() {
  local file_size_bytes=$1
  local requested_bytes=$2
  if (( file_size_bytes < requested_bytes )); then
    printf '%s' "$file_size_bytes"
  else
    printf '%s' "$requested_bytes"
  fi
}

split_total_count() {
  local total=$1
  local workers=$2
  [[ "$total" =~ ^[0-9]+$ && "$workers" =~ ^[0-9]+$ && "$total" -gt 0 && "$workers" -gt 0 ]] || \
    fail "total and worker counts must be positive integers: total=${total} workers=${workers}"
  # fio and mdtest apply their file/item count per worker/rank. Round up so
  # the workload never undershoots the requested total; the overshoot is at
  # most workers-1 and is recorded in the result metadata.
  printf '%s' "$(((total + workers - 1) / workers))"
}

summarize_fio_result() {
  local raw_file=$1
  local summary_file=$2
  local scenario=$3
  local case_id=$4
  local phase=$5
  local workload=$6
  local file_size_bytes=$7
  local num_jobs=$8
  local files_per_job=$9
  local total_files=${10}
  local run_index=${11}

  python3 - "$raw_file" "$summary_file" "$scenario" "$case_id" "$phase" "$workload" \
    "$file_size_bytes" "$num_jobs" "$files_per_job" "$total_files" "$run_index" <<'PY'
import json
import pathlib
import sys

raw_path = pathlib.Path(sys.argv[1])
summary_path = pathlib.Path(sys.argv[2])
scenario = sys.argv[3]
case_id = sys.argv[4]
phase = sys.argv[5]
workload = sys.argv[6]
file_size_bytes = int(sys.argv[7])
num_jobs = int(sys.argv[8])
files_per_job = int(sys.argv[9])
total_files = int(sys.argv[10])
run_index = int(sys.argv[11])

data = json.loads(raw_path.read_text(encoding="utf-8"))
jobs = data.get("jobs") or []
if not jobs:
    raise SystemExit(f"fio result has no jobs: {raw_path}")


def number(value):
    try:
        return float(value or 0)
    except (TypeError, ValueError):
        return 0.0


def metric(stat_name):
    return {
        "io_bytes": sum(number(job.get(stat_name, {}).get("io_bytes")) for job in jobs),
        "bw_bytes": sum(number(job.get(stat_name, {}).get("bw_bytes")) for job in jobs),
        "iops": sum(number(job.get(stat_name, {}).get("iops")) for job in jobs),
    }

if workload == "rand_rw":
    read = metric("read")
    write = metric("write")
    io_bytes = read["io_bytes"] + write["io_bytes"]
    bw_bytes = read["bw_bytes"] + write["bw_bytes"]
    iops = read["iops"] + write["iops"]
else:
    direction = "read" if workload == "seq_read" or workload == "rand_read" else "write"
    stats = metric(direction)
    io_bytes = stats["io_bytes"]
    bw_bytes = stats["bw_bytes"]
    iops = stats["iops"]

runtime_ms = max(number(job.get("job_runtime")) for job in jobs)
percentiles = {}
for percentile in ("50.000000", "95.000000", "99.000000"):
    values = []
    for job in jobs:
        for stat_name in ("read", "write"):
            value = job.get(stat_name, {}).get("clat_ns", {}).get("percentile", {}).get(percentile)
            if value is not None:
                values.append(number(value) / 1_000_000)
    if values:
        percentiles[f"p{percentile.split('.')[0]}_ms_job_average"] = round(sum(values) / len(values), 3)

summary = {
    "scenario": scenario,
    "case_id": case_id,
    "phase": phase,
    "workload": workload,
    "file_size_bytes": file_size_bytes,
    "num_jobs": num_jobs,
    "files_per_job": files_per_job,
    "total_files_requested": total_files,
    "total_files_actual": num_jobs * files_per_job,
    "run": run_index,
    "fio_jobs": len(jobs),
    "io_bytes": int(io_bytes),
    "bandwidth_mib_s": round(bw_bytes / (1024 * 1024), 3),
    "iops": round(iops, 3),
    "runtime_ms": round(runtime_ms, 3),
    "latency_percentiles_ms": percentiles,
    "raw_result": str(raw_path),
}
summary_path.parent.mkdir(parents=True, exist_ok=True)
summary_path.write_text(json.dumps(summary, sort_keys=True) + "\n", encoding="utf-8")
print(json.dumps(summary, sort_keys=True))
PY
}

run_fio_workload() {
  local scenario=$1
  local case_id=$2
  local phase=$3
  local workload=$4
  local fio_root=$5
  local file_size_bytes=$6
  local num_jobs=$7
  local total_files=$8
  local run_index=$9
  local result_root=${10}
  local timeout_seconds=${11}
  local dataset rw block_bytes sync_option="" raw_file summary_file data_dir fio_job_name command_name
  local readonly_mode=0
  local existing_files_mode=0
  local precreate_files=0
  local fio_rc=0
  local precreate_raw_file precreate_command_name precreate_index
  local files_per_job total_bytes effective_timeout
  files_per_job="$(split_total_count "$total_files" "$num_jobs")"
  local -a args precreate_args

  case "$workload" in
    seq_write)
      dataset=seq
      rw=write
      block_bytes="$(fio_block_bytes "$file_size_bytes" "$FIO_SEQ_BS_BYTES")"
      ;;
    seq_read)
      dataset=seq
      rw=read
      block_bytes="$(fio_block_bytes "$file_size_bytes" "$FIO_SEQ_BS_BYTES")"
      readonly_mode=1
      ;;
    rand_write)
      dataset=rand
      rw=randwrite
      block_bytes="$(fio_block_bytes "$file_size_bytes" "$FIO_RANDOM_BS_BYTES")"
      ;;
    rand_read)
      dataset=rand
      rw=randread
      block_bytes="$(fio_block_bytes "$file_size_bytes" "$FIO_RANDOM_BS_BYTES")"
      readonly_mode=1
      ;;
    rand_rw)
      dataset=mixed
      rw=randrw
      block_bytes="$(fio_block_bytes "$file_size_bytes" "$FIO_RANDOM_BS_BYTES")"
      existing_files_mode=1
      # randrw may issue a read before its first write. Pre-create and size all
      # files so a random first read cannot hit EOF and become fio EIO.
      if (( run_index == 1 )); then
        precreate_files=1
      fi
      ;;
    fsync_write)
      dataset=fsync
      rw=write
      block_bytes="$(fio_block_bytes "$file_size_bytes" "$FIO_RANDOM_BS_BYTES")"
      sync_option=--fsync=1
      ;;
    fdatasync_write)
      dataset=fdatasync
      rw=write
      block_bytes="$(fio_block_bytes "$file_size_bytes" "$FIO_RANDOM_BS_BYTES")"
      sync_option=--fdatasync=1
      ;;
    *)
      fail "unsupported fio workload: ${workload}"
      ;;
  esac

  total_bytes=$((file_size_bytes * files_per_job))
  data_dir="${fio_root}/${dataset}"
  raw_file="${result_root}/${phase}/${workload}-run${run_index}.json"
  summary_file="${result_root}/${phase}/${workload}-run${run_index}.summary.json"
  fio_job_name="fio-${case_id}-${dataset}"
  command_name="fio-${case_id}-${phase}-${workload}-run${run_index}"
  mkdir -p -- "$data_dir" "${result_root}/${phase}"

  args=(
    "$FIO_BIN"
    "--name=${fio_job_name}"
    "--directory=${data_dir}"
    "--filename_format=${fio_job_name}.\$jobnum.\$filenum"
    "--rw=${rw}"
    "--bs=${block_bytes}B"
    "--size=${total_bytes}B"
    "--filesize=${file_size_bytes}B"
    "--nrfiles=${files_per_job}"
    "--numjobs=${num_jobs}"
    "--ioengine=sync"
    "--iodepth=1"
    --thread
    --direct=0
    --group_reporting
    --randrepeat=0
    --output-format=json
    "--output=${raw_file}"
  )
  if (( precreate_files == 1 )); then
    precreate_raw_file="${result_root}/${phase}/${workload}-run${run_index}.precreate.json"
    precreate_command_name="${command_name}-precreate"
    precreate_args=("${args[@]}")
    for precreate_index in "${!precreate_args[@]}"; do
      if [[ "${precreate_args[$precreate_index]}" == --output=* ]]; then
        precreate_args[$precreate_index]="--output=${precreate_raw_file}"
        break
      fi
    done
    precreate_args+=(--create_only=1 --create_on_open=0 --allow_file_create=1)
    effective_timeout="$(case_timeout_remaining "$timeout_seconds")" || return $?
    log "fio precreate: scenario=${scenario} workload=${workload} files=${num_jobs}x${files_per_job} run=${run_index} timeout=${effective_timeout}s"
    if run_nohup "$precreate_command_name" "$effective_timeout" "${precreate_args[@]}"; then
      :
    else
      fio_rc=$?
      warn "fio precreate failed: ${precreate_command_name}, exit=${fio_rc}"
      if [[ -s "$precreate_raw_file" ]]; then
        warn "fio precreate result: ${precreate_raw_file}"
        sed -n '1,24p' -- "$precreate_raw_file" >&2 || true
      fi
      return "$fio_rc"
    fi
  fi
  if (( existing_files_mode == 1 || readonly_mode == 1 )); then
    args+=(--create_on_open=0 --allow_file_create=0)
  else
    args+=(--create_on_open=1)
  fi
  [[ -n "$sync_option" ]] && args+=("$sync_option")
  [[ "$workload" == rand_rw ]] && args+=(--rwmixread=50)

  effective_timeout="$(case_timeout_remaining "$timeout_seconds")" || return $?
  log "fio: scenario=${scenario} phase=${phase} workload=${workload} size=${file_size_bytes}B jobs=${num_jobs} total_files=${total_files} files_per_job=${files_per_job} actual_files=$((num_jobs * files_per_job)) run=${run_index} timeout=${effective_timeout}s"
  if run_nohup "$command_name" "$effective_timeout" "${args[@]}"; then
    :
  else
    fio_rc=$?
    warn "fio workload failed: ${command_name}, exit=${fio_rc}"
    if [[ -s "$raw_file" ]]; then
      warn "fio result: ${raw_file}"
      sed -n '1,24p' -- "$raw_file" >&2 || true
    fi
    return "$fio_rc"
  fi
  summarize_fio_result "$raw_file" "$summary_file" "$scenario" "$case_id" "$phase" "$workload" \
    "$file_size_bytes" "$num_jobs" "$files_per_job" "$total_files" "$run_index" >/dev/null || return $?
}

summarize_fio_matrix() {
  local result_root=$1
  local summary_file=$2
  local scenario=$3
  local case_id=$4
  local file_size_bytes=$5
  local num_jobs=$6
  local total_files=$7

  python3 - "$result_root" "$summary_file" "$scenario" "$case_id" "$file_size_bytes" "$num_jobs" "$total_files" <<'PY'
import json
import math
import pathlib
import statistics
import sys

result_root = pathlib.Path(sys.argv[1])
summary_path = pathlib.Path(sys.argv[2])
scenario = sys.argv[3]
case_id = sys.argv[4]
file_size_bytes = int(sys.argv[5])
num_jobs = int(sys.argv[6])
total_files = int(sys.argv[7])

records = []
for path in sorted(result_root.glob("*/*.summary.json")):
    data = json.loads(path.read_text(encoding="utf-8"))
    bandwidth = float(data.get("bandwidth_mib_s", 0.0))
    iops = float(data.get("iops", 0.0))
    if not math.isfinite(bandwidth) or not math.isfinite(iops):
        raise SystemExit(f"fio summary contains non-finite metrics: {path}")
    records.append({
        "phase": data.get("phase"),
        "workload": data.get("workload"),
        "run": data.get("run"),
        "bandwidth_mib_s": bandwidth,
        "iops": iops,
        "path": str(path),
    })

if not records:
    raise SystemExit(f"no fio summaries found below {result_root}")

phases = {}
for phase in sorted({record["phase"] for record in records}):
    phase_records = [record for record in records if record["phase"] == phase]
    peak_bandwidth = max(phase_records, key=lambda record: record["bandwidth_mib_s"])
    peak_iops = max(phase_records, key=lambda record: record["iops"])
    by_workload = {}
    for workload in sorted({record["workload"] for record in phase_records}):
        workload_records = [record for record in phase_records if record["workload"] == workload]
        by_workload[workload] = {
            "runs": len(workload_records),
            "bandwidth_mib_s": {
                "max": max(record["bandwidth_mib_s"] for record in workload_records),
                "median": statistics.median(record["bandwidth_mib_s"] for record in workload_records),
            },
            "iops": {
                "max": max(record["iops"] for record in workload_records),
                "median": statistics.median(record["iops"] for record in workload_records),
            },
        }
    phases[phase] = {
        "peak_bandwidth_mib_s": peak_bandwidth["bandwidth_mib_s"],
        "peak_bandwidth_workload": peak_bandwidth["workload"],
        "peak_bandwidth_run": peak_bandwidth["run"],
        "peak_iops": peak_iops["iops"],
        "peak_iops_workload": peak_iops["workload"],
        "peak_iops_run": peak_iops["run"],
        "workloads": by_workload,
    }

summary = {
    "scenario": scenario,
    "case_id": case_id,
    "file_size_bytes": file_size_bytes,
    "num_jobs": num_jobs,
    "total_files_requested": total_files,
    "total_files_actual": num_jobs * math.ceil(total_files / num_jobs),
    "phases": phases,
    "source_summaries": len(records),
}
summary_path.parent.mkdir(parents=True, exist_ok=True)
summary_path.write_text(json.dumps(summary, sort_keys=True) + "\n", encoding="utf-8")
print(json.dumps(summary, sort_keys=True))
PY
}

run_fio_write_phase() {
  local scenario=$1
  local case_id=$2
  local fio_root=$3
  local file_size_bytes=$4
  local num_jobs=$5
  local total_files=$6
  local result_root=$7
  local timeout_seconds=$8
  local run_index

  for run_index in $(seq 1 "$FIO_RUNS"); do
    run_fio_workload "$scenario" "$case_id" write seq_write "$fio_root" "$file_size_bytes" "$num_jobs" "$total_files" "$run_index" "$result_root" "$timeout_seconds" || return $?
    run_fio_workload "$scenario" "$case_id" write rand_write "$fio_root" "$file_size_bytes" "$num_jobs" "$total_files" "$run_index" "$result_root" "$timeout_seconds" || return $?
    run_fio_workload "$scenario" "$case_id" write rand_rw "$fio_root" "$file_size_bytes" "$num_jobs" "$total_files" "$run_index" "$result_root" "$timeout_seconds" || return $?
    run_fio_workload "$scenario" "$case_id" write fsync_write "$fio_root" "$file_size_bytes" "$num_jobs" "$total_files" "$run_index" "$result_root" "$timeout_seconds" || return $?
    run_fio_workload "$scenario" "$case_id" write fdatasync_write "$fio_root" "$file_size_bytes" "$num_jobs" "$total_files" "$run_index" "$result_root" "$timeout_seconds" || return $?
  done
}

run_fio_read_phase() {
  local scenario=$1
  local case_id=$2
  local fio_root=$3
  local file_size_bytes=$4
  local num_jobs=$5
  local total_files=$6
  local result_root=$7
  local timeout_seconds=$8
  local run_index

  for run_index in $(seq 1 "$FIO_RUNS"); do
    run_fio_workload "$scenario" "$case_id" read seq_read "$fio_root" "$file_size_bytes" "$num_jobs" "$total_files" "$run_index" "$result_root" "$timeout_seconds" || return $?
    run_fio_workload "$scenario" "$case_id" read rand_read "$fio_root" "$file_size_bytes" "$num_jobs" "$total_files" "$run_index" "$result_root" "$timeout_seconds" || return $?
  done
}

summarize_mdtest_result() {
  local raw_file=$1
  local summary_file=$2
  local scenario=$3
  local case_id=$4
  local mode=$5
  local num_procs=$6
  local entries_per_rank=$7
  local total_entries=$8
  local iterations=$9

  python3 - "$raw_file" "$summary_file" "$scenario" "$case_id" "$mode" "$num_procs" "$entries_per_rank" "$total_entries" "$iterations" <<'PY'
import json
import math
import pathlib
import re
import sys

raw_path = pathlib.Path(sys.argv[1])
summary_path = pathlib.Path(sys.argv[2])
scenario = sys.argv[3]
case_id = sys.argv[4]
mode = sys.argv[5]
num_procs = int(sys.argv[6])
entries_per_rank = int(sys.argv[7])
total_entries = int(sys.argv[8])
iterations = int(sys.argv[9])

line_pattern = re.compile(
    r"^\s*(Directory creation|Directory stat|Directory removal|File creation|File stat|File read|File removal|Tree creation|Tree removal)\s*:\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s*$"
)
expected_by_mode = {
    "files": {"file_creation", "file_stat", "file_read", "file_removal"},
    "dirs": {"directory_creation", "directory_stat", "directory_removal", "tree_creation", "tree_removal"},
    "all": {
        "directory_creation",
        "directory_stat",
        "directory_removal",
        "file_creation",
        "file_stat",
        "file_read",
        "file_removal",
        "tree_creation",
        "tree_removal",
    },
}
try:
    expected_operations = expected_by_mode[mode]
except KeyError as exc:
    raise SystemExit(f"unsupported mdtest mode: {mode}") from exc
operations = {}
rate_summary_seen = False
for line in raw_path.read_text(encoding="utf-8", errors="replace").splitlines():
    if not rate_summary_seen:
        if line.lstrip().startswith("SUMMARY rate:"):
            rate_summary_seen = True
        continue
    if line.lstrip().startswith("SUMMARY ") and not line.lstrip().startswith("SUMMARY rate:"):
        break
    match = line_pattern.match(line)
    if not match:
        continue
    key = match.group(1).lower().replace(" ", "_")
    if key in operations:
        raise SystemExit(f"mdtest output contains duplicate rate row: {key}")
    try:
        values = [float(match.group(index)) for index in range(2, 6)]
    except ValueError as exc:
        raise SystemExit(f"mdtest output contains non-numeric rate row: {key}") from exc
    if any(value < 0 or not math.isfinite(value) for value in values):
        raise SystemExit(f"mdtest output contains invalid rate row: {key}")
    operations[key] = {
        "max_rate": values[0],
        "min_rate": values[1],
        "mean_rate": values[2],
        "stddev": values[3],
    }

if not rate_summary_seen:
    raise SystemExit(f"mdtest output has no SUMMARY rate section: {raw_path}")
missing_operations = expected_operations.difference(operations)
if missing_operations:
    missing = ", ".join(sorted(missing_operations))
    raise SystemExit(f"mdtest SUMMARY rate is incomplete; missing: {missing}")

summary = {
    "scenario": scenario,
    "case_id": case_id,
    "mode": mode,
    "num_procs": num_procs,
    "entries_per_rank": entries_per_rank,
    "total_entries_requested": total_entries,
    "total_entries_actual": num_procs * entries_per_rank,
    "iterations": iterations,
    "operations": operations,
    "raw_log": str(raw_path),
}
summary_path.parent.mkdir(parents=True, exist_ok=True)
summary_path.write_text(json.dumps(summary, sort_keys=True) + "\n", encoding="utf-8")
print(json.dumps(summary, sort_keys=True))
PY
}

run_mdtest_workload() {
  local scenario=$1
  local case_id=$2
  local mdtest_root=$3
  local mode=$4
  local num_procs=$5
  local total_entries=$6
  local iterations=$7
  local result_root=$8
  local timeout_seconds=$9
  local effective_timeout command_name log_file raw_file summary_file
  local entries_per_rank
  local -a mdtest_args

  entries_per_rank="$(split_total_count "$total_entries" "$num_procs")"
  command_name="mdtest-${case_id}-${mode}-p${num_procs}"
  log_file="${LOG_DIR}/${command_name}.log"
  raw_file="${result_root}/mdtest-${mode}-p${num_procs}.log"
  summary_file="${result_root}/mdtest-${mode}-p${num_procs}.json"
  mkdir -p -- "$mdtest_root" "$result_root"
  effective_timeout="$(case_timeout_remaining "$timeout_seconds")" || return $?
  log "mdtest: scenario=${scenario} mode=${mode} total_entries=${total_entries} entries_per_rank=${entries_per_rank} actual_entries=$((num_procs * entries_per_rank)) num_procs=${num_procs} iterations=${iterations} timeout=${effective_timeout}s"

  mdtest_args=(
    -d "$mdtest_root"
    -n "$entries_per_rank"
    -i "$iterations"
    -u
    -L
  )
  case "$mode" in
    files) mdtest_args+=(-F) ;;
    dirs) mdtest_args+=(-D) ;;
    all) ;;
    *) fail "unsupported mdtest mode: ${mode}" ;;
  esac

  if ! run_nohup "$command_name" "$effective_timeout" env \
    OMPI_ALLOW_RUN_AS_ROOT=1 \
    OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1 \
    OMPI_MCA_rmaps_base_oversubscribe=1 \
    HYDRA_ALLOW_RUN_AS_ROOT=1 \
    "$MDTEST_LAUNCHER" -np "$num_procs" "$MDTEST_BIN" "${mdtest_args[@]}"; then
    cp -- "$log_file" "$raw_file" >/dev/null 2>&1 || true
    return 1
  fi
  cp -- "$log_file" "$raw_file"
  summarize_mdtest_result "$raw_file" "$summary_file" "$scenario" "$case_id" "$mode" "$num_procs" "$entries_per_rank" "$total_entries" "$iterations" >/dev/null
}

run_mdtest_case_body() {
  local scenario=$1 profile=$2 mode=$3 num_procs=$4 case_id=$5
  local remote_root="${6}" mount_point="${7}" cache_dir="${8}" local_root="${9}" layer_name="${10}"
  local mdtest_root result_root

  ACTIVE_REMOTE_ROOT="$remote_root"
  if ! drive9 fs mkdir ":${remote_root}"; then
    return 1
  fi
  if [[ "$scenario" == layer ]] && ! create_layer "$remote_root" "$layer_name"; then
    return 1
  fi
  if ! start_mount "$scenario" "$profile" "$remote_root" "$mount_point" "$cache_dir" "$local_root" "$ACTIVE_LAYER_ID"; then
    return 1
  fi
  if [[ "$scenario" == git ]]; then
    if ! prepare_git_workspace; then
      return 1
    fi
    mdtest_root="${mount_point}/repo/agent-bench/mdtest/git"
  else
    mdtest_root="${mount_point}/mdtest/${scenario}"
  fi
  result_root="${RESULT_DIR}/mdtest/${scenario}/${case_id}"
  run_mdtest_workload "$scenario" "$case_id" "$mdtest_root" "$mode" "$num_procs" \
    "$MDTEST_TOTAL_ENTRIES" "$MDTEST_ITERATIONS" "$result_root" "$MDTEST_CASE_TIMEOUT_S"
}

run_mdtest_case() {
  local scenario=$1
  local profile=$2
  local mode=$3
  local num_procs=$4
  local stamp case_id remote_root case_dir mount_point cache_dir local_root layer_name
  stamp="$(date -u +%Y%m%dT%H%M%S)-$$"
  case_id="${scenario}-mdtest-${mode}-p${num_procs}-${stamp}"
  remote_root="/bench-${case_id}/"
  case_dir="${WORK_DIR}/${case_id}"
  mount_point="${case_dir}/mount"
  cache_dir="${case_dir}/cache"
  local_root="${case_dir}/local"
  layer_name="${case_id}"

  run_case_with_cleanup "$case_dir" "$MDTEST_CASE_TIMEOUT_S" run_mdtest_case_body \
    "$scenario" "$profile" "$mode" "$num_procs" "$case_id" "$remote_root" "$mount_point" \
    "$cache_dir" "$local_root" "$layer_name"
}

run_case_with_cleanup() {
  local case_dir=$1
  local case_timeout=$2
  local callback=$3
  shift 3
  local rc=0 cleanup_rc=0

  require_positive_int case_timeout "$case_timeout"
  ACTIVE_CASE_DEADLINE=$(( $(date +%s) + case_timeout ))
  mkdir -p -- "$case_dir"
  if begin_case_tenant; then
    ACTIVE_CASE_DIR="$case_dir"
    set +e
    "$callback" "$@"
    rc=$?
    set -e
  else
    rc=$?
    if ! rm -rf -- "$case_dir" >/dev/null 2>&1; then
      warn "could not remove case directory after tenant setup failed: ${case_dir}"
      cleanup_rc=1
    fi
  fi

  if ! end_case_tenant; then
    cleanup_rc=1
  fi
  if (( rc != 0 )); then
    if (( cleanup_rc == 0 )); then
      ACTIVE_CASE_DEADLINE=0
    fi
    return "$rc"
  fi
  if (( cleanup_rc == 0 )); then
    ACTIVE_CASE_DEADLINE=0
  fi
  return "$cleanup_rc"
}

run_small_case_body() {
  local scenario=$1 profile=$2 size=$3 concurrency=$4 case_id=$5
  local remote_root=$6 mount_point=$7 cache_write=$8 cache_read=$9
  local local_write="${10}" local_read="${11}" layer_name="${12}"
  local fio_root result_root

  ACTIVE_REMOTE_ROOT="$remote_root"
  if ! drive9 fs mkdir ":${remote_root}"; then
    return 1
  fi
  if [[ "$scenario" == layer ]] && ! create_layer "$remote_root" "$layer_name"; then
    return 1
  fi
  if ! start_mount "$scenario" "$profile" "$remote_root" "$mount_point" "$cache_write" "$local_write" "$ACTIVE_LAYER_ID"; then
    return 1
  fi
  if [[ "$scenario" == git ]]; then
    if ! prepare_git_workspace; then
      return 1
    fi
    # Keep fio data outside the fixture's local-only ignore rule so writes
    # exercise the remote Git workspace instead of only the local overlay.
    fio_root="${mount_point}/repo/agent-bench/fio/git/small"
  else
    fio_root="${mount_point}/fio/${scenario}/small"
  fi
  result_root="${RESULT_DIR}/fio/${scenario}/small/${case_id}/${size}b-c${concurrency}"
  run_fio_write_phase "$scenario" "$case_id" "$fio_root" "$size" "$concurrency" \
    "$FIO_SMALL_TOTAL_FILES" "$result_root" "$SMALL_CASE_TIMEOUT_S" || return $?
  if ! stop_mount; then
    return 1
  fi

  # Fresh cache/local-root and a fresh FUSE process for the read half.
  if ! start_mount "$scenario" "$profile" "$remote_root" "$mount_point" "$cache_read" "$local_read" "$ACTIVE_LAYER_ID"; then
    return 1
  fi
  if [[ "$scenario" == git ]]; then
    # Keep fio data outside the fixture's local-only ignore rule so writes
    # exercise the remote Git workspace instead of only the local overlay.
    fio_root="${mount_point}/repo/agent-bench/fio/git/small"
  else
    fio_root="${mount_point}/fio/${scenario}/small"
  fi
  run_fio_read_phase "$scenario" "$case_id" "$fio_root" "$size" "$concurrency" \
    "$FIO_SMALL_TOTAL_FILES" "$result_root" "$SMALL_CASE_TIMEOUT_S" || return $?
}

run_small_case() {
  local scenario=$1
  local profile=$2
  local size=$3
  local concurrency=$4
  local stamp case_id remote_root case_dir mount_point cache_write cache_read local_write local_read layer_name
  stamp="$(date -u +%Y%m%dT%H%M%S)-$$"
  case_id="${scenario}-small-${size}b-c${concurrency}-${stamp}"
  remote_root="/bench-${case_id}/"
  case_dir="${WORK_DIR}/${case_id}"
  mount_point="${case_dir}/mount"
  cache_write="${case_dir}/cache-write"
  cache_read="${case_dir}/cache-read"
  local_write="${case_dir}/local-write"
  local_read="${case_dir}/local-read"
  # Use a fresh local root for the read mount. Git workspace discovery restores
  # the registered .git state; fio data itself lives in the remote workspace.
  layer_name="${case_id}"
  run_case_with_cleanup "$case_dir" "$SMALL_CASE_TIMEOUT_S" run_small_case_body \
    "$scenario" "$profile" "$size" "$concurrency" "$case_id" "$remote_root" \
    "$mount_point" "$cache_write" "$cache_read" "$local_write" "$local_read" "$layer_name"
}

run_large_case_body() {
  local scenario=$1 profile=$2 large_mib=$3 case_id=$4 num_jobs=$5
  local remote_root="${6}" mount_point="${7}" cache_write="${8}" cache_read="${9}"
  local local_write="${10}" local_read="${11}" layer_name="${12}"
  local fio_root result_root file_size_bytes total_files

  ACTIVE_REMOTE_ROOT="$remote_root"
  if ! drive9 fs mkdir ":${remote_root}"; then
    return 1
  fi
  if [[ "$scenario" == layer ]] && ! create_layer "$remote_root" "$layer_name"; then
    return 1
  fi
  if ! start_mount "$scenario" "$profile" "$remote_root" "$mount_point" "$cache_write" "$local_write" "$ACTIVE_LAYER_ID"; then
    return 1
  fi
  if [[ "$scenario" == git ]]; then
    if ! prepare_git_workspace; then
      return 1
    fi
    fio_root="${mount_point}/repo/agent-bench/fio/git/large"
  else
    fio_root="${mount_point}/fio/${scenario}/large"
  fi
  result_root="${RESULT_DIR}/fio/${scenario}/large/${case_id}/${large_mib}MiB"
  file_size_bytes=$((large_mib * 1024 * 1024))
  total_files=$((num_jobs * FIO_LARGE_FILES_PER_JOB))
  run_fio_write_phase "$scenario" "$case_id" "$fio_root" "$file_size_bytes" "$num_jobs" \
    "$total_files" "$result_root" "$LARGE_CASE_TIMEOUT_S" || return $?
  if ! stop_mount; then
    return 1
  fi

  if ! start_mount "$scenario" "$profile" "$remote_root" "$mount_point" "$cache_read" "$local_read" "$ACTIVE_LAYER_ID"; then
    return 1
  fi
  if [[ "$scenario" == git ]]; then
    fio_root="${mount_point}/repo/agent-bench/fio/git/large"
  else
    fio_root="${mount_point}/fio/${scenario}/large"
  fi
  run_fio_read_phase "$scenario" "$case_id" "$fio_root" "$file_size_bytes" "$num_jobs" \
    "$total_files" "$result_root" "$LARGE_CASE_TIMEOUT_S" || return $?
  summarize_fio_matrix "$result_root" "${result_root}/matrix-summary.json" "$scenario" "$case_id" "$file_size_bytes" "$num_jobs" "$total_files"
}

run_large_case() {
  local scenario=$1
  local profile=$2
  local large_mib=$3
  local num_jobs=$4
  local stamp case_id remote_root case_dir mount_point cache_write cache_read local_write local_read layer_name
  stamp="$(date -u +%Y%m%dT%H%M%S)-$$"
  case_id="${scenario}-large-${large_mib}m-c${num_jobs}-f${FIO_LARGE_FILES_PER_JOB}-${stamp}"
  remote_root="/bench-${case_id}/"
  case_dir="${WORK_DIR}/${case_id}"
  mount_point="${case_dir}/mount"
  cache_write="${case_dir}/cache-write"
  cache_read="${case_dir}/cache-read"
  local_write="${case_dir}/local-write"
  local_read="${case_dir}/local-read"
  layer_name="${case_id}"
  mkdir -p -- "$case_dir"

  run_case_with_cleanup "$case_dir" "$LARGE_CASE_TIMEOUT_S" run_large_case_body \
    "$scenario" "$profile" "$large_mib" "$case_id" "$num_jobs" "$remote_root" "$mount_point" \
    "$cache_write" "$cache_read" "$local_write" "$local_read" "$layer_name"
}

validate_kimi_remote_prefix() {
  local prefix=$1
  [[ "$prefix" =~ ^/bench-kimi[A-Za-z0-9._-]*$ ]] || \
    fail "KIMI_REMOTE_ROOT_PREFIX must start with /bench-kimi and contain only letters, digits, '.', '_' or '-': ${prefix}"
}

run_kimi_case() {
  local case_name=$1
  shift
  local stamp remote_root result_dir work_dir home_dir job_name rc cleanup_rc
  local -a common_env section_env
  stamp="$(date -u +%Y%m%dT%H%M%S)-$$"
  remote_root="${KIMI_REMOTE_ROOT_PREFIX}-${case_name}-${stamp}"
  validate_kimi_remote_prefix "$KIMI_REMOTE_ROOT_PREFIX"
  validate_kimi_remote_prefix "${KIMI_REMOTE_ROOT_PREFIX}-${case_name}-${stamp}"
  result_dir="${RESULT_DIR}/kimi/${case_name}-${stamp}"
  work_dir="${WORK_DIR}/kimi/${case_name}-${stamp}"
  home_dir="${work_dir}/home"
  job_name="kimi-${case_name}-${stamp}"

  begin_case_tenant
  ACTIVE_CASE_DIR="$work_dir"
  # Kimi's FUSE mounts live below result_dir/tmp; keep reports under result_dir.
  ACTIVE_EXTRA_CASE_DIR="${result_dir}/tmp"
  mkdir -p -- "$result_dir" "$home_dir"
  log "=== customer.kimi_perf case: ${case_name} ==="
  log "Kimi tenant: ${ACTIVE_TENANT_ID}"
  log "Kimi remote root: ${remote_root}"
  log "Kimi result directory: ${result_dir}"

  common_env=(
    "HOME=${home_dir}"
    "BLACKBOX_KIMI_PERF_ENABLE=1"
    "BLACKBOX_KIMI_PERF_REMOTE_ROOT=${remote_root}"
    "BLACKBOX_KIMI_PERF_PROFILE=${KIMI_PROFILE}"
    "BLACKBOX_KIMI_PERF_DURABILITY=${KIMI_DURABILITY}"
    "BLACKBOX_KIMI_PERF_RUNS=${KIMI_RUNS}"
    "BLACKBOX_KIMI_PERF_VISIBILITY_TIMEOUT_S=${KIMI_VISIBILITY_TIMEOUT_S}"
    "BLACKBOX_KIMI_PERF_NAMESPACE_CMD_TIMEOUT_S=${KIMI_NAMESPACE_CMD_TIMEOUT_S}"
    "BLACKBOX_KIMI_PERF_NAMESPACE_CMD_TIMEOUTS=${KIMI_NAMESPACE_CMD_TIMEOUTS}"
    "BLACKBOX_KIMI_PERF_DATASET_TIMEOUT_S=${KIMI_DATASET_TIMEOUT_S}"
    "BLACKBOX_KIMI_PERF_DATASET_TIMEOUTS=${KIMI_DATASET_TIMEOUTS}"
    "BLACKBOX_KIMI_PERF_STAT_SAMPLES=${KIMI_STAT_SAMPLES}"
    "BLACKBOX_KIMI_PERF_RAW=1"
    "BLACKBOX_KIMI_PERF_REUSE_DATASETS=0"
  )
  section_env=("$@")
  rc=0
  if run_nohup "$job_name" "$KIMI_CASE_TIMEOUT_S" \
    env "${common_env[@]}" "${section_env[@]}" \
      python3 "${ROOT_DIR}/blackbox/run.py" \
        --module customer.kimi_perf \
        --server-mode config \
        --bin "$CLI" \
        --strict-prereqs \
        --runs "$KIMI_RUNS" \
        --work-dir "$work_dir" \
        --out-dir "$result_dir"; then
    rc=0
  else
    rc=$?
  fi

  cleanup_rc=0
  if ! end_case_tenant; then
    cleanup_rc=1
  fi
  if (( cleanup_rc == 0 )); then
    if rm -rf -- "$work_dir"; then
      log "Kimi case environment clean: ${case_name}"
    else
      cleanup_rc=1
      warn "could not remove Kimi case workdir: ${work_dir}"
    fi
  else
    warn "preserving Kimi case workdir because cleanup failed: ${work_dir}"
  fi
  log "Kimi report: ${result_dir}/artifacts/customer.kimi_perf/report.md"

  if (( rc != 0 )); then
    return "$rc"
  fi
  return "$cleanup_rc"
}

run_kimi_perf() {
  if ! is_true "$RUN_KIMI_PERF"; then
    log 'customer.kimi_perf disabled by RUN_KIMI_PERF'
    return 0
  fi

  local size concurrency mount_count scale layout
  local -a small_sizes small_concurrency flush_sizes flush_concurrency mount_counts kimi_scales kimi_layouts
  validate_kimi_remote_prefix "$KIMI_REMOTE_ROOT_PREFIX"
  IFS=',' read -r -a small_sizes <<< "$KIMI_SMALL_SIZES"
  IFS=',' read -r -a small_concurrency <<< "$KIMI_SMALL_CONCURRENCY"
  IFS=',' read -r -a flush_sizes <<< "$KIMI_FLUSH_SIZES"
  IFS=',' read -r -a flush_concurrency <<< "$KIMI_FLUSH_CONCURRENCY"
  IFS=',' read -r -a mount_counts <<< "$KIMI_MOUNT_COUNTS"
  IFS=',' read -r -a kimi_scales <<< "$KIMI_SCALES"
  IFS=',' read -r -a kimi_layouts <<< "$KIMI_LAYOUTS"

  log 'customer.kimi_perf uses one fresh tenant per internal parameter case'

  for size in "${small_sizes[@]}"; do
    for concurrency in "${small_concurrency[@]}"; do
      run_kimi_case "small-${size}b-c${concurrency}" \
        BLACKBOX_KIMI_PERF_NAMESPACE=0 \
        BLACKBOX_KIMI_PERF_SMALL_FILE=1 \
        BLACKBOX_KIMI_PERF_SMALL_SIZES="$size" \
        BLACKBOX_KIMI_PERF_SMALL_CONCURRENCY="$concurrency" \
        BLACKBOX_KIMI_PERF_SMALL_OPS="$KIMI_SMALL_OPS" \
        BLACKBOX_KIMI_PERF_FLUSH=0 \
        BLACKBOX_KIMI_PERF_PERSISTENCE=0 \
        BLACKBOX_KIMI_PERF_MULTI_MOUNT=0 \
        BLACKBOX_KIMI_PERF_SOAK=0
    done
  done

  # The unmodified native module covers close, fsync, and fdatasync inside
  # each flush invocation. Keep one tenant per size/concurrency case.
  for size in "${flush_sizes[@]}"; do
    for concurrency in "${flush_concurrency[@]}"; do
      run_kimi_case "flush-${size}b-c${concurrency}" \
        BLACKBOX_KIMI_PERF_NAMESPACE=0 \
        BLACKBOX_KIMI_PERF_SMALL_FILE=0 \
        BLACKBOX_KIMI_PERF_FLUSH=1 \
        BLACKBOX_KIMI_PERF_FLUSH_SIZES="$size" \
        BLACKBOX_KIMI_PERF_FLUSH_CONCURRENCY="$concurrency" \
        BLACKBOX_KIMI_PERF_FLUSH_OPS="$KIMI_FLUSH_OPS" \
        BLACKBOX_KIMI_PERF_FLUSH_VISIBILITY_SAMPLES="$KIMI_VISIBILITY_SAMPLES" \
        BLACKBOX_KIMI_PERF_PERSISTENCE=0 \
        BLACKBOX_KIMI_PERF_MULTI_MOUNT=0 \
        BLACKBOX_KIMI_PERF_SOAK=0
    done
  done

  # The unmodified native module covers close and fsync inside each
  # persistence invocation. Keep one tenant per file-size case.
  for size in "${flush_sizes[@]}"; do
    run_kimi_case "persistence-${size}b" \
      BLACKBOX_KIMI_PERF_NAMESPACE=0 \
      BLACKBOX_KIMI_PERF_SMALL_FILE=0 \
      BLACKBOX_KIMI_PERF_FLUSH=0 \
      BLACKBOX_KIMI_PERF_PERSISTENCE=1 \
      BLACKBOX_KIMI_PERF_FLUSH_SIZES="$size" \
      BLACKBOX_KIMI_PERF_PERSISTENCE_SAMPLES="$KIMI_PERSISTENCE_SAMPLES" \
      BLACKBOX_KIMI_PERF_MULTI_MOUNT=0 \
      BLACKBOX_KIMI_PERF_SOAK=0
  done

  for mount_count in "${mount_counts[@]}"; do
    run_kimi_case "multi-mount-${mount_count}" \
      BLACKBOX_KIMI_PERF_NAMESPACE=0 \
      BLACKBOX_KIMI_PERF_SMALL_FILE=0 \
      BLACKBOX_KIMI_PERF_FLUSH=0 \
      BLACKBOX_KIMI_PERF_PERSISTENCE=0 \
      BLACKBOX_KIMI_PERF_MULTI_MOUNT=1 \
      BLACKBOX_KIMI_PERF_MOUNT_COUNTS="$mount_count" \
      BLACKBOX_KIMI_PERF_SOAK=0
  done

  for scale in "${kimi_scales[@]}"; do
    for layout in "${kimi_layouts[@]}"; do
      run_kimi_case "namespace-${scale}-${layout}" \
        BLACKBOX_KIMI_PERF_NAMESPACE=1 \
        BLACKBOX_KIMI_PERF_SCALES="$scale" \
        BLACKBOX_KIMI_PERF_LAYOUTS="$layout" \
        BLACKBOX_KIMI_PERF_STAT_SAMPLES="$KIMI_STAT_SAMPLES" \
        BLACKBOX_KIMI_PERF_SMALL_FILE=0 \
        BLACKBOX_KIMI_PERF_FLUSH=0 \
        BLACKBOX_KIMI_PERF_PERSISTENCE=0 \
        BLACKBOX_KIMI_PERF_MULTI_MOUNT=0 \
        BLACKBOX_KIMI_PERF_SOAK=0
    done
  done

  if is_true "$KIMI_SOAK"; then
    run_kimi_case 'soak' \
      BLACKBOX_KIMI_PERF_NAMESPACE=0 \
      BLACKBOX_KIMI_PERF_SMALL_FILE=0 \
      BLACKBOX_KIMI_PERF_FLUSH=0 \
      BLACKBOX_KIMI_PERF_PERSISTENCE=0 \
      BLACKBOX_KIMI_PERF_MULTI_MOUNT=0 \
      BLACKBOX_KIMI_PERF_SOAK=1 \
      BLACKBOX_KIMI_PERF_SOAK_MINUTES="$KIMI_SOAK_MINUTES"
  fi
}

run_gate_command_body() {
  local name=$1
  local timeout_seconds
  shift
  timeout_seconds="$(case_timeout_remaining "$GATE_TIMEOUT_S")" || return $?
  run_nohup "$name" "$timeout_seconds" env "$@"
}

run_gate_case() {
  local name=$1
  local case_dir=$2
  local rc=0
  shift 2
  log "running gate with isolated tenant: ${name}"
  ACTIVE_EXTRA_CASE_DIR="$case_dir"
  if run_case_with_cleanup "$case_dir" "$GATE_TIMEOUT_S" run_gate_command_body "$name" "$@"; then
    ACTIVE_EXTRA_CASE_DIR=""
    return 0
  else
    rc=$?
  fi
  return "$rc"
}

prepare_work_root() {
  log "cleaning stale local benchmark work root: ${WORK_DIR}"
  cleanup_external_mounts "$WORK_DIR" || \
    fail "stale FUSE mount/process remains under benchmark work root: ${WORK_DIR}"
  rm -rf -- "$WORK_DIR"
  mkdir -p -- "$WORK_DIR"
}

run_correctness_gates() {
  if ! is_true "$RUN_CORRECTNESS_GATES"; then
    log 'correctness gates disabled by RUN_CORRECTNESS_GATES'
    return 0
  fi

  run_gate_case gate-fuse-correctness "${WORK_DIR}/gate-fuse-correctness" \
    CLI_SOURCE=build FUSE_STRICT_PREREQS=1 \
    FUSE_MOUNT_ROOT="${WORK_DIR}/gate-fuse-correctness" FUSE_UMOUNT_TIMEOUT="$UMOUNT_TIMEOUT" \
    bash "${ROOT_DIR}/e2e/fuse-correctness-workload.sh"

  run_gate_case gate-layer-fs "${WORK_DIR}/gate-layer-fs" \
    CLI_SOURCE=build \
    RUN_LAYER_FUSE_SMOKE=1 LAYER_FUSE_STRICT_PREREQS=1 LAYER_CLI_LARGE_FILE_MB="$LAYER_CLI_LARGE_MB" \
    FUSE_MOUNT_ROOT="${WORK_DIR}/gate-layer-fs" FUSE_UMOUNT_TIMEOUT="$UMOUNT_TIMEOUT" \
    bash "${ROOT_DIR}/e2e/layer-fs-smoke-test.sh"

  # git-feature-smoke-test builds a local bare fixture with tools/git_fixture.py
  # and uses file:// URLs; it never contacts GitHub.
  run_gate_case gate-git-feature "${WORK_DIR}/gate-git-feature" \
    CLI_SOURCE=build FUSE_STRICT_PREREQS=1 \
    FUSE_MOUNT_ROOT="${WORK_DIR}/gate-git-feature" FUSE_UMOUNT_TIMEOUT="$UMOUNT_TIMEOUT" \
    GIT_TERMINAL_PROMPT=0 POLL_TIMEOUT_S="$TENANT_PROVISION_TIMEOUT_S" MOUNT_READY_TIMEOUT_S="$MOUNT_READY_TIMEOUT_S" \
    GIT_FEATURE_TIMEOUT_S="$GIT_FEATURE_TIMEOUT_S" GIT_FEATURE_RUN_OVERSIZED="$GIT_FEATURE_RUN_OVERSIZED" \
    bash "${ROOT_DIR}/e2e/git-feature-smoke-test.sh"
}

main() {
  local mdtest_mode
  local -a mdtest_modes
  IFS=',' read -r -a mdtest_modes <<< "$MDTEST_MODES"

  log "output directory: ${BENCH_OUTPUT_DIR}"
  log "server: ${DRIVE9_SERVER}"
  log "fio binary: ${FIO_BIN} (${FIO_VERSION})"
  log "fio small sizes: ${SMALL_SIZES}"
  log "fio small jobs: ${SMALL_CONCURRENCY}"
  log "fio total files per small case: ${FIO_SMALL_TOTAL_FILES}"
  log "fio runs per workload: ${FIO_RUNS}"
  log "fio large sizes MiB: ${LARGE_MIBS}"
  log "fio large concurrency: ${FIO_LARGE_CONCURRENCY}"
  log "fio large files per job: ${FIO_LARGE_FILES_PER_JOB}"
  log "mdtest enabled: ${RUN_MDTEST}"
  log "mdtest binary: ${MDTEST_BIN} (${MDTEST_VERSION})"
  log "mdtest launcher: ${MDTEST_LAUNCHER} (${MDTEST_LAUNCHER_VERSION})"
  log "mdtest total entries per case: ${MDTEST_TOTAL_ENTRIES}"
  log "mdtest process matrix: ${MDTEST_NUMPROCS}"
  log "mdtest modes: ${MDTEST_MODES}"
  log "Kimi enabled: ${RUN_KIMI_PERF}"
  log "Kimi scales/layouts: ${KIMI_SCALES}/${KIMI_LAYOUTS}"
  log "Kimi small sizes/concurrency: ${KIMI_SMALL_SIZES}/${KIMI_SMALL_CONCURRENCY}"
  log "metadata database: ${DRIVE9_META_DB_NAME}@${MYSQL_HOST}:${MYSQL_PORT}"

  prepare_work_root

  log 'checking live Drive9 health'
  curl --fail --silent --show-error "${DRIVE9_SERVER%/}/healthz" >/dev/null

  run_correctness_gates

  log '=== base filesystem: fio I/O matrix ==='
  for size in $SMALL_SIZES; do
    for concurrency in $SMALL_CONCURRENCY; do
      run_small_case base none "$size" "$concurrency"
    done
  done

  log '=== base filesystem: fio large-file/concurrency matrix ==='
  for large_mib in $LARGE_MIBS; do
    for num_jobs in $FIO_LARGE_CONCURRENCY; do
      run_large_case base none "$large_mib" "$num_jobs"
    done
  done

  if is_true "$RUN_MDTEST"; then
    log '=== base filesystem: mdtest metadata matrix ==='
    for mdtest_mode in "${mdtest_modes[@]}"; do
      for num_procs in $MDTEST_NUMPROCS; do
        run_mdtest_case base none "$mdtest_mode" "$num_procs"
      done
    done
  fi

  log '=== LayerFS: fio I/O matrix ==='
  for size in $SMALL_SIZES; do
    for concurrency in $SMALL_CONCURRENCY; do
      run_small_case layer none "$size" "$concurrency"
    done
  done

  log '=== LayerFS: fio large-file/concurrency matrix ==='
  for large_mib in $LARGE_MIBS; do
    for num_jobs in $FIO_LARGE_CONCURRENCY; do
      run_large_case layer none "$large_mib" "$num_jobs"
    done
  done

  if is_true "$RUN_MDTEST"; then
    log '=== LayerFS: mdtest metadata matrix ==='
    for mdtest_mode in "${mdtest_modes[@]}"; do
      for num_procs in $MDTEST_NUMPROCS; do
        run_mdtest_case layer none "$mdtest_mode" "$num_procs"
      done
    done
  fi

  log '=== Git workspace: fio I/O matrix ==='
  for size in $SMALL_SIZES; do
    for concurrency in $SMALL_CONCURRENCY; do
      run_small_case git coding-agent "$size" "$concurrency"
    done
  done

  log '=== Git workspace: fio large-file/concurrency matrix ==='
  for large_mib in $LARGE_MIBS; do
    for num_jobs in $FIO_LARGE_CONCURRENCY; do
      run_large_case git coding-agent "$large_mib" "$num_jobs"
    done
  done

  if is_true "$RUN_MDTEST"; then
    log '=== Git workspace: mdtest metadata matrix ==='
    for mdtest_mode in "${mdtest_modes[@]}"; do
      for num_procs in $MDTEST_NUMPROCS; do
        run_mdtest_case git coding-agent "$mdtest_mode" "$num_procs"
      done
    done
  fi

  log '=== customer.kimi_perf: repository FUSE reference benchmark ==='
  run_kimi_perf

  log 'all benchmark cases completed'
  log "fio results: ${RESULT_DIR}/fio"
  log "mdtest results: ${RESULT_DIR}/mdtest"
  log "Kimi results: ${RESULT_DIR}/kimi"
  log "logs: ${LOG_DIR}"
}

main "$@"
