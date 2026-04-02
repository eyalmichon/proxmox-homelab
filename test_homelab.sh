#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# test_homelab.sh — local verification matrix for the homelab script
#
# Runs entirely offline with mock docker/git/wget/jq stubs.
# Usage:  bash test_homelab.sh
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMELAB="$SCRIPT_DIR/homelab"

PASS=0 FAIL=0 SKIP=0
GN="\033[1;32m" RD="\033[01;31m" YW="\033[33m" BD="\033[1m" CL="\033[m"

pass() { PASS=$((PASS + 1)); echo -e " ${GN}✓${CL} $1"; }
fail() { FAIL=$((FAIL + 1)); echo -e " ${RD}✗ $1${CL}"; }
skip() { SKIP=$((SKIP + 1)); echo -e " ${YW}⊘ $1${CL}"; }

# ── Sandbox setup ────────────────────────────────────────────────────────────

SANDBOX=""
cleanup() { [[ -n "$SANDBOX" ]] && rm -rf "$SANDBOX"; }
trap cleanup EXIT

new_sandbox() {
  [[ -n "$SANDBOX" ]] && rm -rf "$SANDBOX"
  SANDBOX=$(mktemp -d)
  export SERVICES_DIR="$SANDBOX/services"
  export BACKUPS_DIR="$SANDBOX/backups"
  mkdir -p "$SERVICES_DIR" "$BACKUPS_DIR"

  MOCK_BIN="$SANDBOX/bin"
  mkdir -p "$MOCK_BIN"
  export PATH="$MOCK_BIN:$ORIG_PATH"
}

ORIG_PATH="$PATH"

# ── Mock builders ────────────────────────────────────────────────────────────

mock_cmd() {
  local name="$1" body="$2"
  {
    echo '#!/usr/bin/env bash'
    printf '%s\n' "$body"
  } > "$MOCK_BIN/$name"
  chmod +x "$MOCK_BIN/$name"
}

mock_docker_default() {
  mock_cmd docker '
case "$*" in
  "compose version")     echo "Docker Compose version v2.24.0" ;;
  *"compose -f"*"ps -q"*)  echo "" ;;
  *"compose -f"*"ps --format json"*) echo "[]" ;;
  *"compose -f"*"up -d"*)  exit 0 ;;
  *"compose -f"*"down"*)   exit 0 ;;
  *"compose -f"*"down -v"*) exit 0 ;;
  *"compose -f"*"restart"*) exit 0 ;;
  *"compose -f"*"config --volumes"*) echo "" ;;
  *"compose -f"*"config --format json"*) echo "{\"name\":\"test\"}" ;;
  *"compose -f"*"logs"*)   echo "[mock] log output" ;;
  "image inspect alpine"*) exit 0 ;;
  "volume inspect"*)       exit 0 ;;
  "pull alpine")           exit 0 ;;
  "run --rm"*)             exit 0 ;;
  *)                       echo "[mock docker] unhandled: $*" >&2; exit 0 ;;
esac
'
}

mock_git_default() {
  mock_cmd git '
case "$*" in
  "clone --depth 1"*)
    dest="${@: -1}"
    mkdir -p "$dest"
    echo "Cloning into ${dest}..."
    ;;
  *"pull --ff-only"*)
    echo "Already up to date."
    ;;
  *"remote get-url origin"*)
    echo "https://github.com/eyalmichon/test-repo.git"
    ;;
  *)
    echo "[mock git] unhandled: $*" >&2
    exit 0
    ;;
esac
'
}

mock_jq_default() {
  mock_cmd jq '
echo ""
'
}

mock_wget_default() {
  mock_cmd wget '
for arg in "$@"; do
  if [[ "$prev" == "-qO" || "$arg" =~ ^/ ]]; then
    target="$arg"
    break
  fi
  prev="$arg"
done
if [[ -n "${target:-}" ]]; then
  echo "#!/usr/bin/env bash" > "$target"
  echo "echo mock" >> "$target"
fi
'
}

# NOTE: Always source homelab directly (not via a wrapper function) because
# `declare -A` inside a function creates a local variable — REGISTRY would
# vanish when the function returns.

# ── Tests ────────────────────────────────────────────────────────────────────

echo -e "\n${BD}═══ homelab test suite ═══${CL}\n"

# ─── 1. Pure function: trim() ───────────────────────────────────────────────

echo -e "${BD}── trim() ──${CL}"
new_sandbox
mock_docker_default
source "$HOMELAB"

result=$(trim "  hello  ")
[[ "$result" == "hello" ]] && pass "trim: leading+trailing spaces" || fail "trim: expected 'hello', got '$result'"

result=$(trim "	 tabs and spaces 	")
[[ "$result" == "tabs and spaces" ]] && pass "trim: tabs and spaces" || fail "trim: expected 'tabs and spaces', got '$result'"

result=$(trim "nospace")
[[ "$result" == "nospace" ]] && pass "trim: no whitespace" || fail "trim: expected 'nospace', got '$result'"

result=$(trim "")
[[ "$result" == "" ]] && pass "trim: empty string" || fail "trim: expected '', got '$result'"

# ─── 2. Pure function: dotenv_escape() ──────────────────────────────────────

echo -e "\n${BD}── dotenv_escape() ──${CL}"

result=$(dotenv_escape 'simple')
[[ "$result" == "simple" ]] && pass "dotenv_escape: plain value" || fail "dotenv_escape: expected 'simple', got '$result'"

result=$(dotenv_escape 'pass"word')
[[ "$result" == 'pass\"word' ]] && pass "dotenv_escape: double quotes" || fail "dotenv_escape: got '$result'"

result=$(dotenv_escape 'back\slash')
[[ "$result" == 'back\\slash' ]] && pass "dotenv_escape: backslash" || fail "dotenv_escape: got '$result'"

result=$(dotenv_escape 'price$5')
[[ "$result" == 'price\$5' ]] && pass "dotenv_escape: dollar sign" || fail "dotenv_escape: got '$result'"

result=$(dotenv_escape 'a"b\c$d')
[[ "$result" == 'a\"b\\c\$d' ]] && pass "dotenv_escape: all special chars combined" || fail "dotenv_escape: got '$result'"

# ─── 3. is_installed() — marker vs legacy ───────────────────────────────────

echo -e "\n${BD}── is_installed() ──${CL}"
new_sandbox
mock_docker_default
source "$HOMELAB"

mkdir -p "$SERVICES_DIR/svc-marker"
touch "$SERVICES_DIR/svc-marker/.homelab-installed"
is_installed "svc-marker" && pass "is_installed: .homelab-installed marker" || fail "is_installed: marker not detected"

mkdir -p "$SERVICES_DIR/svc-legacy"
touch "$SERVICES_DIR/svc-legacy/docker-compose.yml"
is_installed "svc-legacy" && pass "is_installed: legacy docker-compose.yml" || fail "is_installed: legacy not detected"

mkdir -p "$SERVICES_DIR/svc-empty"
is_installed "svc-empty" && fail "is_installed: empty dir should not be installed" || pass "is_installed: empty dir correctly rejected"

is_installed "nonexistent" && fail "is_installed: nonexistent should fail" || pass "is_installed: nonexistent correctly rejected"

# ─── 4. installed_services() ────────────────────────────────────────────────

echo -e "\n${BD}── installed_services() ──${CL}"
new_sandbox
mock_docker_default
source "$HOMELAB"

mkdir -p "$SERVICES_DIR/alpha"
touch "$SERVICES_DIR/alpha/.homelab-installed"
mkdir -p "$SERVICES_DIR/beta"
touch "$SERVICES_DIR/beta/docker-compose.yml"
mkdir -p "$SERVICES_DIR/gamma"  # no marker, no compose

result=$(installed_services)
if echo "$result" | grep -q "alpha" && echo "$result" | grep -q "beta" && ! echo "$result" | grep -q "gamma"; then
  pass "installed_services: finds marker + legacy, skips empty"
else
  fail "installed_services: got '$result'"
fi

# ─── 5. maybe_stamp_marker() — legacy migration ────────────────────────────

echo -e "\n${BD}── maybe_stamp_marker() ──${CL}"
new_sandbox

# Mock docker where compose ps -q returns a container ID
mock_cmd docker '
case "$*" in
  "compose version") echo "Docker Compose version v2.24.0" ;;
  *"compose -f"*"ps -q"*) echo "abc123" ;;
  *) exit 0 ;;
esac
'
source "$HOMELAB"

mkdir -p "$SERVICES_DIR/running-svc"
touch "$SERVICES_DIR/running-svc/docker-compose.yml"

maybe_stamp_marker "running-svc" 2>/dev/null
[[ -f "$SERVICES_DIR/running-svc/.homelab-installed" ]] \
  && pass "maybe_stamp_marker: stamps running legacy service" \
  || fail "maybe_stamp_marker: did not create marker"

# Already has marker — should be a no-op
maybe_stamp_marker "running-svc" 2>/dev/null \
  && pass "maybe_stamp_marker: no-op when marker exists" \
  || fail "maybe_stamp_marker: failed on existing marker"

# Partial clone — no containers running
new_sandbox
mock_cmd docker '
case "$*" in
  "compose version") echo "Docker Compose version v2.24.0" ;;
  *"compose -f"*"ps -q"*) echo "" ;;
  *) exit 0 ;;
