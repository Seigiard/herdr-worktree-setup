#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="${PLUGIN_UNDER_TEST:-$ROOT/setup.ts}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/herdr-worktree-setup-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

new_repository() {
  local root="$1" remote="$2"
  mkdir -p "$root"
  git -C "$root" init --quiet -b main
  git -C "$root" config user.email test@example.com
  git -C "$root" config user.name 'Test User'
  printf '%s\n' tracked > "$root/tracked"
  printf '%s\n' secret > "$root/.env"
  git -C "$root" add tracked
  git -C "$root" commit --quiet -m initial
  git -C "$root" remote add origin "$remote"
}

marker_path() {
  git -C "$1" rev-parse --path-format=absolute --git-path herdr-generated-worktree
}

setup_status_path() {
  git -C "$1" rev-parse --path-format=absolute --git-path herdr-worktree-setup
}

run_setup() {
  local config="$1" worktree="$2" branch="$3"
  HERDR_PLUGIN_CONFIG_DIR="$config" \
    HERDR_PLUGIN_EVENT_JSON="{\"data\":{\"worktree\":{\"path\":\"$worktree\",\"branch\":\"$branch\"}}}" \
    bun "$PLUGIN"
}

test_configured_setup() {
  local root="$WORK/configured" main="$WORK/configured/main" worktree="$WORK/configured/feature" config="$WORK/configured/config"
  new_repository "$main" git@github.com:membranehq/platform.git
  mkdir -p "$config"
  git -C "$main" worktree add --quiet -b feature "$worktree"
  cat > "$config/config.toml" <<'TOML'
[projects."github.com/membranehq/platform"]
fresh-base = false
copy = [".env"]
steps = ["printf '%s' \"$HERDR_BRANCH\" > setup-ran"]
TOML

  run_setup "$config" "$worktree" feature >/dev/null
  [[ $(<"$worktree/.env") == secret ]] || fail 'configured setup copies policy files'
  [[ $(<"$worktree/setup-ran") == feature ]] || fail 'configured setup exports branch to steps'
  [[ $(<"$(marker_path "$worktree")") == feature ]] || fail 'configured setup records generated marker'
  pass 'configured setup copies files, runs steps, and records the marker'
}

test_running_setup_status() {
  local main="$WORK/status-lifecycle/main" worktree="$WORK/status-lifecycle/feature" config="$WORK/status-lifecycle/config"
  new_repository "$main" git@github.com:membranehq/platform.git
  mkdir -p "$config"
  git -C "$main" worktree add --quiet -b feature "$worktree"
  cat > "$config/config.toml" <<'TOML'
[projects."github.com/membranehq/platform"]
steps = ["status=$(git rev-parse --path-format=absolute --git-path herdr-worktree-setup); if [ -f \"$status\" ]; then cat \"$status\" > setup-status-during; else : > setup-status-missing; fi; printf '%s\\n' \"$PPID\" > setup-shell-parent"]
TOML

  local before after running_line shell_parent running_pid running_time
  before="$(bun -e 'console.log(Date.now())')"
  run_setup "$config" "$worktree" feature >/dev/null
  after="$(bun -e 'console.log(Date.now())')"

  [[ ! -e "$worktree/setup-status-missing" ]] || fail 'configured step reads the running setup status file'
  [[ -f "$worktree/setup-status-during" ]] || fail 'configured step records the running setup status file'
  [[ $(wc -l < "$worktree/setup-status-during") -eq 1 ]] || fail 'running setup status has exactly one line'
  running_line="$(<"$worktree/setup-status-during")"
  [[ "$running_line" =~ ^running\ ([0-9]+)\ ([0-9]+)$ ]] || fail 'running setup status has the consumer format'
  running_pid="${BASH_REMATCH[1]}"
  running_time="${BASH_REMATCH[2]}"
  shell_parent="$(<"$worktree/setup-shell-parent")"
  [[ "$running_pid" == "$shell_parent" ]] || fail 'running setup status identifies the setup process'
  (( running_time >= before && running_time <= after )) || fail 'running setup status timestamp is within the setup window'

  pass 'configured setup records running status for agent hooks'
}

