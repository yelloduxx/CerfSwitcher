# Build 166: native interaction checks

## Scope

These checks target two failures: typing while a layout switch is pending, and
repeated manual conversion without deleting neighboring text. They use separate
application, editor, and timestamp-driven CGEvent producer processes. The editors
are an NSTextView and a WKWebView. No Computer Use is involved.

The signed test application compiles the same runtime sources as production.
Its isolated preferences prevent changes to the user's learned rules. This is
native editor evidence, not proof of compatibility with every third-party editor.

## Scenarios and independent expectations

Each editor runs seven short cases:

| Case | Input purpose and expected result |
| --- | --- |
| Russian continuation | Start in EN; physical RU phrase becomes `вечером мы проверим доклад, а утром обсудим результат! ` |
| English continuation | Start in RU; physical EN phrase becomes `please send report Q, then attach appendix D! ` |
| Auto-off control | Repeat the first physical sequence with conversion disabled; it stays `dtxthjv vs ghjdthbv ljrkfl? f enhjv j,celbv htpekmnfn! ` |
| Empty caret, immediate typing | Double Shift, then physical EN `draft notes, and check item R! `; accept either complete EN or complete RU serialization, never a mixed first letter |
| Caret toggle | Preload `anchor: nfrnbxyj`; double Shift produces `anchor: тактично`, then switches back |
| Selection toggle | Select that last word; toggle twice without selecting it again |
| Buffered toggle | Type `the final note: nfrnbxyj`; toggle the buffered word twice and preserve the prefix |

Letters are scheduled 35 ms apart, with no per-word wait for conversion. The
first continuation begins 2 ms after the conversion boundary. The empty-caret
case starts typing 2 ms after the second Shift down. Manual checkpoints observe
completion separately; they are not continuous-input latency measurements.

The assessor checks exact text, UTF-16 caret position, active layout, transaction
count, unchanged clipboard count, callback identity and delivery observations.
WebKit also provides a DOM read-back. Expected strings do not come from the
decoder under test. Independent golden key checks cover the stimulus encoder.

## Confirmed failures and corrections

1. A delayed empty-caret result could clear newer input and switch its layout.
   Focus, revision, and sequence now guard every caret-preparation outcome, not
   only a successful word lookup. The old behavior fails the new regression test.
2. A key already translated before a manual switch could retain its old Unicode
   payload even when the callback observed the new layout. Native output contained
   `dкфае` instead of `вкфае`. Manual switches now use the existing queued-key
   repair already used for automatic switches. No extra deletion or repost occurs.
3. Selected-text fallback always waited 150 ms before checking completion. WebKit
   missed the first confirmation checkpoint. It now reads immediately and retries
   only an unchanged or unavailable result. All retries share the remaining
   150 ms budget, including time spent queued for AX. A match returned after that
   deadline is not promoted to verified learning.

## Results

- All seven cases passed in both editors: 14 native cases, including two auto-off
  controls. Exact text, caret, layout, neighbor preservation, and clipboard checks
  passed. Evidence is in `.audit/native-interaction-final-{appkit,webkit}.log`
  and `.audit/native-interaction-buffered-{appkit,webkit}.log`.
- After the final deadline correction, selected-word toggles passed again in both
  editors. See `.audit/native-interaction-readback-{appkit,webkit}.log`.
- Reassessing each actual auto-off capture against the enabled-conversion oracle
  fails on text, layout, runtime configuration, and transaction count. Results are
  in `.audit/native-interaction-negative-challenge.json`.
- The prepared-binary path now rejects changed sources or changed binary hashes,
  both before input and before accepting the run. A regression test exercises
  both refusals.
- Swift warnings-as-errors suite: 474 tests, one existing own-settings-window
  check skipped, zero failures. Python harness suite: 43 tests, four optional
  preflight checks skipped, zero failures. These counts include skipped tests.
- Universal production packaging passes the no-test-code binary guard. Signing
  uses `RuSwitcher Local Code Signing`; the model and decoder are unchanged.
- Build 166 was atomically installed with a build-165 backup. The installed and
  built executable SHA-256 is
  `99091bf9ba8563e3abdeb4e76235b083d67b1a57a785ef695437be4c3f0f057d`.
  Launch read-back reported PID 70787 and one enabled event tap. All seven
  personal-data sections are unchanged. Installation evidence is in
  `.audit/install-166-result.json`. This launch check is distinct from the native
  test-host input checks above.

## Invalid runs and limits

A development encoder swapped the physical T and Y keys. That run was discarded
and independent golden keys were added. Native reruns also rejected producer
lateness and lost focus; neither is counted as a product pass. In the last rerun,
the first event was 10.053 ms late against an unchanged 10 ms limit. Another run
lost editor focus before typing. Its first completed Russian case passed, but the
whole run remains invalid. The affected selected-word path then passed alone in
both editors. These interruptions were not hidden by widening a timing limit.

Observed callback-segment maxima reached 6.193 ms in AppKit and 8.055 ms in
WebKit. This small sample, instrumented after marker guards and before observer
completion, does not establish a p99 or satisfy a universal 5 ms target.
Codex, Ghostty, and arbitrary editors are not certified by these results.

## Reproduction

With permission to temporarily use desktop focus:

```bash
RUSWITCH_ALLOW_FOCUS_STEALING=1 python3 scripts/run_native_interaction_tests.py --editor nstextview
RUSWITCH_ALLOW_FOCUS_STEALING=1 python3 scripts/run_native_interaction_tests.py --editor webkit
```

Run the editors serially. Each invocation restores the previously running
installed application and verifies its executable hash. A preparation can be
reused with `--prepared .build/external-native-last.json` only while the recorded
sources and all signed executables still match.