esac
'
source "$HOMELAB"

mkdir -p "$SERVICES_DIR/partial-svc"
touch "$SERVICES_DIR/partial-svc/docker-compose.yml"

if maybe_stamp_marker "partial-svc" 2>/dev/null; then
  fail "maybe_stamp_marker: should reject partial install"
else
  [[ ! -f "$SERVICES_DIR/partial-svc/.homelab-installed" ]] \
    && pass "maybe_stamp_marker: rejects partial install, no marker created" \
    || fail "maybe_stamp_marker: created marker for partial install"
fi

# ─── 6. homelab help — no dependencies needed ───────────────────────────────

echo -e "\n${BD}── cmd_help (bare machine) ──${CL}"
new_sandbox

# Resolve bash 4+ path (macOS /bin/bash is 3.2 — too old for associative arrays)
BASH4="$(command -v bash)"

# Empty mock bin — no docker/git/jq/wget available, only system essentials + bash 4+
export PATH="$MOCK_BIN:$(dirname "$BASH4"):/usr/bin:/bin"

output=$("$BASH4" "$HOMELAB" help 2>&1) || true
if echo "$output" | grep -q "homelab.*unified service management"; then
  pass "help: works without jq/wget/docker/git"
else
  fail "help: unexpected output"
fi
export PATH="$MOCK_BIN:$ORIG_PATH"

# ─── 7. .env special characters (generate_env) ─────────────────────────────

echo -e "\n${BD}── generate_env (.env special chars) ──${CL}"
new_sandbox
mock_docker_default
source "$HOMELAB"

svc_dir="$SERVICES_DIR/envtest"
mkdir -p "$svc_dir"
cat > "$svc_dir/.env.example" <<'ENVEX'
# Required
MY_PASSWORD=default123
NORMAL_VAR=hello
ENVEX

# Simulate user typing a value with all dangerous chars: "  \  $  '
# We test by directly calling dotenv_escape and verifying the .env line format
value='He said "hi" \ costs $5 it'\''s fine'
escaped=$(dotenv_escape "$value")
line="MY_PASSWORD=\"$escaped\""

# Verify the line doesn't have unescaped quotes breaking the format
# Count unescaped double quotes (should be exactly 2 — the wrapping pair)
stripped="${line//\\\"/}"  # remove escaped quotes
quote_count=$(echo "$stripped" | tr -cd '"' | wc -c | tr -d ' ')
if [[ "$quote_count" -eq 2 ]]; then
  pass ".env escaping: special chars produce valid dotenv line"
else
  fail ".env escaping: got line '$line' with $quote_count unescaped quotes"
fi

# ─── 8. cmd_status — no services ────────────────────────────────────────────

echo -e "\n${BD}── cmd_status (no services) ──${CL}"
new_sandbox
mock_docker_default
mock_jq_default
source "$HOMELAB"

output=$(cmd_status 2>&1) || true
if echo "$output" | grep -qi "no services"; then
  pass "status: empty host shows 'no services'"
else
  fail "status: expected 'no services' message, got: $output"
fi

# ─── 9. cmd_status — stopped service ────────────────────────────────────────

echo -e "\n${BD}── cmd_status (stopped service) ──${CL}"
new_sandbox

mock_cmd docker '
case "$*" in
  "compose version") echo "Docker Compose version v2.24.0" ;;
  *"compose -f"*"ps --format json"*) echo "[]" ;;
  *) exit 0 ;;
esac
'
mock_jq_default
source "$HOMELAB"

mkdir -p "$SERVICES_DIR/stopped-svc"
touch "$SERVICES_DIR/stopped-svc/.homelab-installed"

output=$(cmd_status 2>&1) || true
if echo "$output" | grep -q "stopped"; then
  pass "status: stopped service shows 'stopped' row"
else
  fail "status: expected 'stopped' row, got: $output"
fi

# ─── 10. cmd_status — running service with ports ────────────────────────────

echo -e "\n${BD}── cmd_status (running service) ──${CL}"
new_sandbox

MOCK_JSON='{"Name":"web-1","State":"running","Health":"healthy","RunningFor":"2 hours ago","Publishers":[{"PublishedPort":8080},{"PublishedPort":0},{"PublishedPort":443}]}'

mock_cmd docker "
case \"\$*\" in
  \"compose version\") echo \"Docker Compose version v2.24.0\" ;;
  *\"compose -f\"*\"ps --format json\"*) echo '$MOCK_JSON' ;;
  *) exit 0 ;;
esac
"

# Real jq needed for this test
if command -v jq &>/dev/null; then
  rm -f "$MOCK_BIN/jq"  # use real jq
  source "$HOMELAB"

  mkdir -p "$SERVICES_DIR/web"
  touch "$SERVICES_DIR/web/.homelab-installed"

  output=$(cmd_status 2>&1) || true
  if echo "$output" | grep -q "running" && echo "$output" | grep -q "healthy"; then
    pass "status: running service shows state and health"
  else
    fail "status: expected running/healthy, got: $output"
  fi

  # Verify port 0 is filtered out
  if echo "$output" | grep -q "443" && ! echo "$output" | grep -qE '\b0\b.*443|443.*\b0\b'; then
    pass "status: port 0 filtered, real ports shown"
  else
    fail "status: port filtering issue, got: $output"
  fi
else
  skip "status (running): jq not installed locally"
fi

# ─── 11. Fresh install flow ─────────────────────────────────────────────────

echo -e "\n${BD}── cmd_install (fresh) ──${CL}"
new_sandbox

mock_cmd docker '
case "$*" in
  "compose version") echo "Docker Compose version v2.24.0" ;;
  *"compose -f"*"ps -q"*) echo "" ;;
  *"compose -f"*"up -d"*) exit 0 ;;
  *) exit 0 ;;
esac
'

mock_cmd git '
case "$*" in
  "clone --depth 1"*)
    dest="${@: -1}"
    mkdir -p "$dest"
    printf "version: \"3\"\nservices:\n  app:\n    image: alpine\n" > "$dest/docker-compose.yml"
    echo "Cloning into ${dest}..."
    ;;
  *) exit 0 ;;
esac
'

source "$HOMELAB"

# Override require_root to skip the check in tests
require_root() { true; }

output=$(cmd_install "nanit-bridge" 2>&1) || true
dest="$SERVICES_DIR/nanit-bridge"

if [[ -f "$dest/.homelab-installed" ]]; then
  pass "install: .homelab-installed marker created"
else
  fail "install: marker not created"
fi

if [[ -f "$dest/docker-compose.yml" ]]; then
  pass "install: docker-compose.yml present"
else
  fail "install: docker-compose.yml missing"
fi

if echo "$output" | grep -q "installed and running"; then
  pass "install: success message shown"
else
  fail "install: expected success message, got: $output"
fi

# ─── 11b. INSTALL_NOTES printed after install ───────────────────────────────

echo -e "\n${BD}── cmd_install (INSTALL_NOTES) ──${CL}"
new_sandbox

mock_cmd docker '
case "$*" in
  "compose version") echo "Docker Compose version v2.24.0" ;;
  *"compose -f"*"ps -q"*) echo "" ;;
  *"compose -f"*"up -d"*) exit 0 ;;
  *) exit 0 ;;
esac
'

mock_cmd git '
case "$*" in
  "clone --depth 1"*)
    dest="${@: -1}"
    mkdir -p "$dest"
    printf "version: \"3\"\nservices:\n  app:\n    image: alpine\n" > "$dest/docker-compose.yml"
    printf "Open http://localhost:8080 to finish setup.\n" > "$dest/INSTALL_NOTES"
    ;;
  *) exit 0 ;;
esac
'

source "$HOMELAB"
require_root() { true; }

output=$(cmd_install "nanit-bridge" 2>&1) || true
if echo "$output" | grep -q "Open http://localhost:8080"; then
  pass "install: INSTALL_NOTES printed after install"
else
  fail "install: INSTALL_NOTES not shown, got: $output"
fi

# Verify no notes when file is absent (already tested by fresh install above — no INSTALL_NOTES in that mock)

# ─── 12. Resume install — existing dir, no marker ──────────────────────────

echo -e "\n${BD}── cmd_install (resume) ──${CL}"
new_sandbox

mock_cmd docker '
case "$*" in
  "compose version") echo "Docker Compose version v2.24.0" ;;
  *"compose -f"*"ps -q"*) echo "orphan123" ;;
  *"compose -f"*"down"*) exit 0 ;;
  *"compose -f"*"up -d"*) exit 0 ;;
  *) exit 0 ;;
esac
'

mock_cmd git '
case "$*" in
  *"pull --ff-only"*) echo "Already up to date." ;;
  *) exit 0 ;;
esac
'

source "$HOMELAB"
require_root() { true; }

dest="$SERVICES_DIR/nanit-bridge"
mkdir -p "$dest"
cat > "$dest/docker-compose.yml" <<'YML'
version: "3"
services:
  app:
    image: alpine
YML

output=$(cmd_install "nanit-bridge" 2>&1) || true

if echo "$output" | grep -qi "resuming install\|stopping incomplete"; then
  pass "resume install: detects existing dir and resumes"
else
  fail "resume install: expected resume message, got: $output"
fi