test_successful_setup_records_final_status() {
  local main="$WORK/status-success/main" worktree="$WORK/status-success/feature" config="$WORK/status-success/config"
  new_repository "$main" git@github.com:membranehq/platform.git
  mkdir -p "$config"
  git -C "$main" worktree add --quiet -b feature "$worktree"
  cat > "$config/config.toml" <<'TOML'
[projects."github.com/membranehq/platform"]
steps = ["bun -e 'console.log(Date.now())' > setup-step-start"]
TOML

  local status after start_time done_line done_time
  status="$(setup_status_path "$worktree")"
  run_setup "$config" "$worktree" feature >/dev/null
  after="$(bun -e 'console.log(Date.now())')"

  [[ -f "$worktree/setup-step-start" ]] || fail 'successful setup completes its configured step'
  start_time="$(<"$worktree/setup-step-start")"
  [[ "$start_time" =~ ^[0-9]+$ ]] || fail 'successful setup step records its wall-clock start'
  [[ -f "$status" ]] || fail 'successful setup records a final status file'
  [[ $(wc -l < "$status") -eq 1 ]] || fail 'final setup status has exactly one line'
  done_line="$(<"$status")"
  [[ "$done_line" =~ ^done\ 0\ ([0-9]+)$ ]] || fail 'successful setup records done 0'
  done_time="${BASH_REMATCH[1]}"
  (( done_time >= start_time && done_time <= after )) || fail 'final setup status timestamp follows the completed step'
  pass 'successful setup records final status for agent hooks'
}

test_failed_step_records_setup_status() {
  local main="$WORK/status-failure/main" worktree="$WORK/status-failure/feature" config="$WORK/status-failure/config"
  new_repository "$main" git@github.com:membranehq/platform.git
  mkdir -p "$config"
  git -C "$main" worktree add --quiet -b feature "$worktree"
  cat > "$config/config.toml" <<'TOML'
[projects."github.com/membranehq/platform"]
steps = ["exit 7", "touch later-step"]
TOML

  local status exit_code
  status="$(setup_status_path "$worktree")"
  if run_setup "$config" "$worktree" feature >/dev/null 2>&1; then
    fail 'a failed setup step must fail the plugin'
  else
    exit_code=$?
  fi
  [[ "$exit_code" == 1 ]] || fail 'a failed setup step returns status 1'
  [[ -f "$status" ]] || fail 'a failed setup step records a final status file'
  [[ $(wc -l < "$status") -eq 1 ]] || fail 'failed setup status has exactly one line'
  [[ $(<"$status") =~ ^done\ 7\ [0-9]+$ ]] || fail 'a failed setup step records done 7'
  [[ ! -e "$worktree/later-step" ]] || fail 'a failed setup step prevents later steps'
  pass 'failed setup steps record their exit code and stop the plugin'
}

test_setup_exception_records_failure_status() {
  local main="$WORK/status-exception/main" worktree="$WORK/status-exception/feature" config="$WORK/status-exception/config"
  new_repository "$main" git@github.com:membranehq/platform.git
  mkdir -p "$config"
  git -C "$main" worktree add --quiet -b feature "$worktree"
  ln -s "$WORK/status-exception/outside" "$worktree/.env"
  cat > "$config/config.toml" <<'TOML'
[projects."github.com/membranehq/platform"]
copy = [".env"]
steps = ["touch step-must-not-run"]
TOML

  local status exit_code
  status="$(setup_status_path "$worktree")"
  if run_setup "$config" "$worktree" feature >/dev/null 2>&1; then
    fail 'a setup exception must fail the plugin'
  else
    exit_code=$?
  fi
  [[ "$exit_code" == 1 ]] || fail 'a setup exception returns status 1'
  [[ -f "$status" ]] || fail 'a setup exception records a final status file'
  [[ $(wc -l < "$status") -eq 1 ]] || fail 'exception setup status has exactly one line'
  [[ $(<"$status") =~ ^done\ 1\ [0-9]+$ ]] || fail 'a setup exception records done 1'
  [[ ! -e "$worktree/step-must-not-run" ]] || fail 'a setup exception prevents configured steps'
  pass 'setup exceptions after startup record done 1 for agent hooks'
}

