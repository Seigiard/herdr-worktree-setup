# Herdr Worktree Setup

`seigi.worktree-setup` prepares a worktree after Herdr creates it. It is a
standalone Herdr plugin: the package owns the event handler and its behavior
tests, while the user's dotfiles own repository-specific policy.

## Requirements

- Herdr 0.8.0 or newer
- Bun 1.x or newer
- Git
- macOS or Linux

## Install

```bash
herdr plugin install Seigiard/herdr-worktree-setup --ref v0.1.1 -y
herdr plugin enable seigi.worktree-setup
```

Use an immutable release tag or commit in managed environments. To update,
review a newer release, change the ref, and run the same install command. To
remove the plugin:

```bash
herdr plugin uninstall seigi.worktree-setup
```

The plugin has no package-owned configuration. Its configuration directory is
selected by Herdr through `HERDR_PLUGIN_CONFIG_DIR`, and the handler reads
`config.toml` there.

## Configuration

Configuration is keyed by the canonical `origin` remote. A repository without
a matching table receives no setup or fresh-base mutation.

```toml
[projects."github.com/membranehq/platform"]
fresh-base = true
copy = ["CLAUDE.local.md", ".env"]
steps = ["mise exec -- make setup"]
```

`fresh-base` resets an untouched new branch to fetched `origin/HEAD` only when
the branch is eligible. `copy` contains relative regular files copied from the
primary checkout when they exist and are not already present. `steps` contains
shell commands run from the new worktree with `HERDR_MAIN_REPO`,
`HERDR_WORKTREE`, and `HERDR_BRANCH` set.

The handler writes the generated-worktree marker before loading project policy:

```text
git rev-parse --path-format=absolute --git-path herdr-generated-worktree
```

The first line is the generated branch name. `herdr-worktree-identity` treats
that file and matching first line as the authorization boundary for renaming a
generated `worktree/*` branch. Later lines may carry attribution for mutations
already made. The marker is written atomically and Git removes it with the
linked worktree metadata.

## Provenance Boundary

The plugin observes Herdr's `worktree.created` event after native worktree
creation. It does not create tabs, panes, workspaces, or worktrees itself, and
it does not register creator relationships. The managed `herdr` PATH wrapper
continues to own provenance for the creation commands it intercepts.

Native creation paths that do not cross that wrapper, and creation surfaces not
covered by the event, remain unknown-provenance paths. This plugin does not
claim them and does not maintain a second registry.

## Development

```bash
make lint
make test
herdr plugin link "$PWD" --enabled
```

The tests use real Git repositories and exercise the plugin through its event
environment, including configured setup, fresh-base behavior, and the
unconfigured-repository control.
