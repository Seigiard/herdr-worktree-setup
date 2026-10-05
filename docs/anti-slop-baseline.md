# Anti-slop baseline

Run `npm ci` and `npm run lint:anti-slop` with Node 24 or newer. `make lint` also runs the new check before the existing Bun build and shell syntax check.

The unchanged `setup.ts` at `70048c616979719aa592df36f37ec076227b2ac8` produces 60 errors:

- 48 `require-readable-spacing` findings.
- Five `no-runtime-typeof` findings at lines 87, 92, 126, 193, and 216.
- Four `require-safety-comment-for-type-assertion` findings at lines 85, 124, 196, and 225.
- Two `no-unknown-parameters` findings at lines 191 and 214.
- One `no-known-value-widening` finding at line 90.

The existing Bun build and shell syntax check pass when run separately. There is no configured TypeScript typecheck. All 18 generic rules and native `oxc/no-accumulating-spread` stay enabled as errors. No Effect dependency is declared.

This draft needs a separate spacing cleanup and review of the event/configuration parsing boundaries and assertion invariants. No runtime code is changed by the settings rollout.