test_unconfigured_repository() {
  local root="$WORK/unconfigured" origin="$WORK/unconfigured/origin.git" main="$WORK/unconfigured/main" worktree="$WORK/unconfigured/feature" config="$WORK/unconfigured/config"
  mkdir -p "$root" "$config"
  git init --quiet --bare "$origin"
  git -C "$origin" symbolic-ref HEAD refs/heads/main
  new_repository "$main" "$origin"
  git -C "$main" push --quiet -u origin main
  git -C "$main" worktree add --quiet -b feature "$worktree"
  local old
  old="$(git -C "$worktree" rev-parse HEAD)"
  printf '%s\n' changed > "$main/tracked"
  git -C "$main" commit --quiet -am changed
  git -C "$main" push --quiet
  cat > "$config/config.toml" <<'TOML'
[projects."other/repository"]
fresh-base = true
copy = [".env"]
steps = ["touch setup-ran"]

[projects."other/invalid"]
copy = [42]
steps = [""]
TOML

  run_setup "$config" "$worktree" feature >/dev/null
  [[ ! -e "$worktree/setup-ran" ]] || fail 'unconfigured repository does not run setup steps'
  [[ ! -e "$worktree/.env" ]] || fail 'unconfigured repository does not copy policy files'
  [[ $(git -C "$worktree" rev-parse HEAD) == "$old" ]] || fail 'unconfigured repository does not refresh fresh-base'
  [[ $(<"$(marker_path "$worktree")") == feature ]] || fail 'unconfigured repository still records lifecycle marker'
  [[ ! -e "$(setup_status_path "$worktree")" ]] || fail 'unconfigured repository has no setup status file'
  pass 'unconfigured repositories receive no policy or fresh-base mutation'
}

test_fresh_base() {
  local root="$WORK/fresh" origin="$WORK/fresh/origin.git" main="$WORK/fresh/main" worktree="$WORK/fresh/feature" dirty="$WORK/fresh/dirty" config="$WORK/fresh/config"
  mkdir -p "$root" "$config"
  git init --quiet --bare "$origin"
  git -C "$origin" symbolic-ref HEAD refs/heads/main
  new_repository "$main" "$origin"
  git -C "$main" push --quiet -u origin main
  git -C "$main" worktree add --quiet -b feature "$worktree"
  local old
  old="$(git -C "$worktree" rev-parse HEAD)"
  git -C "$main" worktree add --quiet -b dirty "$dirty" "$old"
  printf '%s\n' local > "$dirty/untracked"
  printf '%s\n' new > "$main/tracked"
  git -C "$main" commit --quiet -am new
  git -C "$main" push --quiet
  local expected
  expected="$(git -C "$main" rev-parse HEAD)"
  cat > "$config/config.toml" <<TOML
[projects."${origin%.git}"]
fresh-base = true
TOML

  run_setup "$config" "$worktree" feature >/dev/null
  [[ $(git -C "$worktree" rev-parse HEAD) == "$expected" ]] || fail 'fresh-base resets an eligible new branch'
  [[ ! -e "$(setup_status_path "$worktree")" ]] || fail 'a project without steps has no setup status file'
  run_setup "$config" "$dirty" dirty >/dev/null
  [[ $(git -C "$dirty" rev-parse HEAD) == "$old" ]] || fail 'fresh-base preserves a dirty worktree'
  pass 'fresh-base resets only eligible untouched branches'
}

test_invalid_events() {
  local event output status
  for event in 'null' '{}' '{"data":{"worktree":{"path":""}}}' '{"data":{"worktree":{"path":42}}}'; do
    if output="$(HERDR_PLUGIN_EVENT_JSON="$event" bun "$PLUGIN" 2>&1)"; then
      fail "invalid event must fail: $event"
    else
      status=$?
    fi
    [[ "$status" == 1 ]] || fail 'invalid event returns status 1'
    [[ "$output" == '[worktree-setup] error: worktree.created event has no worktree path' ]] || fail 'invalid event reports the missing path'
  done
  if output="$(HERDR_PLUGIN_EVENT_JSON='{' bun "$PLUGIN" 2>&1)"; then
    fail 'malformed JSON must fail'
  else
    status=$?
  fi
  [[ "$status" == 1 ]] || fail 'malformed JSON returns status 1'
  [[ "$output" == '[worktree-setup] error: invalid HERDR_PLUGIN_EVENT_JSON: '* ]] || fail 'malformed JSON reports the JSON boundary'
  pass 'invalid event values and malformed JSON fail at the input boundary'
}

