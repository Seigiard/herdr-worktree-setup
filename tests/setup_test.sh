#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="$ROOT/setup.ts"
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
  local root="$WORK/unconfigured" main="$WORK/unconfigured/main" worktree="$WORK/unconfigured/feature" config="$WORK/unconfigured/config"
  new_repository "$main" https://github.com/example/repository.git
  mkdir -p "$config"
  git -C "$main" worktree add --quiet -b feature "$worktree"
  cat > "$config/config.toml" <<'TOML'
[projects."github.com/another/repository"]
fresh-base = true
copy = [".env"]
steps = ["touch setup-ran"]
TOML

  run_setup "$config" "$worktree" feature >/dev/null
  [[ ! -e "$worktree/setup-ran" ]] || fail 'unconfigured repository does not run setup steps'
  [[ ! -e "$worktree/.env" ]] || fail 'unconfigured repository does not copy policy files'
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

test_configured_setup
test_unconfigured_repository
test_fresh_base
