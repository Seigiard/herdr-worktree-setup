# Anti-slop baseline

Run `npm ci` and `npm run lint:anti-slop` with Node 24 or newer. `make lint` also runs the new check before the existing Bun build and shell syntax check.

The unchanged `setup.ts` at `70048c616979719aa592df36f37ec076227b2ac8` produces 60 errors:

- 48 `require-readable-spacing` findings.
- Five `no-runtime-typeof` findings at lines 87, 92, 126, 193, and 216.
- Four `require-safety-comment-for-type-assertion` findings at lines 85, 124, 196, and 225.
- Two `no-unknown-parameters` findings at lines 191 and 214.
- One `no-known-value-widening` finding at line 90.

The existing Bun build and shell syntax check pass when run separately. There is no configured TypeScript typecheck. All 18 generic rules and native `oxc/no-accumulating-spread` stay enabled as errors. No Effect dependency is declared.

The cleanup resolves all 60 findings. Spacing fixes are separate from semantic changes. JSON events and the selected TOML project policy are decoded with a vendored Valibot 1.5.0 ESM bundle. Unselected projects are not validated. Copy and step helpers receive decoded string arrays without assertions. Missing or non-string branches still become detached events; only the boolean `true` enables fresh-base.

Invalid copy/step lists now fail before fresh-base, copy, or step actions run. The lifecycle marker is still written before policy is loaded. This avoids partial setup when a policy contains a valid copy list but invalid steps.

`make lint` and `make test` pass. Tests use real Git and Bun, including valid setup, unconfigured repositories, fresh-base, invalid inputs, detached branches, and execution from an extracted release without node_modules. Release packaging includes the decoder, license, and provenance. No rules were weakened or suppressed.

Review also found a pre-existing destination-symlink defect in copying. Copy now rejects symbolic links in the destination path, including dangling links and parent directories. Real filesystem tests verify that secrets are not written outside the worktree. Detached-event tests require a newly created step output for each case.