test_invalid_policy() {
  local main="$WORK/invalid/main" worktree="$WORK/invalid/feature" config="$WORK/invalid/config"
  new_repository "$main" git@github.com:membranehq/platform.git
  mkdir -p "$config"
  git -C "$main" worktree add --quiet -b feature "$worktree"
  local policy output status
  for policy in 'copy = "not-an-array"' 'copy = [42]' 'steps = "not-an-array"' 'steps = [42]' 'steps = [""]'; do
    printf '[projects."github.com/membranehq/platform"]\n%s\n' "$policy" > "$config/config.toml"
    if output="$(run_setup "$config" "$worktree" feature 2>&1)"; then
      fail "invalid policy must fail: $policy"
    else
      status=$?
    fi
    [[ "$status" == 1 ]] || fail 'invalid policy returns status 1'
    case "$policy" in
      copy*) [[ "$output" == '[worktree-setup] error: copy must be an array of relative file paths' ]] || fail 'invalid copy reports its contract' ;;
      steps*) [[ "$output" == '[worktree-setup] error: steps must be an array of non-empty shell commands' ]] || fail 'invalid steps reports its contract' ;;
    esac
  done
  printf '[projects."github.com/membranehq/platform"]\ncopy = [".env"]\nsteps = [42]\n' > "$config/config.toml"
  if run_setup "$config" "$worktree" feature >/dev/null 2>&1; then
    fail 'invalid steps must fail before copying policy files'
  fi
  [[ ! -e "$worktree/.env" ]] || fail 'decoding rejects invalid policy before copying'
  [[ $(<"$(marker_path "$worktree")") == feature ]] || fail 'invalid policy still records lifecycle marker'
  pass 'invalid copy and steps are rejected before setup mutations'
}

test_copy_destination_symlinks() {
  local main="$WORK/symlink/main" worktree="$WORK/symlink/feature" config="$WORK/symlink/config"
  new_repository "$main" git@github.com:membranehq/platform.git
  mkdir -p "$config"
  git -C "$main" worktree add --quiet -b feature "$worktree"
  local escaped="$WORK/symlink/leaked-secret" output status
  ln -s "$escaped" "$worktree/.env"
  printf '[projects."github.com/membranehq/platform"]\ncopy = [".env"]\n' > "$config/config.toml"
  if output="$(run_setup "$config" "$worktree" feature 2>&1)"; then
    fail 'dangling destination symlink must fail'
  else
    status=$?
  fi
  [[ "$status" == 1 ]] || fail 'destination symlink returns status 1'
  [[ ! -e "$escaped" ]] || fail 'destination symlink must not leak secrets outside worktree'
  rm "$worktree/.env"
  mkdir -p "$main/nested" "$WORK/symlink/outside"
  printf '%s\n' secret > "$main/nested/.env"
  ln -s "$WORK/symlink/outside" "$worktree/nested"
  printf '[projects."github.com/membranehq/platform"]\ncopy = ["nested/.env"]\n' > "$config/config.toml"
  if output="$(run_setup "$config" "$worktree" feature 2>&1)"; then
    fail 'destination ancestor symlink must fail'
  else
    status=$?
  fi
  [[ "$status" == 1 ]] || fail 'destination ancestor symlink returns status 1'
  [[ ! -e "$WORK/symlink/outside/.env" ]] || fail 'destination ancestor symlink must not leak secrets'
  pass 'copy rejects dangling destination symlinks and symlink ancestors'
}

test_detached_event() {
  local main="$WORK/detached/main" config="$WORK/detached/config"
  new_repository "$main" git@github.com:membranehq/platform.git
  mkdir -p "$config"
  printf '[projects."github.com/membranehq/platform"]\nsteps = ["printf %%s \\\"$HERDR_BRANCH\\\" > branch-value"]\n' > "$config/config.toml"
  local branch
  for branch in '' ',"branch":42' ',"branch":null'; do
    rm -f "$main/branch-value"
    HERDR_PLUGIN_CONFIG_DIR="$config" HERDR_PLUGIN_EVENT_JSON="{\"data\":{\"worktree\":{\"path\":\"$main\"$branch}}}" bun "$PLUGIN" >/dev/null
    [[ -f "$main/branch-value" ]] || fail 'detached event runs the configured step'
    [[ $(<"$main/branch-value") == '' ]] || fail 'missing or invalid branch becomes detached'
    [[ ! -e "$(marker_path "$main")" ]] || fail 'detached event does not record branch marker'
  done
  pass 'missing and non-string branches remain detached events'
}

if (( $# > 0 )); then
  for test_name in "$@"; do
    "$test_name"
  done
else
  test_configured_setup
  test_running_setup_status
  test_successful_setup_records_final_status
  test_failed_step_records_setup_status
  test_setup_exception_records_failure_status
  test_unconfigured_repository
  test_fresh_base
  test_copy_destination_symlinks
  test_invalid_policy
  test_invalid_events
  test_detached_event
fi
