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

test_configured_setup
test_unconfigured_repository
test_fresh_base
test_copy_destination_symlinks
test_invalid_policy
test_invalid_events
test_detached_event
