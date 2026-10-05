#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/herdr-worktree-release-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

bash "$ROOT/tools/package-plugin.sh" "$WORK/plugin.tar.gz"
mkdir "$WORK/extracted"
tar -xzf "$WORK/plugin.tar.gz" -C "$WORK/extracted"
PLUGIN_UNDER_TEST="$WORK/extracted/setup.ts" bash "$ROOT/tests/setup_test.sh"
printf 'ok - extracted release runs without node_modules or package installation\n'