if [[ -f "$dest/.homelab-installed" ]]; then
  pass "resume install: marker created after completion"
else
  fail "resume install: marker not created"
fi

# ─── 13. cmd_update — all services ─────────────────────────────────────────

echo -e "\n${BD}── cmd_update (all) ──${CL}"
new_sandbox

mock_cmd docker '
case "$*" in
  "compose version") echo "Docker Compose version v2.24.0" ;;
  *"compose -f"*"ps -q"*) echo "running123" ;;
  *"compose -f"*"up -d"*) exit 0 ;;
  *) exit 0 ;;
esac
'

mock_cmd git '
case "$*" in
  *"pull --ff-only"*) echo "Already up to date." ;;
  *) exit 0 ;;
esac
'

source "$HOMELAB"
require_root() { true; }

mkdir -p "$SERVICES_DIR/nanit-bridge"
touch "$SERVICES_DIR/nanit-bridge/docker-compose.yml"
touch "$SERVICES_DIR/nanit-bridge/.homelab-installed"
mkdir -p "$SERVICES_DIR/magic-files"
touch "$SERVICES_DIR/magic-files/docker-compose.yml"
touch "$SERVICES_DIR/magic-files/.homelab-installed"

output=$(cmd_update 2>&1) || true
if echo "$output" | grep -q "nanit-bridge.*updated\|Updating nanit-bridge" \
   && echo "$output" | grep -q "magic-files.*updated\|Updating magic-files"; then
  pass "update all: both services targeted"
else
  fail "update all: expected both services, got: $output"
fi

# ─── 14. cmd_update — git failure visible ───────────────────────────────────

echo -e "\n${BD}── cmd_update (git failure) ──${CL}"
new_sandbox

mock_cmd docker '
case "$*" in
  "compose version") echo "Docker Compose version v2.24.0" ;;
  *"compose -f"*"ps -q"*) echo "running123" ;;
  *) exit 0 ;;
esac
'

mock_cmd git '
echo "fatal: Not a git repository" >&2
exit 128
'

source "$HOMELAB"
require_root() { true; }

mkdir -p "$SERVICES_DIR/nanit-bridge"
touch "$SERVICES_DIR/nanit-bridge/docker-compose.yml"
touch "$SERVICES_DIR/nanit-bridge/.homelab-installed"

output=$(cmd_update "nanit-bridge" 2>&1) || true
if echo "$output" | grep -qi "fatal\|git pull failed"; then
  pass "update: git error is visible (not swallowed)"
else
  fail "update: git error swallowed, got: $output"
fi

# ─── 15. cmd_self_update — no-op ───────────────────────────────────────────

echo -e "\n${BD}── cmd_self_update (no-op) ──${CL}"
new_sandbox

# Make a fake "installed" binary that matches what wget will "download"
FAKE_BIN="$SANDBOX/homelab-bin"
printf '#!/usr/bin/env bash\necho mock\n' > "$FAKE_BIN"
chmod +x "$FAKE_BIN"

mock_cmd wget "
for arg in \"\$@\"; do
  if [[ \"\${prev:-}\" == \"-qO\" ]]; then target=\"\$arg\"; break; fi
  prev=\"\$arg\"
done
cp \"$FAKE_BIN\" \"\$target\"
"

mock_cmd install 'exit 0'
mock_cmd cmp '
# Compare: cmp -s file1 file2
exit 0
'

mock_docker_default
source "$HOMELAB"

# Point self-update at our fake binary
output=$(
  # Temporarily override the install target by mocking cmp to return 0 (equal)
  cmd_self_update 2>&1
) || true

if echo "$output" | grep -qi "already up to date"; then
  pass "self-update: no-op when current"
else
  fail "self-update: expected 'Already up to date', got: $output"
fi

# ─── 16. cmd_self_update — real update ──────────────────────────────────────

echo -e "\n${BD}── cmd_self_update (real update) ──${CL}"
new_sandbox

mock_cmd wget "
for arg in \"\$@\"; do
  if [[ \"\${prev:-}\" == \"-qO\" ]]; then target=\"\$arg\"; break; fi
  prev=\"\$arg\"
done
printf '#!/usr/bin/env bash\necho new-version\n' > \"\$target\"
"

mock_cmd cmp 'exit 1'  # files differ

INSTALL_LOG="$SANDBOX/install.log"
mock_cmd install "echo \"\$@\" > \"$INSTALL_LOG\""
mock_docker_default
source "$HOMELAB"

output=$(cmd_self_update 2>&1) || true

if echo "$output" | grep -qi "homelab CLI updated"; then
  pass "self-update: reports successful update"
else
  fail "self-update: expected update message, got: $output"
fi

if [[ -f "$INSTALL_LOG" ]]; then
  install_args=$(cat "$INSTALL_LOG")
  if echo "$install_args" | grep -q "0755"; then
    pass "self-update: installs with mode 0755"
  else
    fail "self-update: expected 0755, got: $install_args"
  fi
else
  fail "self-update: install command not called"
fi

# ─── 17. cmd_self_update — rejects empty download ──────────────────────────

echo -e "\n${BD}── cmd_self_update (empty download) ──${CL}"
new_sandbox

mock_cmd wget '
for arg in "$@"; do
  if [[ "${prev:-}" == "-qO" ]]; then target="$arg"; break; fi
  prev="$arg"
done
: > "$target"  # empty file
'
mock_docker_default
source "$HOMELAB"

output=$(cmd_self_update 2>&1) || true
if echo "$output" | grep -qi "empty"; then
  pass "self-update: rejects empty download"
else
  fail "self-update: expected 'empty' error, got: $output"
fi

# ─── 18. cmd_self_update — rejects non-script ──────────────────────────────

echo -e "\n${BD}── cmd_self_update (bad shebang) ──${CL}"
new_sandbox

mock_cmd wget '
for arg in "$@"; do
  if [[ "${prev:-}" == "-qO" ]]; then target="$arg"; break; fi
  prev="$arg"
done
echo "<html>not a script</html>" > "$target"
'
mock_docker_default
source "$HOMELAB"

output=$(cmd_self_update 2>&1) || true
if echo "$output" | grep -qi "not a valid script"; then
  pass "self-update: rejects non-script download"
else
  fail "self-update: expected 'not a valid script', got: $output"
fi

# ─── 19. cmd_remove — keep directory ────────────────────────────────────────

echo -e "\n${BD}── cmd_remove (keep directory) ──${CL}"
new_sandbox

mock_cmd docker '
case "$*" in
  "compose version") echo "Docker Compose version v2.24.0" ;;
  *"compose -f"*"down"*) exit 0 ;;
  *) exit 0 ;;
esac
'
source "$HOMELAB"
require_root() { true; }

dest="$SERVICES_DIR/nanit-bridge"
mkdir -p "$dest"
touch "$dest/.homelab-installed"
touch "$dest/docker-compose.yml"

# Override prompt_user to simulate answering "y" to confirm, "n" to volumes, "n" to delete dir
call_count=0
prompt_user() {
  local -n _result=$1
  ((call_count++))
  case $call_count in
    1) _result="y" ;;  # confirm removal
    2) _result="n" ;;  # don't remove volumes
    3) _result="n" ;;  # keep directory
  esac
}

output=$(cmd_remove "nanit-bridge" 2>&1) || true

if [[ -d "$dest" ]]; then
  pass "remove: directory kept when user says N"
else
  fail "remove: directory was deleted"
fi

if [[ ! -f "$dest/.homelab-installed" ]]; then
  pass "remove: .homelab-installed marker cleaned up"
else
  fail "remove: marker still exists"
fi

# ─── 20. cmd_backup — volume fallback ──────────────────────────────────────

echo -e "\n${BD}── cmd_backup (volume fallback) ──${CL}"
new_sandbox

if command -v jq &>/dev/null; then
  VOLUME_INSPECTED="$SANDBOX/vol_inspected.log"
  mock_cmd docker "
case \"\$*\" in
  \"compose version\") echo \"Docker Compose version v2.24.0\" ;;
  *\"compose -f\"*\"config --volumes\"*) echo \"mydata\" ;;
  *\"compose -f\"*\"config --format json\"*) echo '{\"name\":\"myproject\"}' ;;
  \"image inspect alpine\"*) exit 0 ;;
  \"volume inspect myproject_mydata\") echo \"no such volume\" >&2; exit 1 ;;
  \"volume inspect mydata\") echo '{}'; echo \"mydata\" >> \"$VOLUME_INSPECTED\" ;;
  \"run --rm\"*) exit 0 ;;
  *) exit 0 ;;
esac
"
  rm -f "$MOCK_BIN/jq"  # use real jq
  source "$HOMELAB"
  require_root() { true; }

  mkdir -p "$SERVICES_DIR/nanit-bridge"
  touch "$SERVICES_DIR/nanit-bridge/.homelab-installed"
  touch "$SERVICES_DIR/nanit-bridge/docker-compose.yml"

  output=$(cmd_backup "nanit-bridge" 2>&1) || true

  if [[ -f "$VOLUME_INSPECTED" ]] && grep -q "mydata" "$VOLUME_INSPECTED"; then
    pass "backup: falls back to bare volume name"
  else
    fail "backup: did not fall back to bare volume name, got: $output"
  fi
else
  skip "backup (volume fallback): jq not installed locally"
