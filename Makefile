.PHONY: test lint

test:
	tests/setup_test.sh

lint:
	rm -rf "$${TMPDIR:-/tmp}/herdr-worktree-setup-build"
	bun build --no-bundle --target bun setup.ts --outdir "$${TMPDIR:-/tmp}/herdr-worktree-setup-build"
	bash -n tests/setup_test.sh
