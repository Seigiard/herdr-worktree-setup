#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tar -czf "$1" -C "$ROOT" README.md LICENSE herdr-plugin.toml setup.ts \
  vendor/valibot/index.js vendor/valibot/LICENSE vendor/valibot/UPSTREAM.md