fi

# ─── 21. cmd_list ───────────────────────────────────────────────────────────

echo -e "\n${BD}── cmd_list ──${CL}"
new_sandbox
mock_docker_default
mock_git_default
source "$HOMELAB"

mkdir -p "$SERVICES_DIR/nanit-bridge"
touch "$SERVICES_DIR/nanit-bridge/.homelab-installed"

output=$(cmd_list 2>&1) || true
if echo "$output" | grep -q "nanit-bridge"; then
  pass "list: shows installed service"
else
  fail "list: expected nanit-bridge, got: $output"
fi

# ─── 22. run_hook — file exists ─────────────────────────────────────────────

echo -e "\n${BD}── run_hook ──${CL}"
new_sandbox
mock_docker_default
source "$HOMELAB"

mkdir -p "$SERVICES_DIR/test-svc/scripts"
echo 'touch /tmp/homelab_hook_ran' > "$SERVICES_DIR/test-svc/scripts/post-install.sh"
# Note: file is NOT executable — run_hook should still work (uses bash, not -x)

rm -f /tmp/homelab_hook_ran
run_hook "test-svc" "post-install.sh" 2>/dev/null
if [[ -f /tmp/homelab_hook_ran ]]; then
  pass "run_hook: runs non-executable script with bash"
  rm -f /tmp/homelab_hook_ran
else
  fail "run_hook: script did not execute"
fi

# ─── 23. shift safety ──────────────────────────────────────────────────────

echo -e "\n${BD}── main dispatch (shift safety) ──${CL}"
new_sandbox
mock_docker_default
export PATH="$MOCK_BIN:$ORIG_PATH"

output=$(bash "$HOMELAB" 2>&1) || true
if echo "$output" | grep -q "homelab.*unified service management"; then
  pass "dispatch: no args defaults to help without shift error"
else
  fail "dispatch: got: $output"
fi

# ─── 24. source guard ──────────────────────────────────────────────────────

echo -e "\n${BD}── source guard ──${CL}"
new_sandbox
mock_docker_default

output=$(bash -c "source '$HOMELAB'; echo 'sourced ok'; trim '  x  '" 2>&1) || true
if echo "$output" | grep -q "sourced ok" && echo "$output" | grep -q "x"; then
  pass "source guard: script is sourceable without running dispatch"
else
  fail "source guard: got: $output"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Edge case & error-path tests
# ═══════════════════════════════════════════════════════════════════════════════

# ─── 25. trim() — additional edge cases ─────────────────────────────────────

echo -e "\n${BD}── trim() edge cases ──${CL}"
new_sandbox
mock_docker_default
source "$HOMELAB"

result=$(trim "   ")
[[ "$result" == "" ]] && pass "trim: only whitespace → empty" || fail "trim: expected '', got '$result'"

result=$(trim "x")
[[ "$result" == "x" ]] && pass "trim: single char" || fail "trim: expected 'x', got '$result'"

result=$(trim "  a  b  ")
[[ "$result" == "a  b" ]] && pass "trim: internal spaces preserved" || fail "trim: expected 'a  b', got '$result'"

# ─── 26. dotenv_escape() — additional edge cases ────────────────────────────

echo -e "\n${BD}── dotenv_escape() edge cases ──${CL}"

result=$(dotenv_escape '')
[[ "$result" == "" ]] && pass "dotenv_escape: empty string" || fail "dotenv_escape: expected '', got '$result'"

result=$(dotenv_escape '"')
[[ "$result" == '\"' ]] && pass "dotenv_escape: lone double quote" || fail "dotenv_escape: got '$result'"

result=$(dotenv_escape '\\')
[[ "$result" == '\\\\' ]] && pass "dotenv_escape: double backslash" || fail "dotenv_escape: got '$result'"

result=$(dotenv_escape '$$$')
[[ "$result" == '\$\$\$' ]] && pass "dotenv_escape: multiple dollar signs" || fail "dotenv_escape: got '$result'"

# ─── 27. cmd_install — unknown service ──────────────────────────────────────

echo -e "\n${BD}── cmd_install (error paths) ──${CL}"
new_sandbox
mock_docker_default
mock_git_default
source "$HOMELAB"
require_root() { true; }

output=$(cmd_install "no-such-service" 2>&1) || true
if echo "$output" | grep -qi "unknown service"; then
  pass "install: rejects unknown service"
else
  fail "install: expected 'Unknown service' error, got: $output"
fi

# ─── 28. cmd_install — missing argument ─────────────────────────────────────

COMMAND=install
output=$(cmd_install 2>&1) || true
if echo "$output" | grep -qi "usage"; then
  pass "install: errors on missing arg"
else
  fail "install: expected usage error, got: $output"
fi

# ─── 29. cmd_install — already fully installed (marker + running) ───────────

echo -e "\n${BD}── cmd_install (already installed) ──${CL}"
new_sandbox

mock_cmd docker '
case "$*" in
  "compose version") echo "Docker Compose version v2.24.0" ;;
  *"compose -f"*"ps -q"*) echo "container123" ;;
  *) exit 0 ;;
esac
'
mock_git_default
source "$HOMELAB"
require_root() { true; }

dest="$SERVICES_DIR/nanit-bridge"
mkdir -p "$dest"
touch "$dest/docker-compose.yml"
touch "$dest/.homelab-installed"

output=$(cmd_install "nanit-bridge" 2>&1) || true
if echo "$output" | grep -qi "already running\|use.*update"; then
  pass "install: blocks duplicate install of running service"
else
  fail "install: expected 'already running' error, got: $output"
fi

# ─── 30. cmd_install — git clone fails ──────────────────────────────────────

echo -e "\n${BD}── cmd_install (git clone fails) ──${CL}"
new_sandbox

mock_cmd docker '
case "$*" in
  "compose version") echo "Docker Compose version v2.24.0" ;;
  *"compose -f"*"ps -q"*) echo "" ;;
  *) exit 0 ;;
esac
'
mock_cmd git '
echo "fatal: repository not found" >&2
exit 128
'
source "$HOMELAB"
require_root() { true; }

output=$(cmd_install "nanit-bridge" 2>&1) || true
if echo "$output" | grep -qi "fatal\|git clone failed"; then
  pass "install: git clone failure is visible"
else
  fail "install: git clone error swallowed, got: $output"
fi

# ─── 31. cmd_remove — abort on N ────────────────────────────────────────────

echo -e "\n${BD}── cmd_remove (abort) ──${CL}"
new_sandbox

mock_cmd docker '
case "$*" in
  "compose version") echo "Docker Compose version v2.24.0" ;;
  *) exit 0 ;;
esac
'
source "$HOMELAB"
require_root() { true; }

dest="$SERVICES_DIR/nanit-bridge"
mkdir -p "$dest"
touch "$dest/.homelab-installed"
touch "$dest/docker-compose.yml"

call_count=0
prompt_user() {
  local -n _result=$1
  ((call_count++)) || true
  _result="n"  # decline everything
}

output=$(cmd_remove "nanit-bridge" 2>&1) || true
if echo "$output" | grep -qi "aborted"; then
  pass "remove: abort when user declines"
else
  fail "remove: expected 'Aborted', got: $output"
fi

# Verify nothing was removed
if [[ -f "$dest/.homelab-installed" ]]; then
  pass "remove: marker preserved on abort"
else
  fail "remove: marker was removed despite abort"
fi

# ─── 32. cmd_remove — delete directory + volumes ────────────────────────────

echo -e "\n${BD}── cmd_remove (delete everything) ──${CL}"
new_sandbox

COMPOSE_DOWN_ARGS="$SANDBOX/down_args.log"
mock_cmd docker "
case \"\$*\" in
  \"compose version\") echo \"Docker Compose version v2.24.0\" ;;
  *\"compose -f\"*\"down\"*)
    echo \"\$*\" >> \"$COMPOSE_DOWN_ARGS\"
    exit 0 ;;
  *) exit 0 ;;
esac
"
source "$HOMELAB"
require_root() { true; }

dest="$SERVICES_DIR/nanit-bridge"
mkdir -p "$dest"
touch "$dest/.homelab-installed"
touch "$dest/docker-compose.yml"

call_count=0
prompt_user() {
  local -n _result=$1
  ((call_count++)) || true
  _result="y"  # yes to everything
}

output=$(cmd_remove "nanit-bridge" 2>&1) || true

if [[ ! -d "$dest" ]]; then
  pass "remove: directory deleted when user says Y"
else
  fail "remove: directory still exists"
fi

if [[ -f "$COMPOSE_DOWN_ARGS" ]] && grep -q "\-v" "$COMPOSE_DOWN_ARGS"; then
  pass "remove: volumes removed with -v flag"
else
  fail "remove: expected down -v, got: $(cat "$COMPOSE_DOWN_ARGS" 2>/dev/null)"
fi

# ─── 33. Unknown command ────────────────────────────────────────────────────

echo -e "\n${BD}── dispatch (unknown command) ──${CL}"
new_sandbox
mock_docker_default
export PATH="$MOCK_BIN:$ORIG_PATH"

output=$(bash "$HOMELAB" frobnicate 2>&1) || true
if echo "$output" | grep -qi "unknown command"; then
  pass "dispatch: rejects unknown command"
