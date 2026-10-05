# Source provenance

- Source: https://github.com/dmmulroy/anti-slop
- Commit: `c44ef22ca116d0ba62a3ff663a0bd13a3f3fa40b`
- Copied directory: `skills/install-anti-slop/assets/anti-slop/`
- Installed directory: `tools/oxlint/anti-slop/`
- Plugin implementation: unchanged upstream assets.
- Local packaging: a private `package.json` declares the plugin ESM without changing the host package module mode.
- Oxlint and `@oxlint/plugins`: `1.87.0`, exact matching versions.
- Coverage: all 18 generic rules plus `oxc/no-accumulating-spread`, at error severity.
- Effect rules: not enabled; no direct Effect dependency.

The upstream MIT license is included as `LICENSE`. Nested Stylistic license and provenance are preserved under `vendor/`.
