# Build 167: manual-only word pairs

## Behavior

The existing never-convert list is now named **Manual conversion only** in
English and **Только ручное переключение** in Russian. It remains under
**Settings > Exceptions**, with the same `com.ruswitcher.deniedWords` key.
No new archive format or second list is introduced.

Adding either layout spelling excludes the pair from automatic conversion and
manual correction learning. The configured manual gesture still converts it.
Case, surrounding punctuation, and trailing spaces do not bypass the exclusion.
The decoder checks the whole candidate set before ranking, so another
punctuation interpretation cannot escape a blocked spelling.

Existing confirmed pairs remain stored, but the exclusion wins over them and
always-convert rules. Manual switches do not reverse or reinforce those pairs,
create application exceptions, or remove them. Removing the list entry restores
normal behavior. Full personal backup already includes this list.

Learning checks the current list at persistence time, not just when staging the
manual correction. The optional Input Method preference path uses the same
policy; its launch compatibility is not established by these tests.

## Failing-before evidence

Two new persistence tests failed before the change. For an excluded `here` pair,
the store returned `confirmation(...)` instead of `ignore`, wrote rule bytes,
and could mutate an existing rule after the exclusion was added. The original
run is recorded in `.audit/manual-only-before.log`.

The decoder regression also caught a punctuation alternative bypassing an
excluded target spelling. Exclusions now apply before candidate selection.

## Checks

- Swift warnings-as-errors suite: 479 tests, one existing own-settings-window
  check skipped, zero failures. It covers both directions, case, punctuation,
  confirmed and always-convert precedence, current-list changes, store reload,
  and full backup restore. See `.audit/build167-all-tests.log`.
- Python harness checks: 43 tests, four optional preflight checks skipped, zero
  failures. The assessor rejects a learned rule in an excluded-pair trace and
  missing learning read-back.
- Two native cases passed in each separate AppKit and WebKit editor. Each types
  `please wait here `, toggles the last word twice with double Shift, and then
  continues with `and keep this note. `. The first read-back is exactly
  `please wait руку ` in RU. The final text is exactly
  `please wait here and keep this note. ` in EN, with collapsed caret `[37, 0]`.
- With `here` excluded, both native checkpoints report zero learned entries and
  no learning Undo. Without the exclusion, the first checkpoint reports one
  confirmed rule and an available learning Undo. This positive control proves
  that zero learned entries is not merely a broken learning path.
- Both native hosts report unchanged clipboard count, complete input delivery,
  and exact intermediate and final text. Native evidence is in
  `.audit/build167-native-webkit.log` and
  `.audit/build167-native-appkit-retry.log`. The initial AppKit run lost focus
  before sending any key; it remains invalid, not a product pass.

The native cases exercise the actual shared runtime in a signed test bundle
with isolated preferences. They do not certify every third-party editor or
replace the separate installed-binary identity check.

Universal production warnings-as-errors and packaging passed. Build 167 was
installed with the prior signing identity and a build-166 backup. The installed
and built executable SHA-256 is
`dd7e64d364643fc0469bf06c35cfe0a49dbd10d7824df6741680e0ecaac04d2c`.
Launch read-back reported PID 78136 with one enabled event tap. All seven
personal-data sections are unchanged. No example words were added to the user's
list. Installation evidence is in `.audit/install-167-result.json`.

## Reproduction

```bash
RUSWITCH_ALLOW_FOCUS_STEALING=1 python3 scripts/run_native_interaction_tests.py --editor nstextview --case manual-only-pair --case manual-only-learning-control
RUSWITCH_ALLOW_FOCUS_STEALING=1 python3 scripts/run_native_interaction_tests.py --editor webkit --case manual-only-pair --case manual-only-learning-control
```

Run the editors serially with permission to use desktop focus. The wrapper
restores the installed application and checks its executable hash after each run.