else
  fail "dispatch: expected 'Unknown command' error, got: $output"
fi

# ─── 34. resolve_targets — no services installed ────────────────────────────

echo -e "\n${BD}── resolve_targets (empty) ──${CL}"
new_sandbox
mock_docker_default
source "$HOMELAB"
require_root() { true; }

output=$(cmd_update 2>&1) || true
if echo "$output" | grep -qi "no services installed"; then
  pass "resolve_targets: errors when no services"
else
  fail "resolve_targets: expected 'No services installed', got: $output"
fi

# ─── 35. installed_services — empty SERVICES_DIR ────────────────────────────

echo -e "\n${BD}── installed_services (empty dir) ──${CL}"
new_sandbox
mock_docker_default
source "$HOMELAB"

result=$(installed_services)
[[ -z "$result" ]] && pass "installed_services: empty dir → no output" || fail "installed_services: expected empty, got '$result'"

# ─── 36. run_hook — missing script (no-op) ──────────────────────────────────

echo -e "\n${BD}── run_hook (missing script) ──${CL}"
new_sandbox
mock_docker_default
source "$HOMELAB"

mkdir -p "$SERVICES_DIR/test-svc"
output=$(run_hook "test-svc" "nonexistent.sh" 2>&1) || true
[[ -z "$output" ]] && pass "run_hook: missing script is silent no-op" || fail "run_hook: expected no output, got '$output'"

# ─── 37. cmd_list — no services (shows available) ──────────────────────────

echo -e "\n${BD}── cmd_list (empty) ──${CL}"
new_sandbox
mock_docker_default
mock_git_default
source "$HOMELAB"

output=$(cmd_list 2>&1) || true
if echo "$output" | grep -qi "no services installed" && echo "$output" | grep -q "nanit-bridge"; then
  pass "list: empty shows available services from registry"
else
  fail "list: expected 'No services' + registry listing, got: $output"
fi

# ─── 38. cmd_status — compose returns garbage ───────────────────────────────

echo -e "\n${BD}── cmd_status (garbage JSON) ──${CL}"
new_sandbox

mock_cmd docker '
case "$*" in
  "compose version") echo "Docker Compose version v2.24.0" ;;
  *"compose -f"*"ps --format json"*) echo "not-valid-json{{{" ;;
  *) exit 0 ;;
esac
'

if command -v jq &>/dev/null; then
  rm -f "$MOCK_BIN/jq"  # use real jq
  source "$HOMELAB"

  mkdir -p "$SERVICES_DIR/broken-svc"
  touch "$SERVICES_DIR/broken-svc/.homelab-installed"

  # Should not crash — jq errors are non-fatal in this path
  output=$(cmd_status 2>&1) || true
  if [[ -n "$output" ]]; then
    pass "status: survives garbage JSON without crash"
  else
    fail "status: no output on garbage JSON"
  fi
else
  skip "status (garbage JSON): jq not installed locally"
fi

# ─── 39. cmd_status — multi-container service ───────────────────────────────

echo -e "\n${BD}── cmd_status (multi-container) ──${CL}"
new_sandbox

LINE1='{"Name":"app-web-1","State":"running","Health":"healthy","RunningFor":"1 hour ago","Publishers":[{"PublishedPort":80}]}'
LINE2='{"Name":"app-db-1","State":"running","Health":"","RunningFor":"1 hour ago","Publishers":[]}'

mock_cmd docker "
case \"\$*\" in
  \"compose version\") echo \"Docker Compose version v2.24.0\" ;;
  *\"compose -f\"*\"ps --format json\"*)
    echo '$LINE1'
    echo '$LINE2'
    ;;
  *) exit 0 ;;
esac
"

if command -v jq &>/dev/null; then
  rm -f "$MOCK_BIN/jq"
  source "$HOMELAB"

  mkdir -p "$SERVICES_DIR/app"
  touch "$SERVICES_DIR/app/.homelab-installed"

  output=$(cmd_status 2>&1) || true
  if echo "$output" | grep -q "app-web-1" && echo "$output" | grep -q "app-db-1"; then
    pass "status: shows all containers in multi-container service"
  else
    fail "status: expected both containers, got: $output"
  fi

  if echo "$output" | grep "app-db-1" | grep -q "\-"; then
    pass "status: empty health shows as '-'"
  else
    fail "status: empty health not handled"
  fi
else
  skip "status (multi-container): jq not installed locally"
fi

# ─── 40. cmd_backup — no volumes ────────────────────────────────────────────

echo -e "\n${BD}── cmd_backup (no volumes) ──${CL}"
new_sandbox
mock_docker_default  # config --volumes returns ""
source "$HOMELAB"
require_root() { true; }

mkdir -p "$SERVICES_DIR/nanit-bridge"
touch "$SERVICES_DIR/nanit-bridge/.homelab-installed"
touch "$SERVICES_DIR/nanit-bridge/docker-compose.yml"

output=$(cmd_backup "nanit-bridge" 2>&1) || true
if echo "$output" | grep -qi "no named volumes.*skipping"; then
  pass "backup: no volumes → skips gracefully"
else
  fail "backup: expected skip message, got: $output"
fi

# ─── 41. cmd_backup — volume not found at all ───────────────────────────────

echo -e "\n${BD}── cmd_backup (missing volume) ──${CL}"
new_sandbox

if command -v jq &>/dev/null; then
  mock_cmd docker "
case \"\$*\" in
  \"compose version\") echo \"Docker Compose version v2.24.0\" ;;
  *\"compose -f\"*\"config --volumes\"*) echo \"ghost_vol\" ;;
  *\"compose -f\"*\"config --format json\"*) echo '{\"name\":\"svc\"}' ;;
  \"image inspect alpine\"*) exit 0 ;;
  \"volume inspect\"*) echo \"no such volume\" >&2; exit 1 ;;
  *) exit 0 ;;
esac
"
  rm -f "$MOCK_BIN/jq"
  source "$HOMELAB"
  require_root() { true; }

  mkdir -p "$SERVICES_DIR/nanit-bridge"
  touch "$SERVICES_DIR/nanit-bridge/.homelab-installed"
  touch "$SERVICES_DIR/nanit-bridge/docker-compose.yml"

  output=$(cmd_backup "nanit-bridge" 2>&1) || true
  if echo "$output" | grep -qi "not found.*skipping"; then
    pass "backup: missing volume warns and skips"
  else
    fail "backup: expected 'not found — skipping', got: $output"
  fi
else
  skip "backup (missing volume): jq not installed locally"
fi

# ─── 42. generate_env — end-to-end with mocked prompts ─────────────────────

echo -e "\n${BD}── generate_env (end-to-end) ──${CL}"
new_sandbox
mock_docker_default
source "$HOMELAB"

svc_dir="$SERVICES_DIR/envtest"
mkdir -p "$svc_dir"
cat > "$svc_dir/.env.example" <<'ENVEX'
# Required
HOST=localhost # The hostname
DB_PASSWORD=  # Database password
API_KEY=  # Secret API key
# Optional
# OPTIONAL_VAR=default_val # An optional setting
ENVEX

# Mock prompt_user to return predictable values
prompt_count=0
prompt_user() {
  local -n _result=$1
  ((prompt_count++)) || true
  case $prompt_count in
    1) _result="myhost.local" ;;      # HOST
    2) _result='p@ss"w0rd\$pecial' ;; # DB_PASSWORD (special chars)
    3) _result="sk-12345" ;;           # API_KEY
    4) _result="" ;;                   # OPTIONAL_VAR (take default)
  esac
}

generate_env "envtest" 2>/dev/null

if [[ -f "$svc_dir/.env" ]]; then
  pass "generate_env: .env file created"
else
  fail "generate_env: .env file not created"
fi

env_content=$(cat "$svc_dir/.env")

if echo "$env_content" | grep -q 'HOST="myhost.local"'; then
  pass "generate_env: simple value written correctly"
else
  fail "generate_env: HOST not found, got: $env_content"
fi

if echo "$env_content" | grep -q 'DB_PASSWORD='; then
  pass "generate_env: password key present"
else
  fail "generate_env: DB_PASSWORD missing, got: $env_content"
fi

if echo "$env_content" | grep -q 'OPTIONAL_VAR='; then
  pass "generate_env: optional/commented var included"
else
  fail "generate_env: OPTIONAL_VAR missing, got: $env_content"
fi

# Verify the .env has the right number of variables
line_count=$(wc -l < "$svc_dir/.env" | tr -d ' ')
if [[ "$line_count" -eq 4 ]]; then
  pass "generate_env: correct variable count (4)"
else
  fail "generate_env: expected 4 lines, got $line_count"
fi

# ─── 43. generate_env — skip when no .env.example ──────────────────────────

echo -e "\n${BD}── generate_env (no example file) ──${CL}"
new_sandbox
mock_docker_default
source "$HOMELAB"

mkdir -p "$SERVICES_DIR/no-env"

output=$(generate_env "no-env" 2>&1) || true
if echo "$output" | grep -qi "no .env.example"; then
  pass "generate_env: warns when no .env.example"
else
  fail "generate_env: expected warning, got: $output"
fi

[[ ! -f "$SERVICES_DIR/no-env/.env" ]] && pass "generate_env: no .env created without example" || fail "generate_env: .env created from nothing"

# ─── 44. require_cmd / require_compose ──────────────────────────────────────

echo -e "\n${BD}── require_cmd / require_compose ──${CL}"
new_sandbox
mock_docker_default
source "$HOMELAB"

# require_cmd with a known command
require_cmd bash 2>/dev/null && pass "require_cmd: passes for installed command" || fail "require_cmd: rejected bash"

# require_cmd with a fake command
output=$(require_cmd "nonexistent_xyz_cmd" 2>&1) || true
if echo "$output" | grep -qi "required but not installed"; then
  pass "require_cmd: errors for missing command"
else
  fail "require_cmd: expected error, got: $output"
fi

# require_compose with mock docker
require_compose 2>/dev/null && pass "require_compose: passes with mock docker" || fail "require_compose: rejected mock docker"

# require_compose without docker — fully strip PATH so docker can't be found
new_sandbox
BASH4="$(command -v bash)"
export PATH="$MOCK_BIN:$(dirname "$BASH4"):/usr/bin:/bin"
source "$HOMELAB"
output=$(require_compose 2>&1) || true
export PATH="$MOCK_BIN:$ORIG_PATH"
if echo "$output" | grep -qi "docker.*required\|not installed"; then
  pass "require_compose: errors without docker"
else
  fail "require_compose: expected error, got: $output"
fi

# ─── 45. is_installed — both marker and compose present ─────────────────────

echo -e "\n${BD}── is_installed (both markers) ──${CL}"
new_sandbox
mock_docker_default
source "$HOMELAB"

mkdir -p "$SERVICES_DIR/svc-both"
touch "$SERVICES_DIR/svc-both/.homelab-installed"
touch "$SERVICES_DIR/svc-both/docker-compose.yml"
is_installed "svc-both" && pass "is_installed: both marker + compose works" || fail "is_installed: both markers rejected"

# ─── 46. cmd_update — not installed ─────────────────────────────────────────

echo -e "\n${BD}── cmd_update (not installed) ──${CL}"
new_sandbox
mock_docker_default
mock_git_default
source "$HOMELAB"
require_root() { true; }

output=$(cmd_update "nonexistent-svc" 2>&1) || true
if echo "$output" | grep -qi "not installed"; then
  pass "update: errors for non-installed service"
else
  fail "update: expected 'not installed' error, got: $output"
fi

# ─── 47. cmd_remove — not installed ─────────────────────────────────────────

echo -e "\n${BD}── cmd_remove (not installed) ──${CL}"

output=$(cmd_remove "nonexistent-svc" 2>&1) || true
if echo "$output" | grep -qi "not installed"; then
  pass "remove: errors for non-installed service"
else
  fail "remove: expected 'not installed' error, got: $output"
fi

# ─── 48. cmd_self_update — wget fails (network error) ──────────────────────

echo -e "\n${BD}── cmd_self_update (wget fails) ──${CL}"
new_sandbox
mock_cmd wget 'exit 1'
mock_docker_default
source "$HOMELAB"

output=$(cmd_self_update 2>&1) || true
if echo "$output" | grep -qi "download failed"; then
  pass "self-update: reports download failure"
else
  fail "self-update: expected 'Download failed', got: $output"
fi

# ─── 49. prompt_user — return code regression ───────────────────────────────

echo -e "\n${BD}── prompt_user (return code) ──${CL}"

# Regression test: the old pattern `[[ ... ]] && echo` returned 1 when the
# condition was false, killing the script under set -e. The fix uses
# `if [[ ... ]]; then echo; fi` which always returns 0.
# We can't test prompt_user directly (it reads /dev/tty), so we verify the
# fixed pattern survives set -e in a subprocess.

result=$(bash -c '
  set -euo pipefail
  # Mimics the fixed prompt_user ending
  test_fixed() {
    if [[ "${1:-}" == "--secret" ]]; then echo "newline"; fi
  }
  test_fixed           # no --secret — old code would exit here
  echo "survived"
' 2>&1) || true
if echo "$result" | grep -q "survived"; then
  pass "prompt_user: if-then pattern returns 0 without --secret (set -e safe)"
else
  fail "prompt_user: pattern still exits under set -e, got: $result"
fi

result=$(bash -c '
  set -euo pipefail
  test_fixed() {
    if [[ "${1:-}" == "--secret" ]]; then echo "newline"; fi
  }
  test_fixed --secret
  echo "survived"
' 2>&1) || true
if echo "$result" | grep -q "survived"; then
  pass "prompt_user: if-then pattern returns 0 with --secret (set -e safe)"
else
  fail "prompt_user: pattern fails with --secret, got: $result"
fi

# Verify the OLD pattern would have failed (proving the test catches the bug)
result=$(bash -c '
  set -euo pipefail
  test_broken() {
    [[ "${1:-}" == "--secret" ]] && echo "newline"
  }
  test_broken          # no --secret — should exit
  echo "survived"
' 2>&1) || true
if ! echo "$result" | grep -q "survived"; then
  pass "prompt_user: old && pattern correctly fails under set -e (regression proof)"
else
  fail "prompt_user: old pattern should have failed but didn't"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Tagged release support tests
# ═══════════════════════════════════════════════════════════════════════════════

# ─── 50. parse_service_arg — with version ────────────────────────────────────

echo -e "\n${BD}── parse_service_arg ──${CL}"
new_sandbox
mock_docker_default
source "$HOMELAB"

parse_service_arg "nanit-bridge@v1.2.0"
[[ "$SVC" == "nanit-bridge" ]] && pass "parse_service_arg: extracts service name" || fail "parse_service_arg: expected 'nanit-bridge', got '$SVC'"
[[ "$VERSION" == "v1.2.0" ]] && pass "parse_service_arg: extracts version" || fail "parse_service_arg: expected 'v1.2.0', got '$VERSION'"

parse_service_arg "nanit-bridge"
[[ "$SVC" == "nanit-bridge" ]] && pass "parse_service_arg: no-version service name" || fail "parse_service_arg: expected 'nanit-bridge', got '$SVC'"
[[ "$VERSION" == "" ]] && pass "parse_service_arg: no-version → empty" || fail "parse_service_arg: expected '', got '$VERSION'"

parse_service_arg ""
[[ "$SVC" == "" ]] && pass "parse_service_arg: empty arg → empty SVC" || fail "parse_service_arg: expected '', got '$SVC'"
[[ "$VERSION" == "" ]] && pass "parse_service_arg: empty arg → empty VERSION" || fail "parse_service_arg: expected '', got '$VERSION'"

parse_service_arg "svc@"
[[ "$SVC" == "svc" ]] && pass "parse_service_arg: trailing @ → empty version" || fail "parse_service_arg: expected 'svc', got '$SVC'"
[[ "$VERSION" == "" ]] && pass "parse_service_arg: trailing @ → empty VERSION" || fail "parse_service_arg: expected '', got '$VERSION'"

parse_service_arg "svc@v1@v2"
[[ "$SVC" == "svc" ]] && pass "parse_service_arg: multiple @ → first split" || fail "parse_service_arg: expected 'svc', got '$SVC'"
[[ "$VERSION" == "v1@v2" ]] && pass "parse_service_arg: multiple @ → rest as version" || fail "parse_service_arg: expected 'v1@v2', got '$VERSION'"

# ─── 51. current_ref — tag, branch, fallback ────────────────────────────────

echo -e "\n${BD}── current_ref ──${CL}"
new_sandbox

# Mock git to return a tag
mock_cmd git '
case "$*" in
  *"describe --tags --exact-match"*) echo "v1.0.0" ;;
  *) echo "[mock git] unhandled: $*" >&2; exit 0 ;;
esac
'
mock_docker_default
source "$HOMELAB"

mkdir -p "$SERVICES_DIR/test-svc"
result=$(current_ref "test-svc")
[[ "$result" == "v1.0.0" ]] && pass "current_ref: returns tag when on tag" || fail "current_ref: expected 'v1.0.0', got '$result'"

# Mock git to fail describe but return branch
new_sandbox
mock_cmd git '
case "$*" in
  *"describe --tags --exact-match"*) exit 1 ;;
  *"rev-parse --abbrev-ref HEAD"*) echo "main" ;;
  *) echo "[mock git] unhandled: $*" >&2; exit 0 ;;
esac
'
mock_docker_default
source "$HOMELAB"

mkdir -p "$SERVICES_DIR/test-svc"
result=$(current_ref "test-svc")
[[ "$result" == "main" ]] && pass "current_ref: falls back to branch" || fail "current_ref: expected 'main', got '$result'"

# Mock git to fail everything
new_sandbox
mock_cmd git 'exit 1'
mock_docker_default
source "$HOMELAB"

mkdir -p "$SERVICES_DIR/test-svc"
result=$(current_ref "test-svc")
[[ "$result" == "-" ]] && pass "current_ref: falls back to '-'" || fail "current_ref: expected '-', got '$result'"

# ─── 52. cmd_install with @version — fresh clone ────────────────────────────

echo -e "\n${BD}── cmd_install (fresh @version) ──${CL}"
new_sandbox

CLONE_ARGS_LOG="$SANDBOX/clone_args.log"
mock_cmd docker '
case "$*" in
  "compose version") echo "Docker Compose version v2.24.0" ;;
  *"compose -f"*"ps -q"*) echo "" ;;
  *"compose -f"*"up -d"*) exit 0 ;;
  *) exit 0 ;;
esac
'

mock_cmd git "
echo \"\$*\" >> \"$CLONE_ARGS_LOG\"
case \"\$*\" in
  clone*)
    dest=\"\${@: -1}\"
    mkdir -p \"\$dest\"
    printf 'version: \"3\"\nservices:\n  app:\n    image: alpine\n' > \"\$dest/docker-compose.yml\"
    echo \"Cloning into \${dest}...\"
    ;;
  *) exit 0 ;;
esac
"

source "$HOMELAB"
require_root() { true; }

output=$(cmd_install "nanit-bridge@v1.0.0" 2>&1) || true

if [[ -f "$CLONE_ARGS_LOG" ]] && grep -q "\-\-branch v1.0.0" "$CLONE_ARGS_LOG"; then
  pass "install@version: passes --branch to git clone"
else
  fail "install@version: expected --branch v1.0.0, got: $(cat "$CLONE_ARGS_LOG" 2>/dev/null)"
fi

if echo "$output" | grep -q "@ v1.0.0"; then
  pass "install@version: header shows version"
else
  fail "install@version: expected version in header, got: $output"
fi

if [[ -f "$SERVICES_DIR/nanit-bridge/.homelab-installed" ]]; then
  pass "install@version: marker created"
else
  fail "install@version: marker not created"
fi

# ─── 53. cmd_install with @version — resume path ────────────────────────────

echo -e "\n${BD}── cmd_install (resume @version) ──${CL}"
new_sandbox

GIT_CMDS_LOG="$SANDBOX/git_cmds.log"
mock_cmd docker '
case "$*" in
  "compose version") echo "Docker Compose version v2.24.0" ;;
  *"compose -f"*"ps -q"*) echo "orphan123" ;;
  *"compose -f"*"down"*) exit 0 ;;
  *"compose -f"*"up -d"*) exit 0 ;;
  *) exit 0 ;;
esac
'

mock_cmd git "
echo \"\$*\" >> \"$GIT_CMDS_LOG\"
case \"\$*\" in
  *\"fetch --depth 1 origin tag\"*) echo \"From https://...\" ;;
  *\"checkout\"*) echo \"HEAD is now at abc1234\" ;;
  *) exit 0 ;;
esac
"

source "$HOMELAB"
require_root() { true; }

dest="$SERVICES_DIR/nanit-bridge"
mkdir -p "$dest"
cat > "$dest/docker-compose.yml" <<'YML'
version: "3"
services:
  app:
    image: alpine
YML

output=$(cmd_install "nanit-bridge@v2.0.0" 2>&1) || true

if [[ -f "$GIT_CMDS_LOG" ]] && grep -q "fetch --depth 1 origin tag v2.0.0" "$GIT_CMDS_LOG"; then
  pass "install@version resume: fetches tag"
else
  fail "install@version resume: expected fetch tag, got: $(cat "$GIT_CMDS_LOG" 2>/dev/null)"
fi

if [[ -f "$GIT_CMDS_LOG" ]] && grep -q "checkout v2.0.0" "$GIT_CMDS_LOG"; then
  pass "install@version resume: checks out tag"
else
  fail "install@version resume: expected checkout, got: $(cat "$GIT_CMDS_LOG" 2>/dev/null)"
fi

if echo "$output" | grep -q "Checked out v2.0.0"; then
  pass "install@version resume: shows checkout message"
else
  fail "install@version resume: expected checkout msg, got: $output"
fi

# ─── 54. cmd_install without @version — unchanged behavior ──────────────────

echo -e "\n${BD}── cmd_install (no version, unchanged) ──${CL}"
new_sandbox

CLONE_ARGS_LOG="$SANDBOX/clone_args.log"
mock_cmd docker '
case "$*" in
  "compose version") echo "Docker Compose version v2.24.0" ;;
  *"compose -f"*"ps -q"*) echo "" ;;
  *"compose -f"*"up -d"*) exit 0 ;;
  *) exit 0 ;;
esac
'

mock_cmd git "
echo \"\$*\" >> \"$CLONE_ARGS_LOG\"
case \"\$*\" in
  clone*)
    dest=\"\${@: -1}\"
    mkdir -p \"\$dest\"
    printf 'version: \"3\"\nservices:\n  app:\n    image: alpine\n' > \"\$dest/docker-compose.yml\"
    ;;
  *) exit 0 ;;
esac
"

source "$HOMELAB"
require_root() { true; }

output=$(cmd_install "nanit-bridge" 2>&1) || true

if [[ -f "$CLONE_ARGS_LOG" ]] && ! grep -q "\-\-branch" "$CLONE_ARGS_LOG"; then
  pass "install (no version): no --branch flag in clone"
else
  fail "install (no version): unexpected --branch in clone args: $(cat "$CLONE_ARGS_LOG" 2>/dev/null)"
fi

# ─── 55. cmd_update with @version ────────────────────────────────────────────

echo -e "\n${BD}── cmd_update (@version) ──${CL}"
new_sandbox

GIT_CMDS_LOG="$SANDBOX/git_cmds.log"
mock_cmd docker '
case "$*" in
  "compose version") echo "Docker Compose version v2.24.0" ;;
  *"compose -f"*"ps -q"*) echo "running123" ;;
  *"compose -f"*"up -d"*) exit 0 ;;
  *) exit 0 ;;
esac
'

mock_cmd git "
echo \"\$*\" >> \"$GIT_CMDS_LOG\"
case \"\$*\" in
  *\"fetch --depth 1 origin tag\"*) echo \"From https://...\" ;;
  *\"checkout\"*) echo \"HEAD is now at abc1234\" ;;
  *) exit 0 ;;
esac
"

source "$HOMELAB"
require_root() { true; }

mkdir -p "$SERVICES_DIR/nanit-bridge"
touch "$SERVICES_DIR/nanit-bridge/.homelab-installed"
touch "$SERVICES_DIR/nanit-bridge/docker-compose.yml"

output=$(cmd_update "nanit-bridge@v3.0.0" 2>&1) || true

if [[ -f "$GIT_CMDS_LOG" ]] && grep -q "fetch --depth 1 origin tag v3.0.0" "$GIT_CMDS_LOG"; then
  pass "update@version: fetches tag"
else
  fail "update@version: expected fetch tag, got: $(cat "$GIT_CMDS_LOG" 2>/dev/null)"
fi

if [[ -f "$GIT_CMDS_LOG" ]] && grep -q "checkout v3.0.0" "$GIT_CMDS_LOG"; then
  pass "update@version: checks out tag"
else
  fail "update@version: expected checkout, got: $(cat "$GIT_CMDS_LOG" 2>/dev/null)"
fi

if echo "$output" | grep -q "Checked out v3.0.0"; then
  pass "update@version: shows checkout message"
else
  fail "update@version: expected checkout msg, got: $output"
fi

if echo "$output" | grep -q "→ v3.0.0"; then
  pass "update@version: header shows target version"
else
  fail "update@version: expected version in header, got: $output"
fi

# ─── 56. cmd_update without @version — unchanged ────────────────────────────

echo -e "\n${BD}── cmd_update (no version, unchanged) ──${CL}"
new_sandbox

GIT_CMDS_LOG="$SANDBOX/git_cmds.log"
mock_cmd docker '
case "$*" in
  "compose version") echo "Docker Compose version v2.24.0" ;;
  *"compose -f"*"ps -q"*) echo "running123" ;;
  *"compose -f"*"up -d"*) exit 0 ;;
  *) exit 0 ;;
esac
'

mock_cmd git "
echo \"\$*\" >> \"$GIT_CMDS_LOG\"
case \"\$*\" in
  *\"pull --ff-only\"*) echo \"Already up to date.\" ;;
  *) exit 0 ;;
esac
"

source "$HOMELAB"
require_root() { true; }

mkdir -p "$SERVICES_DIR/nanit-bridge"
touch "$SERVICES_DIR/nanit-bridge/.homelab-installed"
touch "$SERVICES_DIR/nanit-bridge/docker-compose.yml"

output=$(cmd_update "nanit-bridge" 2>&1) || true

if [[ -f "$GIT_CMDS_LOG" ]] && grep -q "pull --ff-only" "$GIT_CMDS_LOG"; then
  pass "update (no version): uses pull --ff-only"
else
  fail "update (no version): expected pull --ff-only, got: $(cat "$GIT_CMDS_LOG" 2>/dev/null)"
fi

if [[ -f "$GIT_CMDS_LOG" ]] && ! grep -q "fetch.*tag\|checkout" "$GIT_CMDS_LOG"; then
  pass "update (no version): no tag fetch/checkout"
else
  fail "update (no version): unexpected tag operations: $(cat "$GIT_CMDS_LOG" 2>/dev/null)"
fi

# ─── 57. cmd_versions — tags found ──────────────────────────────────────────

echo -e "\n${BD}── cmd_versions ──${CL}"
new_sandbox

mock_cmd git '
case "$*" in
  "ls-remote --tags --refs"*)
    echo "abc123	refs/tags/v1.0.0"
    echo "def456	refs/tags/v1.1.0"
    echo "ghi789	refs/tags/v2.0.0"
    ;;
  *"describe --tags --exact-match"*) echo "v1.1.0" ;;
  *) exit 0 ;;
esac
'
mock_docker_default
source "$HOMELAB"

COMMAND=versions
mkdir -p "$SERVICES_DIR/nanit-bridge"
touch "$SERVICES_DIR/nanit-bridge/.homelab-installed"

output=$(cmd_versions "nanit-bridge" 2>&1) || true

if echo "$output" | grep -q "v2.0.0" && echo "$output" | grep -q "v1.1.0" && echo "$output" | grep -q "v1.0.0"; then
  pass "versions: lists all tags"
else
  fail "versions: expected all tags, got: $output"
fi

if echo "$output" | grep "v1.1.0" | grep -q "installed"; then
  pass "versions: marks installed version"
else
  fail "versions: expected '← installed' on v1.1.0, got: $output"
fi

# ─── 58. cmd_versions — no tags ─────────────────────────────────────────────

echo -e "\n${BD}── cmd_versions (no tags) ──${CL}"
new_sandbox

mock_cmd git '
case "$*" in
  "ls-remote --tags --refs"*) echo "" ;;
  *) exit 0 ;;
esac
'
mock_docker_default
source "$HOMELAB"

COMMAND=versions
output=$(cmd_versions "nanit-bridge" 2>&1) || true

if echo "$output" | grep -qi "no tagged releases"; then
  pass "versions: handles no tags gracefully"
else
  fail "versions: expected 'No tagged releases', got: $output"
fi

# ─── 59. cmd_versions — unknown service ──────────────────────────────────────

echo -e "\n${BD}── cmd_versions (unknown service) ──${CL}"

output=$(cmd_versions "no-such-svc" 2>&1) || true
if echo "$output" | grep -qi "unknown service"; then
  pass "versions: rejects unknown service"
else
  fail "versions: expected 'Unknown service', got: $output"
fi

# ─── 60. cmd_versions — missing argument ─────────────────────────────────────

COMMAND=versions
output=$(cmd_versions 2>&1) || true
if echo "$output" | grep -qi "usage"; then
  pass "versions: errors on missing arg"
else
  fail "versions: expected usage error, got: $output"
fi

# ─── 61. cmd_status — VERSION column present ─────────────────────────────────

echo -e "\n${BD}── cmd_status (VERSION column) ──${CL}"
new_sandbox

mock_cmd docker '
case "$*" in
  "compose version") echo "Docker Compose version v2.24.0" ;;
  *"compose -f"*"ps --format json"*) echo "[]" ;;
  *) exit 0 ;;
esac
'
mock_cmd git '
case "$*" in
  *"describe --tags --exact-match"*) echo "v1.0.0" ;;
  *) exit 0 ;;
esac
'
mock_jq_default
source "$HOMELAB"

mkdir -p "$SERVICES_DIR/test-svc"
touch "$SERVICES_DIR/test-svc/.homelab-installed"

output=$(cmd_status 2>&1) || true
if echo "$output" | grep -q "VERSION"; then
  pass "status: VERSION column in header"
else
  fail "status: expected VERSION header, got: $output"
fi

if echo "$output" | grep -q "v1.0.0"; then
  pass "status: shows version for service"
else
  fail "status: expected version in row, got: $output"
fi

# ─── 62. cmd_list — VERSION column present ───────────────────────────────────

echo -e "\n${BD}── cmd_list (VERSION column) ──${CL}"
new_sandbox

mock_cmd git '
case "$*" in
  *"describe --tags --exact-match"*) echo "v2.0.0" ;;
  *"remote get-url origin"*) echo "https://github.com/test/repo.git" ;;
  *) exit 0 ;;
esac
'
mock_docker_default
source "$HOMELAB"

mkdir -p "$SERVICES_DIR/test-svc"
touch "$SERVICES_DIR/test-svc/.homelab-installed"

output=$(cmd_list 2>&1) || true
if echo "$output" | grep -q "VERSION"; then
  pass "list: VERSION column in header"
else
  fail "list: expected VERSION header, got: $output"
fi

if echo "$output" | grep -q "v2.0.0"; then
  pass "list: shows version for service"
else
  fail "list: expected version in row, got: $output"
fi

# ─── 63. cmd_help — shows @version syntax ───────────────────────────────────

echo -e "\n${BD}── cmd_help (@version syntax) ──${CL}"
new_sandbox
mock_docker_default
source "$HOMELAB"

output=$(cmd_help 2>&1) || true
if echo "$output" | grep -q "@version"; then
  pass "help: shows @version syntax"
else
  fail "help: expected @version in output, got: $output"
fi

if echo "$output" | grep -q "versions"; then
  pass "help: lists versions command"
else
  fail "help: expected 'versions' command in help, got: $output"
fi

# ─── 64. dispatch — versions command reachable ───────────────────────────────

echo -e "\n${BD}── dispatch (versions command) ──${CL}"
new_sandbox
mock_docker_default
mock_cmd git '
case "$*" in
  "ls-remote --tags --refs"*)
    echo "abc123	refs/tags/v1.0.0"
    ;;
  *) exit 0 ;;
esac
'
export PATH="$MOCK_BIN:$ORIG_PATH"

output=$(bash "$HOMELAB" versions nanit-bridge 2>&1) || true
if echo "$output" | grep -q "v1.0.0\|Available versions"; then
  pass "dispatch: 'versions' command works via CLI"
else
  fail "dispatch: expected versions output, got: $output"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Security quick-win tests
# ═══════════════════════════════════════════════════════════════════════════════

# ─── 65. validate_service_name — valid names ─────────────────────────────────

echo -e "\n${BD}── validate_service_name ──${CL}"
new_sandbox
mock_docker_default
source "$HOMELAB"

validate_service_name "nanit-bridge" 2>/dev/null && pass "validate_service_name: hyphenated name" || fail "validate_service_name: rejected 'nanit-bridge'"
validate_service_name "my_svc" 2>/dev/null && pass "validate_service_name: underscored name" || fail "validate_service_name: rejected 'my_svc'"
validate_service_name "svc123" 2>/dev/null && pass "validate_service_name: alphanumeric name" || fail "validate_service_name: rejected 'svc123'"
validate_service_name "A" 2>/dev/null && pass "validate_service_name: single char" || fail "validate_service_name: rejected 'A'"

# ─── 66. validate_service_name — bad names ───────────────────────────────────

output=$(validate_service_name "../etc" 2>&1) || true
if echo "$output" | grep -qi "invalid service name"; then
  pass "validate_service_name: rejects path traversal '../etc'"
else
  fail "validate_service_name: accepted '../etc', got: $output"
fi

output=$(validate_service_name "svc name" 2>&1) || true
if echo "$output" | grep -qi "invalid service name"; then
  pass "validate_service_name: rejects space in name"
else
  fail "validate_service_name: accepted 'svc name', got: $output"
fi

output=$(validate_service_name "svc;rm" 2>&1) || true
if echo "$output" | grep -qi "invalid service name"; then
  pass "validate_service_name: rejects semicolon injection"
else
  fail "validate_service_name: accepted 'svc;rm', got: $output"
fi

output=$(validate_service_name 'svc$(cmd)' 2>&1) || true
if echo "$output" | grep -qi "invalid service name"; then
  pass "validate_service_name: rejects command substitution"
else
  fail "validate_service_name: accepted 'svc\$(cmd)', got: $output"
fi

output=$(validate_service_name "" 2>&1) || true
if echo "$output" | grep -qi "invalid service name"; then
  pass "validate_service_name: rejects empty string"
else
  fail "validate_service_name: accepted empty string, got: $output"
fi

# ─── 67. parse_service_arg validates service name ────────────────────────────

echo -e "\n${BD}── parse_service_arg (validation) ──${CL}"

output=$(parse_service_arg "../etc@v1" 2>&1) || true
if echo "$output" | grep -qi "invalid service name"; then
  pass "parse_service_arg: rejects bad name in service@version"
else
  fail "parse_service_arg: accepted '../etc@v1', got: $output"
fi

# ─── 68. .env file permissions ───────────────────────────────────────────────

echo -e "\n${BD}── generate_env (.env permissions) ──${CL}"
new_sandbox
mock_docker_default
source "$HOMELAB"

svc_dir="$SERVICES_DIR/permtest"
mkdir -p "$svc_dir"
cat > "$svc_dir/.env.example" <<'ENVEX'
# Required
MY_VAR=default
ENVEX

prompt_user() {
  local -n _result=$1
  _result="testval"
}

generate_env "permtest" 2>/dev/null

if [[ -f "$svc_dir/.env" ]]; then
  perms=$(stat -f "%Lp" "$svc_dir/.env" 2>/dev/null || stat -c "%a" "$svc_dir/.env" 2>/dev/null)
  if [[ "$perms" == "600" ]]; then
    pass ".env permissions: file created with mode 600"
  else
    fail ".env permissions: expected 600, got $perms"
  fi
else
  fail ".env permissions: .env file not created"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo -e "\n${BD}═══════════════════════════════${CL}"
echo -e " ${GN}Passed: $PASS${CL}  ${RD}Failed: $FAIL${CL}  ${YW}Skipped: $SKIP${CL}"
echo -e "${BD}═══════════════════════════════${CL}\n"

[[ $FAIL -eq 0 ]]
