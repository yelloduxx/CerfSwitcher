# RuSwitcher Pro Engineering Notes

This file is the repository-level operating context for future agents. Keep it
updated when architecture, behavior, model artifacts, tests, signing, or the
installed build changes.

## Product

- RuSwitcher Pro is a local macOS menu-bar application for EN<->RU keyboard-layout
  conversion. The quality target is Caramba/Punto-like behavior without cloud
  inference or telemetry containing user text.
- Supported platform: macOS 13+; the release bundle is universal (`arm64` and
  `x86_64`).
- Automatic conversion is off by default until the user enables it.
- Primary repository: `yelloduxx/RuSwitcher`; the production branch is `main`.
  `rashn/RuSwitcher` is the author's upstream repository, not a release source
  for this fork.
- Production product on `main` is **RuSwitcher Pro** `4.0.0` build **130**:
  - Bundle: `RuSwitcherPro.app` → `/Applications/RuSwitcherPro.app`
  - Bundle ID: `com.ruswitcher.pro` · Executable: `RuSwitcherPro` · Dev tag: `pro`
  - Logs: `~/Library/Logs/RuSwitcherPro/ruswitcher-pro.log` via
    `ProductIdentity.logFilePath` (Settings and rslog must match)
  - Lineage: Lab 105 conversion core + AX 106–108 safety + runtime
    `ManualHostPolicy` capability detection + keyboard-deletion manual path for
    external hosts (build 118+) + non-destructive physical selection and
    deferred manual learning for AX-blind hosts (builds 125–126) + V3.1 ranked
    SCOWL evidence for general RU-to-EN dictionary recovery (build 128) + exact
    native-test identity gates and wake/session event-tap recovery (build 129) +
    explicit learning and confirmed-rule recovery for plain ALL-CAPS acronyms
    while structured identifiers remain protected (build 130).
  - Signed with the reusable `RuSwitcher Local Code Signing` identity (or
    Developer ID when available).
  - Installed executable SHA-256:
    `2b59f4bc61eaad8754a75442d75d7798af37a576a9139dacc85f2b2c984044aa`.
- Verify the installed binary hash and PID after every local replacement; do
  not infer the running build from `version.json` alone.
- Changing `ProductIdentity.bundleIdentifier` requires re-granting Accessibility
  and Input Monitoring; defaults live in the app's standard domain for that ID.

## User Requirements

- Prefer reliable conversion over aggressive destructive edits. In ambiguous
  editor state, keep the text unchanged.
- Do not add word-specific hardcode for reported examples. Fix candidate,
  language-model, context, or transaction rules generically.
- The user prefers short progress/final messages in Russian.
- Do not use Computer Use for testing this app. Use unit tests, the simulator,
  and CGEvent/HID probes from the terminal.
- Do not replace the reusable signing identity with ad-hoc signing.
- Work with the existing worktree and never discard unrelated user changes.

## Package Layout

- `Sources/RuSwitcherCore`: pure/testable V3 decoder, language model, state and
  transaction data.
- `Sources/RuSwitcherAppSupport`: testable native replacement, event,
  pasteboard, logging and release-version contracts.
- `Experimental/V4`: separate Swift package for the Core ML research project;
  it is absent from the root package graph and production bundle.
- `Sources/RuSwitcher`: AppKit application, event tap, layout switching, AX
  context, manual conversion, transaction execution and settings.
- `Sources/RuSwitcherInputMethod`: optional InputMethodKit companion with EN/RU
  marked-text composition over the same production V3 decoder.
- `InputMethod/Info.plist`, `build_input_method.sh` and
  `scripts/install_input_method.sh`: companion metadata, universal build/signing
  and atomic per-user registration.
- `Sources/RuSwitcherSimulator`: parallel V3 corpus/phrase simulator.
- `Sources/RuSwitcherTypingSimulator`: legacy literal-text/ideal-delivery checks
  and an explicit `--physical-input` scheduled key-event mode. The physical mode
  shares local classification and replacement lifecycle with production, but
  uses virtual editor/AX transport, not native AppDelegate/AX/CGEvent delivery.
  Legacy independent phrase JSONL batches support `--jobs`.
- `Tests/NativeEditorHost` and `Tests/NativeDriver`: separate executable targets
  for an external NSTextView receiver and timestamp-driven CGEvent producer.
  They are not dependencies or resources of the production `.app`.
- `Tests/Support` (`RuSwitcherTestSupport`) and `Tests/RuSwitcherTypingTests`:
  read-only system-layout loading, physical fixtures, interpreter and independent
  assessor. These are dependencies of the simulator/tests, never the app.
- `Tests/RuSwitcherCoreTests`: unit, corpus, state-machine and transaction tests.
- `Tests/RuSwitcherAppSupportTests`: native-contract tests with controlled fakes.
- `Experimental/V4/Tests`: isolated V4 research tests.
- `Tests/Fixtures/Simulator`: deterministic word and phrase fixtures.
- `Tests/Fixtures/HID/mixed-layout-corpus-batch.json`: continuous one-window
  CGEvent fixture selected from the user's 5,000-phrase corpus.
- `scripts`: model generation/training, corpus import, randomized simulation,
  isolated CGEvent tests and continuous batch tests.

SwiftPM targets:

- `RuSwitcherCore` library (production V3)
- `RuSwitcherAppSupport` library
- `RuSwitcher` executable
- `RuSwitcherInputMethod` executable
- `RuSwitcherSimulator` executable
- `RuSwitcherTypingSimulator` executable
- `RuSwitcherCoreTests`
- `RuSwitcherAppSupportTests`

V4 has its own package and is built only with
`swift test --package-path Experimental/V4`.

## Decoder Architecture

The production decoder is a local noisy-channel decoder over physical keys. It
compares the literal-layout and opposite-layout hypotheses using:

- physical-key/lattice cost;
- frequent word probabilities;
- ranked EN SCOWL 35/50/60 and RU Hunspell spelling membership;
- character 2-5-gram plausibility;
- recent language belief and phrase context;
- compound analysis for unknown Russian forms;
- confirmed/manual pairs and adaptive counters;
- hard safety blockers.

Important types:

- `AutoConvertCandidate` and `AutoConvertCandidateGenerator`
- `LayoutDecoder` (the sole production decision engine)
- `LanguageBelief`, `CompoundWordAnalyzer`
- `InputSession`, `TokenSnapshot`, `ConversionTransaction`
- `ReplacementCoordinator`, `InputEventClassifier` and
  `KeyboardLayoutTranslationState`

V4 is not part of the application runtime, settings, root simulator or app
resources. Its Core ML model, lattice, adapter and decoder live only in the
separate `Experimental/V4` package. For EN/RU, a missing V3 model causes a safe
keep; it never activates another automatic decoder.

## Candidate and Punctuation Rules

- Candidate generation preserves leading/trailing wrappers and explores the
  physical-key interpretation of punctuation keys.
- A single punctuation key that produces punctuation in both layouts follows
  the target physical-key interpretation when the word converts. This fixes an
  English-layout `?` intended as a Russian comma and `&` intended as a Russian
  question mark. Multi-mark suffixes such as `?!` and `...` remain literal.
- Typed punctuation remains literal when the opposite layout would turn it into
  a letter and the punctuation candidate is the valid word, as in `ghbdtn,`.
- Examples covered by tests:
  - `b` -> `и` in Russian context, but `plan B` stays unchanged.
  - `ghbdtncnde.` -> `приветствую` when the final physical period is Russian `ю`.
  - `ghbdtn, ` -> `привет, `.
  - `ghbitk? ` -> `пришел, `.
  - `ghbitk& ` -> `пришел? `.
  - `гыуб ` -> `use, `.
  - `афиду ` -> `fable `.
  - `дщщыут ` -> `loosen `.
  - `cegthcgbyf ` -> `суперспина `.
  - `htdjk.wbz ` -> `революция `.
- Automatic conversion now commits only on Space, Enter, or Tab. Punctuation is
  retained inside the token until that boundary. Do not restore conversion on
  the first punctuation key: it caused `...` to become `.//` after the layout
  switched mid-sequence and caused races with the following boundary.
- A word ending in punctuation with no following Space/Enter/Tab remains pending.
- Physical key code alone is not a boundary. `KeyboardLayoutTranslationState`
  keeps the Carbon dead-key state for the active input source. On US
  International-PC, quote followed by physical Space produces a quote and must
  remain inside the token; only a translated literal space is a word boundary.
- AX suffix validation retries one mismatch after 0.75 ms within the existing
  4 ms deadline. This handles short-token races in WebKit/Electron while still
  blocking a persistent focus/caret mismatch.
- Posted replacement events are verified asynchronously for up to 120 ms. This
  does not block the event callback; it prevents a temporarily stale AX value
  from clearing valid phrase context after the editor has accepted a conversion.

Hard blockers remain authoritative:

- secure input and password fields;
- denied applications (terminals, IDEs, password managers, etc.);
- URL, email and code/identifier shapes;
- mixed-script identifiers and camelCase;
- unconfirmed ALL-CAPS acronyms; a plain multi-letter acronym may convert only
  through an explicitly confirmed global physical-layout pair, while URL/email,
  structured identifiers and code-like shapes remain hard blockers;
- single uppercase Latin letters, except a non-word capital that is a Russian
  word, at phrase start or after Russian (`D` -> `В`, but `plan B` stays);
- single uppercase Cyrillic letters that are words;
- `neverConvert` rules;
- stale focus/revision/editor integrity.

Unknown valid Russian words must not convert to English from script score alone.
Both-known pairs such as `here`/`руку` follow the language of the last two
context tokens (build 138): after two English words `руку` becomes `here`, after
two Russian words `here` becomes `руку`; otherwise they stay unchanged unless
explicitly confirmed by the user. One previous target-language word suffices
when Tatoeba shows it leads to the target reading at least 1% of the time
(`come руку` -> `come here`). Build 140: an attested letter reading of a
trailing `.`/`,` key competes with a frequent punctuation reading
(`вероятностью`, not `вероятность.`), and a conversion with no dictionary evidence
needs target char-LM >= -13.0 or Tatoeba attestation (`Konami` stays, not
`Лщтфьш`; `Джеймса` still converts). Build 141: shape blockers yield to
dictionary evidence when a hyphenated reading is a word in every part and the
typed one is not (`премьер-министра`, but codes with an all-caps part such as
`ru-RU` stay), and when an all-caps token reads as an attested target word while
its own letters spell no word (`CIF/` -> `США.`; `NASA`, `HTTP` stay). Build 142
targets proper names: on the English layout a lone final `/` is the Russian
period key, not a path (`Fdcnhfkbb/` -> `Австралии.`); a capital right after a
hyphen is a name part, not camelCase (`Сан-Франциско`); a Tatoeba-attested
target reading over typed letters that spell no word gets the dictionary bonus
and passes the unknown-English gate (`Дщы` -> `Los`, `ВТФ` -> `DNA`), unless it
keeps a leading layout-letter key as punctuation; and a word keeping such a key
faces the attested letter reading (`<fdfhbb` -> `Баварии`). Unattested acronyms
such as `KPI` still need explicit confirmation. FLORES dev: 1,406 safe misses
(was 1,842), 45 wrong, 13 false positives. Build 145: in Russian prose (two
Russian words, or a Tatoeba follower) a SCOWL-only English spelling yields to a
frequent Russian reading (`я помыл herb` -> `руки`; `herb` alone or after English
stays). A Tatoeba-attested reading over a non-word now counts as lexical
evidence (`Ыфт` -> `San`, `y/` -> `н.`), except for two plain letters, which
are too ambiguous (`tv`/`ем`, `cm`/`сь` stay), and except where a key no prose
uses there is absent (`кв.` stays). Readings are ranked frequent > attested or
dictionary > none: a frequent wrapped core keeps its quote (`"lj` -> `"до`, not
`Эдо`), an equal or weaker one yields to the letter reading (`'njv` -> `этом`,
`<fdfhbb` -> `Баварии`), and an unknown core never keeps a trailing `.`/`,`
letter key as punctuation (`utjabkmnhfwb.` -> `геофильтрацию`, `Gtyl;f,` ->
`Пенджаб`). FLORES dev: 1,161 safe misses, 20 wrong, 13 false positives;
legacy gate unchanged at 45. Build 146 (model 3.4): one previous Russian word
that Tatoeba shows leading to the reading is enough (`большие herb` -> `руки`);
contractions are attested (`шеэы` -> `it's`) and an English possessive is
attested through its base (`Тфвфдэы` -> `Nadal's`). FLORES dev: 1,099 safe
misses, 20 wrong, 13 false positives; legacy 44 safe misses. Since build 135 a source
known only to a spelling dictionary (Hunspell, or SCOWL rare tier) is not "known"
against a frequent target: when the target's unigram log-probability exceeds the
rarest listed source-language word by 2.5 (natural log), frequency decides
(`тучею` -> `next.`, `ult` -> `где`). Common/standard SCOWL words stay protected
outside Russian prose.
Trailing `.`/`,` keys read as `ю`/`б` when that forms a word (build 134), and an
opening bracket never ends a word (build 132). The legacy 5,000-phrase gate is
now 45 safe misses (builds 136-137: every wrapper prefix length is a reading, so `[,eath_` -> `[буфер_`; a lone Cyrillic capital that is no word converts to a frequent English word, `Ш` -> `I`, also wrapped `(Ш)` but never the initial `Ш.`); `scripts/make_flores_mixed_tsv.py` builds the independent
FLORES development phrases used to find new errors.

## Event and Editing State

`KeyboardMonitor` and `InputSession` classify printable keys, Space/Enter/Tab,
Backspace, modified deletion, navigation, clipboard commands, Undo, focus changes
and synthetic events before mutating the token state.

- Plain Backspace removes one physical key.
- Option/Command+Backspace, forward Delete, Cut/Paste/Undo, arrows, mouse focus
  changes and tap recovery invalidate the token/revision as appropriate.
- Synthetic RuSwitcher Pro events carry `kRuSwitcherEventMarker` and must never feed
  back into the state machine.
- macOS wake and session-active notifications debounce into one recovery: clear
  stale input/learning state, invalidate AX focus and recreate the event tap.
  Reconfiguration retries after 1, 3 and 10 seconds, then stops rather than
  spinning indefinitely.
- Active taps use `.headInsertEventTap`; listen-only taps may use tail placement.
- Automatic replacement validates PID, bundle, focus identity, revision and the
  expected suffix before editing. An unavailable AX preflight blocks the post;
  a timed-out field is retried after a one-second cooldown rather than being
  ignored for 30 seconds.
- Opt-in setting `axlessConversion` (default off) lets the automatic path post
  its keystroke transaction when the AX preflight is `.unavailable` — hosts that
  expose no AX text (Ghostty, Chromium/Electron). It is wired as
  `ReplacementRequest.allowUnavailablePost`; the coordinator then relies on the
  focus + revision freshness match as the only gate. A `.mismatch` (AX read and
  disagreed) still blocks unconditionally, opt-in or not. The manual double-Shift
  fallback already posts by keyboard in AX-unavailable hosts regardless of this
  setting, because it is explicit user intent.
- A posted conversion immediately publishes provisional phrase context for the
  next token. AX read-back confirms learning and Undo state without duplicating
  that context. In build 130, layout switches immediately after a successful
  post, before the event callback returns. An unavailable read-back keeps the
  posted reconversion state but does not create verified automatic learning;
  mismatch invalidates the current staged state without a destructive retry.
  Stale confirmation is rejected by the staged sequence/current-token checks.

The reliable build-68 transaction path is intentional:

1. Consume the original Space only after the conversion decision succeeds.
2. Build ordered Backspace keyDown/keyUp events and one Unicode replacement.
3. For AX-readable fields, post directly to the validated target PID with
   `CGEvent.postToPid`. The explicit AX-less opt-in chooses the global event
   stream when preflight is unavailable; mismatch still blocks.
4. Replay Space as one marked targeted key event.
5. Switch layout and remember the manual-reconversion transaction on post.
   Verified read-back confirms staged completion and automatic learning state;
   it is not the first layout switch. Do not change this timing from older docs
   without continuous-input characterization tests.

Do not revert this to a burst through `tapPostEvent` or a Unicode payload ending
in a space. Continuous CGEvent tests demonstrated lost Backspaces, missing spaces,
duplicate spaces and duplicated first characters with those approaches.

## Manual Trigger and Learning

The configured trigger is currently used as double Shift by the user. Priority:

1. Convert a real non-empty selection.
2. Convert the current buffered token.
3. Convert the last completed buffered token after a boundary.
4. Recover and convert the exact token before the caret through verified AX when
   navigation or focus changes have invalidated the physical-key buffer.
5. Undo/reconvert the immediately preceding automatic correction.
6. Switch layout only.

Selection direction is based on dominant script, not the active layout. AX
selected-text replacement is preferred. Clipboard fallback is retained only
when the selected text itself cannot be read; it preserves pasteboard types.
Failure must leave selection and layout unchanged.

A real, user-made **selection** is converted through Accessibility
(`readSelection` → `kAXSelectedText`), because that write replaces a genuine
selection reliably. **Current-/previous-word** conversion (no selection) is
different: in an **external** host it goes straight to a keyboard path.
Programmatically selecting the suffix via `kAXSelectedTextRange` and then
writing `kAXSelectedText` inserts instead of replacing in
Chromium/Electron (Claude desktop, VS Code) and terminals — it leaves the
original word and duplicates text, and `recoverInsertedReplacement` cannot heal
it because the collapse write uses the same broken AX primitive. AX-readable
external hosts use the established targeted replacement. AX-blind hosts select
the exact suffix with marked Shift+Left and type physical target-layout keys
over that selection, so a dropped insertion cannot first erase the word. Only
the in-process `NSTextView` host uses the AX suffix write (tested,
AppKit-main-thread-sensitive, and known-good there).

Manual current/previous-word conversion is a forced physical-layout toggle; it
does not ask the decoder whether either spelling is correct. It replaces the
exact suffix before the caret atomically through Accessibility when available.
The non-AX fallback never posts Backspace. A read-back verified edit learns
immediately. A `postedUnverified` explicit manual edit stages a provisional
learning pair: the next ordinary input or a 1.2-second grace period confirms it,
while Backspace/Delete, Undo, Cut/Paste, or another double Shift cancels it.
Repeated double Shift toggles the remembered pair, also immediately after an
automatic conversion.

For an in-process `NSTextView` host, selected-text AX mutation must run on the
main thread. Calling `AXUIElementSetAttributeValue` for a local AppKit element
from the manual AX queue triggers AppKit's queue assertion and crashes. External
AX mutation remains asynchronous and polls bounded read-back before fallback.

Adaptive learning behavior:

- A successful manual word conversion records a normalized, globally confirmed
  source/target pair. The next occurrence can auto-convert without dictionary
  evidence.
- A completed following token is a weak positive signal.
- Explicit Undo or double-Shift reversal is a negative signal. A plain first
  Backspace after auto-conversion usually deletes the replayed space and must not
  train or create an application exception.
- A permanent application exception is created only when explicitly reversing a
  globally confirmed manual pair. Weak automatic positives are not sufficient.
- Rule-book model 8 removes legacy app-local negative rules and unsafe learned
  pairs. Persistent manual pairs require at least two letters on both sides, so
  accidental `а`/`f` or `b`/`и` confirmations cannot become global overrides.
- Simple switch-only actions do not train.
- Adaptive rules persist in `UserDefaults`.
- Advanced settings can reset learned corrections.
- Advanced settings can export and import learned word rules as a versioned,
  human-readable JSON archive. Import merges by normalized source, target and
  app scope; it is idempotent, preserves confirmations and keeps the larger
  counters/newer timestamp. The archive contains adaptive pairs/counters only,
  never typed context, general settings, always/never lists or adapter weights.
- Archive validation is atomic: reject foreign/unsupported formats, files over
  5 MB, more than 2,000 rules and invalid fields without changing current rules.

## Input Method Companion

`RuSwitcherInputMethod` is an optional native input source, not another decoder.
It exposes `com.ruswitcher.inputmethod.RuSwitcherPro.en` and `.ru`, keeps the
unfinished token as marked text and calls `InputMethodCompositionSession` at
Space, Enter or Tab. The session uses the bundled V3 model, phrase belief,
always/never policy and the existing adaptive rules from the `com.ruswitcher.pro`
defaults suite. It commits one final string through `IMKTextInput`; automatic
conversion never posts deletion events, reads AX or touches the pasteboard.

Double Shift first toggles marked text, then a real selection or the exact token
before the caret exposed by `IMKTextInput`. Manual learning is deferred until the
next ordinary input and is cancelled by destructive editing or another double
Shift. The main application's event tap detects either companion source and stays
transparent while it is active, preventing duplicate conversion.

This path applies only to clients that implement the macOS text-input contract.
Do not claim support for raw terminal surfaces, games, remote sessions, secure
fields or fully custom editors without a native host result. If the V3 model or
IMK client is unavailable, the controller passes the event through instead of
claiming it. On macOS 26, AMFI rejects the reusable self-signed identity even
when it is trusted for `codeSign` in the user or System domain. Activation needs
an Apple-issued Apple Development or Developer ID identity with an eligible
provisioning chain. `codesign` and Gatekeeper success alone do not prove that
AMFI will launch the input-source process.

Current build-130 candidate status: the universal companion builds, passes its
self-check and registers two selectable modes, but macOS 26 rejects launch with
AMFI error `-423` and reports no eligible provisioning profile. User- and
System-domain trust tests for `RuSwitcher Local Code Signing` were both reverted;
both trust domains are clean. No companion bundle remains in
`~/Library/Input Methods`; rejected local test bundles were moved to
`/private/tmp/ruswitcher-input-method-rejected-20260802`. Installed production
RuSwitcher Pro remains running as build 130.

## Models and Provenance

Bundled resources:

- `language-model-v1.bin`: versioned V3 model `2026.10-v3.4-mapped` (format 3),
  current SHA-256
  `81b443e8c8adda4c3ba7a764a0131187da6554f0901920cbfbb2e7593f4021fa` (15.6 MB).
  Model 3.4 (build 146) widens the Tatoeba statistics: followers cover every
  word whose keys spell a frequent or attested word in the other layout
  (17,831 EN and 4,220 RU pairs, was 7,862 and 134), and attested English words
  include contractions (`it's`, `didn't`).
  Format 3 (build 143) stores every score table as an `RSHT` open-addressing
  hash table that `ModelScoreTable` reads in place from the memory-mapped file;
  the Russian Bloom filter is read in place too. Only metadata, thresholds and
  the productive list are JSON. Values stay float64, so decisions are
  bit-identical to format 2 (identical FLORES and 5,000-phrase results). Load
  fell from ~200 ms to ~19 ms and the model's dirty footprint from ~55 MB to
  ~0.3 MB (its ~15 MB of pages are clean, file-backed and reclaimable).
  `build_language_model.py --reencode OLD.bin` converts a format-2 model without
  re-downloading sources; only format 3 loads.
  Sections 14/15 hold Tatoeba-derived ln P(word | previous) for words whose keys
  spell a frequent word in the other layout (build 139). Sections 16/17 hold
  Tatoeba-attested words outside the frequency list (count >= 2), placed below
  every listed word (build 140). `scripts/v4_training_sources.json` still pins the earlier model
  that V4 research was bootstrapped from.
- Production `.app` contains no V4 model. `layout-model-v4.json` and
  `LayoutRerankerV4.mlmodelc` belong only to `Experimental/V4`.

`scripts/build_language_model.py` reproducibly builds the V3 artifact. Inputs and
hashes are pinned in `scripts/v4_training_sources.json`:

- Google Books frequency data, CC BY 3.0.
- English Speller Database/SCOWL levels 35, 50 and 60, generated from one
  pinned revision with commands and hashes recorded in the manifest. Runtime
  uses these as common/standard/rare evidence, never as per-word overrides.
- LibreOffice Russian Hunspell dictionary revision
  `38d96a4d54ec3449cf7f28cddae1fce32e2b15a7`.
- The Russian dictionary expands lowercase forms with one SFX rule and stores
  roughly 1.42 million forms in a 2^25-bit, 9-hash Bloom filter.

Keep `THIRD_PARTY_NOTICES.md`, source archives under `scripts/data`, manifest
hashes and `build_app.sh` resource copying synchronized. The app performs no model
downloads and no network inference.

## Privacy

- Decoder, models and personal learning are local.
- Debug logs contain only lengths, language/evidence categories, revision,
  latency buckets and transaction outcomes; never words or neighboring text.
- The anonymous-statistics UI, reporter, persistence and localization keys were
  removed. There is no statistics endpoint.
- The obsolete repository stats workflow, Telegram reporter and committed
  history were removed in build 129; Stability CI has read-only permissions.
- `rslog` accepts only `StaticString`; dynamic user text, context, paths, layout
  IDs, bundle IDs and localized errors cannot be passed to it.

## Test Corpus and Current Results

User-provided external files (not committed):

- `/Users/bezh/Downloads/mixed_word_layout_stress_test_5000.txt`
- `/Users/bezh/Downloads/mixed_word_layout_stress_test_pairs_5000.tsv`

The TSV has 5,000 phrases and 59,388 labelled tokens. Import/run with:

```bash
python3 scripts/run_mixed_layout_tsv_suite.py \
  /Users/bezh/Downloads/mixed_word_layout_stress_test_pairs_5000.tsv
```

Last audited result:

- 58,938 / 59,388 tokens correct: 99.2423%.
- 4,572 / 5,000 phrases entirely exact.
- 100% keep accuracy for correct English, correct Russian and technical tokens.
- 450 remaining failures were safe misses; zero wrong replacements/false positives.
- Reports are generated under `.build/mixed-layout-5000-*.json*`.

Pure and deterministic checks:

```bash
swift test
swift test -c release
bash scripts/lint_bound_contains.sh
swift run -c release RuSwitcherSimulator --output .build/simulator-final-report.json
bash scripts/run_randomized_layout_suite.sh
bash scripts/verify_simulator_negative_control.sh
bash scripts/run_headless_typing_simulator.sh
python3 scripts/run_mixed_layout_event_stream_suite.py \
  /Users/bezh/Downloads/mixed_word_layout_stress_test_pairs_5000.tsv --jobs 8
bash scripts/run_headless_native_parity_test.sh
bash scripts/verify_v3_only_build.sh
```

The current source contains 320 XCTest cases: RuSwitcherTypingTests 44,
RuSwitcherCoreTests 174 and RuSwitcherAppSupportTests 102. Run them in both
configurations (`swift test` and `swift test -c release`); see the Swift 6.4
optimizer hazard below. V4's 12 research tests run
only from its separate package. The headless event-stream fixture must pass and
its intentionally wrong expected output must fail.

The 450 safe misses in the 5,000-phrase corpus are six repeated ambiguous
lexical bases: `где` 157, `next` 95, `I` 77, `буфер` 67, `я` 41 and `he` 13.
They are abstentions, not wrong replacements.

The full headless event-stream corpus mode keeps every phrase sequential and
isolated while scheduling separate phrases in parallel. Build 128 processed the
59,388-token corpus with 8 workers in 2.087 seconds: 58,938 correct tokens, 450
safe misses, zero false/wrong replacements and zero duplicate transactions. A
fresh clean build-126 checkout produces the same 450 misses; the historical 443
report came from an unreproducible uncommitted decoder state. The batch quality
gate rejects any false replacement, wrong replacement, duplicate transaction or
regression above 450 safe misses.

Learned-rule persistence is tested by `scripts/run_manual_learning_test.sh`: an
unknown pair stays unchanged before training, selected-text double Shift creates
a confirmation, buffered-token double Shift converts the unfinished word in the
phrase `сегодня я ...`, and previous-token double Shift converts the last word
after a Space. The probes assert a zero pasteboard `changeCount` delta for all
three manual paths. The next physical-key input converts, and the conversion
still works after restarting RuSwitcher Pro. Each native probe runs alone so two
global event taps cannot process the same trigger. The script restores the
complete preferences domain afterward, so it does not pollute the user's
dictionary.

Forced manual toggle cycles are tested by
`scripts/run_manual_toggle_cycle_test.sh`. The short native CGEvent probe covers
the current Cyrillic token, a real selection, an immediately auto-converted
previous word and a token recovered before the caret after navigation. It
asserts the exact text after every double Shift, preserves two spaces in the
caret scenario and requires a zero pasteboard `changeCount` delta. The
Cyrillic-token scenario forces targeted synthetic-input fallback so the non-AX
editor path remains covered. The probe also records every observed layout and
fails unless both and only the configured RU/EN layouts are used; isolated
defaults can never auto-select a Chinese IME.

Real CGEvent tests, without Computer Use:

```bash
bash scripts/run_hid_batch_tests.sh
bash scripts/run_hid_stress_tests.sh
bash scripts/run_native_release_smoke.sh
```

- Every native script defaults to `/Applications/RuSwitcherPro.app` and rejects
  a bundle whose ID, version, build or executable hash differs from the current
  source-built app. The reference bundle is mandatory unless hash comparison is
  explicitly disabled. `RUSWITCH_EXPECTED_BUNDLE_ID`,
  `RUSWITCH_ALLOW_VERSION_MISMATCH` and `RUSWITCH_ALLOW_HASH_MISMATCH` are
  explicit escape hatches for intentional fork testing.
- App-facing fixtures and result files are staged under a unique temporary
  directory so macOS Documents TCC cannot stall `Data(contentsOf:)` in a probe.
- `run_native_release_smoke.sh` uses one mixed automatic phrase plus caret-word
  and real-selection double-Shift cycles. It exits 77 as blocked unless run in
  an isolated macOS session or with `RUSWITCH_ALLOW_FOCUS_STEALING=1`.

- The authored stress fixture contains 16 natural mixed-language phrases, 164
  alternating-layout phases and 939 physical input characters in one
  `NSTextView`, without pauses after words.
- It passed exactly after the stateful dead-key and asynchronous AX verification
  fixes, including straight/double quotes under US International-PC, wrappers,
  `?!`, `...`, `@`, email, `plan B`, one-letter conjunctions and alternating
  RU/EN words.
- Do not run multiple CGEvent UI probes in parallel: macOS has one focus/layout
  event stream. The pure simulator may use parallel workers.
- `headless-native-parity-trap.json` is shared by the headless simulator and the
  native host. Its 15 phases cover both-known
  context, short words, dead-key quotes, punctuation/layout-letter ambiguity,
  ranked RU-to-EN words, email, `plan B`, double spaces and a rare Russian word.
  The current expected trace contains 11 transactions. Build 88's earlier
  13-phase fixture produced the same exact text in both paths: 9 planned
  headless transactions and 9/9 native
  posted/verified transactions, with no external input, layout mismatch or
  boundary timeout. The native host disables macOS double-space period and
  automatic capitalization only through a volatile test-process defaults domain.
- The headless typing simulator opens no window and does not touch the global
  event stream. Its legacy mode feeds literal characters and ideal replacements;
  it does not verify asynchronous state, layout-switch delivery or learning.
  The native probe currently shares a process with AppDelegate/NSTextView, so
  its local AX success does not establish external-editor compatibility.
- HID probes use the isolated `com.ruswitcher.hidhost` preferences suite, reset
  at probe startup, so corpus runs cannot train or mutate the user's learned
  rules. The manual persistence script opts into the standard domain explicitly,
  backs it up and restores it on exit.
- The build-128 ranked-English native fixture is
  `Tests/Fixtures/HID/ranked-english-build128.json`. Its latest launch was
  blocked because macOS did not grant the probe window focus, so it is not
  counted as a native pass. The normal installed process separately showed an
  enabled event tap; deterministic decoder/event-stream coverage passed.

### Unreleased validation work (September 10)

- First checkpoint: 213 Swift tests passed with no skips; 11 Python artifact
  checks passed. The existing international-layout test now runs rather than
  skipping an installed-but-disabled source. Both legacy corpus paths retain
  58,938/59,388 exact tokens, 450 safe misses and zero false/wrong replacements.
- `python3 scripts/run_physical_typing_suite.py` runs one continuous RU/EN
  physical fixture and negative controls without windows or desktop input.
  `--physical-input` accepts a `stimulus` (keys/times/layout pair) plus a separate
  `oracle` (expected text/layout/checkpoints). The runner cannot read the oracle.
- System layouts are loaded read-only by exact input-source ID, including
  installed-but-disabled sources; tests do not enable/select them. Independent
  golden keys cover `,`/`б`, `.`/`ю`, shifted punctuation and Caps Lock.
- The first physical checkpoint modeled ideal synchronous delivery. The third
  checkpoint below replaces it with a virtual schedule. Automatic dead-key
  composition is explicitly unsupported, not a silent pass;
  the underlying stateful Carbon translator has a separate real-data unit test.
- The release CLI suite checks auto-off, missing layout switch, drop/duplicate
  insertion, wrong oracle, missing input, absent layout and legacy oracle
  isolation. JSON reports contain fixture/model/layout hashes and complete
  synthetic-input traces. Missing layouts return 77/`blockedEnvironment`.
- Legacy `--phrase-input` no longer reads an expected verdict to set the next
  source language. `manualLanguage` persists until the next explicit declaration.
  Its report label is `legacy-text-ideal-delivery`; physical mode is now
  `physical-keys-scheduled-delivery`. Neither is a full native parity claim.
- Corpus wrappers archive each run under `.build/corpus-runs`, invalidate the
  previous audit before launch, and require fresh complete ordered results with
  matching exit status/counts. Empty corpora are invalid. Event-stream quality
  still permits the baseline 450 safe misses; the strict decoder wrapper returns
  1 for those completed mismatches. `invalidRun` is a different failure class.
- Second checkpoint: 240 Swift tests passed with no skips; the app builds with
  warnings treated as errors. `InputEventClassifier.classifyLocalKeyDown` now
  drives local production key classification; remote Unicode handling is still
  separate. `InputSession.applyTokenHandlingResult` rejects stale synchronous
  results before they can clear a newer token.
- `AutomaticReplacementDriver` is connected to AppDelegate and the native
  coordinator. It queues acknowledgements until staging can finish and ignores
  duplicate acknowledgements/submissions. Confirmation checks app/known field,
  revision, sequence and token integrity. The target layout changes only on a
  new post, never again on a delayed acknowledgement.
- Ten new lifecycle tests use the real coordinator, driver and InputSession
  with controlled reader/poster fakes and a virtual scheduler; 17 additional
  tests cover local classification. These are contract tests, not native-event
  delivery evidence. At that checkpoint scheduling was not wired into the CLI.
- Third checkpoint: the physical CLI now uses the same local classifier,
  NativeReplacementCoordinator, AutomaticReplacementDriver and staged session
  result handling. Its context capacity matches production's
  `InputContextLimits.maximumTokens` (16), not the legacy default (5).
- VirtualTextEditor models UTF-16 selection/caret ranges, grapheme edits and
  per-field revision. Physical timestamps drive a stable FIFO virtual scheduler;
  each synthetic key event, layout switch, read-back and acknowledgement is
  separate. Input continues without boundary waits. Synthetic events mutate
  the editor but never feed back into InputSession.
- Verified: 269 Swift tests passed; the physical CLI release suite passed all
  19 harness checks, including expected failing fault runs. Those counts do not
  certify native delivery, manual learning, modified host commands, asynchronous
  preflight or a complete shared AppDelegate decoder/policy path.
- The third checkpoint exposed two modeled runtime limitations: losing a Backspace
  or duplicating insertion can leave extra text while suffix-only read-back
  still reports verified; 16 ms delayed delivery during 1 ms key intervals can
  corrupt following input. Independent whole-editor assertions reject both.
- Fourth checkpoint: `TextContextPreflight.matched` carries an immutable
  `TextReplacementAnchor` with the resolved field and up to 64 UTF-16 units of
  preceding text. Native and simulated verification now require the expected
  caret, exact anchored range and unchanged prefix plus replacement. No anchor
  text is logged or persisted. Without a preflight anchor the explicit AX-less
  opt-in remains `postedUnverified`, even if AX becomes readable later.
- Native preflight retains the 4 ms outer deadline and one suffix-mismatch retry;
  verification uses a 120 ms deadline set before queueing. Field-identity
  mismatch never falls back to another field. Observed mismatch cannot become
  AX-unavailable merely because its retry timed out. Local NSTextView reads and
  polling run on the main actor without sleep; this local path also needs an
  AX-resolved field identity and still awaits native-host verification.
- The anchored verification checks and all 19 physical CLI harness checks pass. The
  lost-Backspace/duplicate-insertion controls now have zero confirmations. Their
  text still fails the independent oracle: detection does not repair damage.
  Delivery overlapping the next input is not yet prevented. Native latency and
  actual editor compatibility remain unverified; no new bundle was installed.
- `NativeKeyboardEventBatch` now prepares deletion, Unicode and every replay
  boundary before TextConverter posts the first event. Allocation failure on
  the final boundary keyUp rejects the whole batch. The old private event
  builders/postKey helper were removed after checking all call sites. Five
  tests construct actual CGEvent objects without posting them, check order and
  markers, and inject final-event/source allocation failure.
- Native CGEvent inspection showed that setting an empty keyUp Unicode string
  does not guarantee an empty getter result: Quartz can derive a character
  from its keycode. Keep separate down/up objects and put the explicit full
  replacement payload on down only; do not claim an empty keyUp or alter the
  keycode just to satisfy a synthetic test. See Apple's
  [Unicode event contract](https://developer.apple.com/documentation/coregraphics/cgevent/keyboardsetunicodestring(stringlength:unicodestring:)).
- The expanded 283-test suite also passes AddressSanitizer; this covers memory
  access in exercised paths, not external editor delivery or leak-free lifetime.
- Next: characterize overlapping native event delivery, finish shared
  decoder/policy orchestration and missing simulated event semantics, then
  compare one identical short scenario in an external
  native host. No installed app or production decoder changed; native checks
  and installation remain pending.

### External native harness (September 10)

- `scripts/run_external_native_suite.py --prepare-only` compiles the app, host
  and driver with warnings-as-errors, validates the input-only stimulus and
  report formats, and returns `preparedNotRun`. It never opens a window or posts
  an event. The compiled source fingerprint and executable hashes are recorded.
- Live execution requires `RUSWITCH_ALLOW_FOCUS_STEALING=1`. It uses distinct
  app/editor/driver PIDs, one continuous mixed phrase and an auto-off negative
  control. The driver has absolute timestamps, no per-word waits, and rejects
  schedules more than 10 ms late instead of silently slowing the test.
- The app entry `--external-native-probe UUID session.json --host-pid PID`
  starts the production monitor/replacement path without onboarding or update
  checks, restricted to that host PID. Preferences/rules use a unique
  `com.ruswitcher.nativeprobe.<uuid>` domain. Test logs read that domain's debug
  flag, and isolated startup no longer deletes the user's obsolete stats file.
- `--restart-installed-pro` is an explicit opt-in for stopping only the exact
  `/Applications/RuSwitcherPro.app/Contents/MacOS/RuSwitcherPro` process after
  permission/signature checks, then restoring it with PID/hash verification.
  Other switcher processes block the run; the harness does not kill them.
- The host records trusted marked events and its actual text/UTF-16 selection.
  Foreign input/focus loss aborts without serializing the new user text. The
  verifier checks fresh run IDs, distinct PIDs, text, selection, layouts, input
  counts, scheduling, and app post/confirmation counts. Seven Python negative
  checks cover malformed/stale/incomplete/incorrect evidence.
- Current state: preparation/self-checks succeeded; 286 Swift tests passed. The
  user allowed a short live run, but preflight returned exit 77 before any window
  or event tap was opened. The signed driver explicitly reported
  `postingAccess=false enabledLayouts=true`. The signed app's preflight also
  failed; its designated requirement matches the installed app, which does not
  prove OS access for a separately launched process. No privacy database,
  signature identity or trust setting was modified to bypass this gate.
- The installed build-130 process stayed PID 2151 throughout this failed attempt;
  executable hash remained `2b59f4bc61eaad8754a75442d75d7798af37a576a9139dacc85f2b2c984044aa`.
  There is no successful external native result yet. First attempt evidence:
  `.build/external-native-first-live.log` and
  `/private/tmp/ruswitch-external-rdee1tbd/summary.json`.
- Current native coverage is automatic input only, AppKit, current architecture.
  Explicit modifier flags are supplied with keys; physical flagsChanged/manual
  double-Shift, WebKit/Electron, persisted learning and callback p99 remain
  outside this first external harness. Do not claim full native parity or a
  release pass from preparation, self-checks or a blocked run.
- After resume, `--preflight-only` was added as a read-only access check, without
  a focus flag or app stop. The fresh signed probe reported all three access
  flags false; the driver reported posting false and enabled layouts true.
  Evidence: `.build/external-native-resume-preflight.log`. The tool never
  requests or changes privacy grants; successful access is
  `permissionsReadyNotRun`, never a native pass.
- Review found three false-green paths in the new harness, not three decoder
  bugs. Auto-off now has a separately authored raw-text oracle; its integrity
  must pass as well as the normal oracle failing. Every delivered input has a
  unique action marker, so loss plus duplication of another key cannot hide in
  matching aggregate counts. Only posted conversion boundary keyDowns may be
  absent. Completion rechecks actual editor text, selection and focus instead
  of blindly writing a cached good snapshot. The final native snapshot fix is
  source-verified and builds; its live race has not yet been exercised.
- The test app uses the production hardened-runtime flag and entitlements with
  the same reusable identity. These are packaging parity, not a TCC workaround.
  287 Swift tests and 23 Python artifact/assessor tests pass. Native delivery,
  external editor behavior and the modeled overlapping-input failure remain
  unverified/unresolved; no new app has been installed.
- Permission requests are explicit CLI actions (`--request-access`) on the
  validated probe/driver configuration; they exit after the standard macOS
  request and never start an event tap or type. Ordinary `--preflight` and the
  wrapper's `--preflight-only` do not request grants. The user authorized one
  request; installed Pro was neither stopped nor replaced.
- After the Mac restarted, installed Pro retained the build-130 hash and ran as
  PID 1566. The old `/private/tmp` probe bundles were gone. The wrapper now copies
  completed reports/configs/logs into `.build/native-runs/<runID>` (without app
  bundles), publishes the archived summary last and refuses run-ID reuse.
  `artifactDirectory` points to durable evidence; `directory` is the runtime
  location. All 25 Python artifact/assessor checks pass, including temporary
  directory deletion and duplicate archive-ID controls.
- Post-restart TCC attribution is now verified, not inferred: both test
  processes were attributed to responsible `com.openai.codex`, whose current
  `/Applications/ChatGPT.app` has display name `ChatGPT`. Its Accessibility and
  Input Monitoring grants are the relevant UI entries for direct child-process
  tests on this host. Evidence: `.build/native-permission-attribution.log` and
  `.build/native-after-restart-preflight.log`. Do not add private TCC entitlements,
  change signing identity or launch through another privileged app to evade a
  refusal. No successful external native run has occurred yet.

### Shared automatic preparation (September 10)

- `AutomaticConversionPlanner` is now the same decoder-to-request path for
  AppDelegate and the scheduled physical runner. It preserves raw never checks,
  EN/RU/model availability, snapshot context/belief/Caps/integrity, adaptive
  callbacks, keep/finalize handling and exact transaction fields. The old
  `AutoSwitchPolicy.isDeniedWord` helper has no remaining callers and was removed.
- Target-layout resolution is lazy: keep, missing-model and denied-word paths
  do not resolve the target input source. Remote switch-only handling still
  stays in AppDelegate and does not require that lookup.
- 294 Swift tests passed with warnings-as-errors, including seven planner
  characterization tests. All 19 physical-suite harness checks passed. The
  complete positive execution JSON before/after the refactor is identical:
  `.build/physical-runs/closed-loop-f8hk3xsu/positive.json` and
  `.build/physical-runs/closed-loop-1z40xkqi/positive.json`.
- This is shared preparation, not full runtime parity. OS host/secure/remote
  gates, physical mapping adapters and learning persistence still have native
  wrappers; physical fixtures do not yet model user preferences/learning. The
  overlapping-delivery failure remains unresolved. Decoder weights, dictionary,
  installed build and user rules were not changed.

### First external native evidence (September 10)

- OS grants were approved; app and driver preflight now report access. Installed
  build 130 was stopped only for each authorized short run and restored with
  executable-hash/PID verification. The latest restored PID was 6044.
- The first driver run stopped on action 0 at 10,018 microseconds lateness, so
  it did not test conversion. `--timing-check` now measures source lookup and
  event preparation without posting; the cold input-source read measured 32.8 ms.
  Live records split focus/read/preparation/post duration. First post itself is
  still about 9 ms; no deadline was increased or timing pass assumed.
- The driver previously blocked the main run loop with sleep. A no-window
  timer/cancellation self-check failed on that code (exit 64) and passes when
  waiting services the default run-loop mode. Initial source verification and
  non-posted object warmup occur before the input schedule. Absolute per-key
  deadlines remain unchanged; no conversion-dependent wait was added.
- Existing `physical-closed-loop.json` remains an unresolved manual-source
  transition trap: a `selectLayout` and following key share one timestamp;
  native produced `фnd` instead of `and`, despite the driver observing US.
  Its first automatic replacement was posted/verified. The oracle was not
  changed to accept the wrong letter. Evidence: native run
  `9511ec04-5197-4604-921b-d67f354ab6b4` under `.build/native-runs`.
- New `physical-auto-code-switch.json` has 93 physical presses, no manual
  source-change commands, and three independently expected automatic switches.
  It covers RU/EN/RU prose, punctuation and `plan B`; keyDown spacing is 70 ms,
  each keyUp follows its keyDown by 23 ms, without per-word pauses. Headless text, final layout and
  three transition checkpoints pass, with three confirmations.
- In native run `352414a6-96b7-47c7-be62-210f30328d57`, that full text/selection,
  all layout checkpoints and 3 posted/3 verified replacements also matched.
  The full case still failed: original boundary keyDowns 14/68/152 were consumed
  as expected, but original keyUp 15 was absent. All 186 producer actions
  completed, max lateness 9,837 us; no foreign input was recorded. The cause of
  the missing release is not established and is not silently exempted.
- Host reports now separate `receivedEvents` in the AppKit local monitor from
  `eventTrace` after NSTextView handlers. Assessors require actual receipt data,
  not handler callbacks as a proxy. This is still not a global Quartz tap
  observation. The native negative control has not run because the positive
  delivery gate fails first; there is no full external-native suite pass.
- The runner now collects the auto-off control even after a completed positive
  quality failure, retaining an overall failed result. Invalid/interrupted
  evidence still aborts before another window. Two mocked orchestration tests
  cover that distinction; the amended two-case flow has not run natively yet.
- Further UI runs were paused after these short attempts. Next: resolve the
  missing-release observation and characterize explicit source-change latency,
  then complete the native negative control and fast-overlap case. A correct
  normal-speed phrase does not prove all editors or fast input are safe.

### Deletion-span safety checkpoint (September 10, unreleased)

- Windowless `NSTextView` tests reproduced destructive editing: UTF-16-based
  Backspace counts erased preceding prose for emoji/combining text; an inflated
  physical-key count also erased prose for an ASCII suffix. The pre-fix run
  failed with 14 assertions in two tests. This is real AppKit editing, not
  AX/CGEvent transport or a visible test window.
- Automatic and manual keyboard-deletion paths now use the suffix, never an
  inflated stroke count. Nonempty suffixes are accepted only when grapheme and
  UTF-16 counts match; otherwise posting is refused. AX-less opt-in cannot bypass
  this guard. Real AX selection replacement is unchanged. Complex Unicode is
  unsupported by this fallback rather than guessing editor deletion semantics.
- `ambiguous-unicode-deletion.json` exercises a real V3 conversion proposal in
  prose: the legacy CLI records `ambiguous-deletion`, preserves the text and
  posts nothing. A dictionary keep cannot falsely satisfy this regression check.
- Verified: 298 Swift tests passed with warnings-as-errors; 20 focused tests
  passed under ASan. All 20 CLI harness checks (physical plus legacy controls)
  passed in `.build/physical-runs/closed-loop-e9h47mjj`; expected-failing overlap
  controls remain detected failures, not release acceptance.
- Legacy 5,000-phrase audit: 58,938/59,388 exact tokens, 450 safe misses, zero
  wrong replacements or duplicate transactions (`event-stream-68kv9zmx` under
  `.build/corpus-runs`). This is not native-delivery proof. Installed build 130
  and user rules are unchanged; native release gates remain pending.

### Process-level delivery observation (September 10)

- The external host now observes its own PID with a listen-only Quartz tap
  before AppKit dispatch. Host schema 2 records key type/code, exact action
  marker, event timestamp and callback timestamp, never key text in that trace.
  Creation failure exits 77 before opening a window; tap interruption or trace
  overflow interrupts the case. No global input or production code was changed.
- The assessor retains the separate AppKit receipt gate. A Quartz-only keyUp
  cannot make missing AppKit delivery pass. Diagnostics distinguish releases
  unobserved at the process tap from releases observed there but absent at
  AppKit; neither alone proves why an event disappeared. Both positive and
  auto-off cases require the observer and preserve the prior exact-text gates.
- 20 Python native-harness checks passed. Release compilation with
  warnings-as-errors and no-window serialization self-checks passed in native
  preparation `044a7aae-5fd3-4988-9aa8-99b2df254628` (`preparedNotRun`). Do not
  infer native overlap corruption from deliberately delayed virtual transport.
- Authorized live run `28baa820-e962-4f3d-a1af-25652da0bb10` at source `054fe4a`
  passed the short `physical-auto-code-switch.json` fixture and its independent
  auto-off control. Exact 93-character text, caret, three layout checkpoints and
  3 posted/3 verified replacements matched; auto-off matched its literal oracle
  with zero replacements. Both cases delivered all expected original key-ups
  through the process tap and AppKit, with no interference or duplicates.
  Receipt totals were 233 with conversion and 186 without; each driver completed
  186 actions. Maximum scheduling lateness was 8,702/8,489 microseconds.
- This is one successful normal-speed native fixture, not a release-wide pass.
  The earlier missing key-up did not recur; its root cause is still unknown,
  and adding an observer may itself affect timing. The zero-gap manual-source
  trap, rapid-overlap acceptance and other editor/manual-learning gates remain
  open. No further live run was launched. Installed build 130 was restored as
  PID 16207 with its unchanged SHA-256; no new build was installed.

### Rolling-Space timing checkpoint (September 11, windowless)

- The physical CLI suite now derives a rolling-Space variant of the same mixed
  phrase: ordinary keyDown intervals remain 70 ms, but the next key after Space
  arrives after 5 ms while Space is still held. Original 23 ms hold times,
  keycodes/modifiers and initial layout are preserved. Actions are re-sorted;
  oracle checkpoint indices are remapped separately, without guiding input.
- All 23 CLI harness checks passed (`closed-loop-xb_jxm1f` under
  `.build/physical-runs`), including exact rolling-Space output, its independent
  auto-off literal oracle, and detection of intentionally delayed delivery.
  A 4 ms delivery delay plus 100 us between synthetic events damages the next
  token in this model; it receives zero confirmations, not a false pass.
  All 34 Python checks passed. No new native run or installation occurred.
- A 16-profile exploratory grid (`.build/timing-grid-523ogghm`) varies keyDown
  intervals 70/20/5/1 ms and delivery delay 0/4/8/16 ms, with 100 us event spacing.
  All 70/20 ms profiles are exact; 5 ms fails with nonzero delay; 1 ms fails even
  without initial delay. These are modeled limits, not measured user typing.
- In the successful native trace, producer-boundary-post return to final Quartz
  receipt measured 7.150, 2.474 and 12.154 ms for three batches. This includes the
  event route, not just the callback. Three samples do not establish p95/p99 or
  justify tuning production delays. Parse Int64 markers with exact integers;
  floating-point JSON arithmetic loses their low bits and misidentifies actions.
- Next diagnostic: measure callback occupancy before treating virtual overlap
  as native corruption. The virtual clock currently does not charge synchronous
  callback work, whereas a real callback may hold later input in the tap queue.
  Do not hide the modeled failure or switch delivery APIs based on this grid.

### Callback timing and processing checkpoints (September 11)

- Only `--external-native-probe` installs `KeyboardMonitor.onCallbackTiming`.
  Normal runs leave it nil and do not read the clock for this measurement.
  The span starts after marker/userInfo guards and ends before the observer;
  it includes synchronous conversion work, not observer recording or OS delivery.
- App-probe schema 2 exports trusted test action indices, keycodes, start/end
  nanoseconds, consumed flags and the source layout already read by the normal
  key-processing path. There is no extra TIS lookup. No text is read for this trace. Detailed rows
  are exported only at stop, avoiding repeated serialization during input.
  Overflow, missing/invalid timing rows and disagreement with actual consumed
  keys reject acceptance. Reports give sample counts/maxima, not a claimed p99.
- Native run `3c5dc4e6-92fd-4861-ac66-2ce0081ba0c7` produced exact rolling-Space
  text and complete input delivery, but failed the old checkpoint assumptions:
  the producer posted the next key while the previous callback was active,
  whereas that key was processed only after the callback finished. Conversion
  callbacks took 17.997-21.384 ms. The producer's earlier layout snapshot is not
  the layout used at processing time; it remains diagnostic, not the oracle.
- Native keyDown checkpoints now use the captured processing source. Missing
  layout switching still fails. Confirmation counts follow the existing optional
  `verifiedCompletions` oracle: always require 0 <= verified <= posted; require
  the exact count when specified. The ordinary fixture explicitly requires 3;
  rolling input permits stale confirmations to be ignored, as the production
  completion contract requires after new input. Text and receipt gates remain
  mandatory; old failed reports were not rewritten.
- Rolling run `b6b9e8f3-9e81-4aa7-9a03-b4c61d8f298a` passed with 3 posts, exact
  text/layout/receipts and 0 confirmations; its auto-off control matched exactly.
  Ordinary run `3019ddf8-458c-4d1b-80eb-3bafe1641fb6` passed with the stricter 3/3
  post/confirmation requirement and its auto-off control. These validate this
  NSTextView fixture, not all editors, manual learning or arbitrary overlap.
- Removed redundant TISEnableInputSource calls from LayoutSwitcher: its
  TISCreateInputSourceList(..., false) already lists enabled sources only, per
  Apple's SDK contract. Native selection still works. A speedup is not proven:
  converted-key callbacks remain about 15-24 ms, above the target budget.
- 298 Swift tests, 42 Python checks and 23 physical CLI checks passed. Installed
  build 130 was restored with unchanged hash as PID 23679. No new build was
  installed; the model and user's rules remain unchanged.

### Independent text preparation (September 11, not evaluated)

- `Tests/Fixtures/Independent/flores200-clean-v1` freezes 2,009 EN/RU sentence
  pairs from 562 FLORES-200 source articles under CC BY-SA 4.0. Full license,
  attribution, article URLs, upstream/member hashes and reproduction instructions
  accompany the 436 KiB test-only artifact. It is not an app resource or training
  input, and no user text is collected.
- `scripts/prepare_independent_corpus.py` verifies the pinned archive/license,
  groups whole articles and exact normalized translation duplicates, then assigns
  groups by fixed hash to development/calibration/test. It preserves sentence
  strings and refuses to overwrite an existing corpus. Two independent output
  directories produced byte-identical compressed data and manifests; 3 unit
  tests cover grouping, reproducibility, checksum failure and overwrite refusal.
- Split sizes: 1,222/400/387 pairs in 339/113/110 groups. Test has 8,225 EN and
  7,555 RU whitespace tokens, below the planned 50,000-per-language gate. These
  are news/explanatory/travel texts, not full chat/work/code or OOV coverage.
  No decoder evaluation or synthetic error profiles were run yet. Never tune on
  the frozen test split or silently normalize its punctuation for physical input.

### Queued-key layout transition checkpoint (September 11, not installed)

- Moving health diagnostics off immediate status-icon updates removes synchronous
  permission/front-app/sibling queries from that UI call path. Sibling presence
  is cached from workspace launch/termination notifications, with snapshots at
  startup, wake and menu opening. The health tooltip refreshes on the existing
  two-second UI timer. Conversion safety checks remain live and unchanged.
- The optional native `--sample-process` mode samples only the owned positive
  probe; it never runs in prepare/preflight-only mode. Sampled timings are marked
  diagnostic. Run `04baee4c...` was invalid due to driver scheduling lateness;
  its stack sample caught a slow startup icon/LaunchServices query, **not** a
  converted event callback. No timing limit was relaxed. Helper display names
  no longer contain RuSwitcher, so they do not masquerade as sibling switchers.
- Rolling-Space run `30ed5867-b687-4289-910e-28a0a99bc7a7` failed with `vы` and
  `кeview`. All original event receipts and processing-layout checkpoints were
  intact. Control `c6d7adb7-00e5-4880-936f-0e3c678d6837`, with synchronous icon
  updates restored, also failed and added `jбсудим`. The asynchronous-icon
  experiment was rejected and removed.
- Evidence: the next key was posted while the boundary callback was still
  working. By processing time the monitor's TIS source had changed, but the
  external NSTextView received its keyDown in the earlier layout; its later
  keyUp already used the target layout. Producer CGEvent Unicode diagnostics
  were removed after the control because they are not the AppKit interpretation.
  The test-only host now records accepted NSEvent characters alongside its
  existing exact-text trace. Unmarked/user input is still rejected.
- `QueuedLayoutTransition` now covers only local EN/RU automatic switches whose
  TIS selection succeeded. Queued printable keyDowns timestamped no later than
  that switch receive the session's translated Unicode on the **original**
  event. There is no deletion, repost, sleep, timer window or word-specific rule.
  Newer timestamps, layout mismatch, editing/focus reset, shortcuts, dead keys
  and complex Unicode close or bypass this narrow transition. Remote/listen-only
  input and the Input Method are not rewritten. Apple documents that frameworks
  may interpret [keyboard Unicode overrides](https://developer.apple.com/documentation/coregraphics/cgevent/keyboardsetunicodestring(stringlength:unicodestring:))
  differently, so NSTextView success is not a claim about every editor.
- Fixed rolling run `19c7c54c-ef9f-4b96-94d8-8f1d4bc6c578` and ordinary run
  `e9970ba3-a36e-4d26-ba23-7157d7415f9e` both passed exact text/caret/layout,
  complete Quartz/AppKit receipts and independent auto-off controls. They use
  one continuous 93-character phrase, with no per-word waits; rolling puts the
  next key 5 ms after Space. Ordinary input retained its strict 3 posts/3
  confirmations gate. Rolling had 3 posts/0 fresh confirmations as expected
  after subsequent input. No test oracle was changed to accept the bad letters.
- Conversion callback samples remain above the 5 ms target: rolling
  13.260/3.537/6.876 ms, ordinary 8.075/9.171/3.535 ms. This is neither p99 nor a
  completed performance gate. The physical simulator still lacks callback busy
  time and pre-queue layout interpretation; it does **not** yet reproduce this
  native race. Shared transition unit tests and the external host establish
  this fix; do not attribute it to existing headless parity.
- 306 Swift tests, 45 Python harness checks, 26 focused ASan tests and 23 physical
  CLI controls passed. The physical suite still reports its known modeled
  overlap limitations; those expected failing controls are not runtime fixes.
  The installed build 130
  was restored with unchanged executable SHA-256 as PID 30245 after the final
  windowed run. The new code is not installed; the model and user's learned
  rules are unchanged. Remaining work includes modeled queue
  timing, WebKit/Electron, manual/learning paths and broader release gates.

### External WebKit receiver checkpoint (September 11, test-only)

- `run_external_native_suite.py --editor webkit` selects a real WKWebView
  textarea instead of the default external NSTextView. `--prepare-only` and
  `--preflight-only` keep their no-window/no-input contracts; preparation
  self-checks the selected host argument and typed DOM state serialization.
- The test page is inline, nonpersistent and restricted by CSP to no network
  resources. It never sees an oracle or injects fixture text. Only marked
  driver/app events pass the native monitor; clipboard/drop events and user
  interference stop the test. Production dependencies/resources are unchanged.
- WebKit reports trusted DOM keyDown/keyUp/input/selection events with ordered
  sequence numbers, actual value, UTF-16 selection and focus. Final completion
  requires a new read-only JavaScript query matching the event-driven state,
  with a 250 ms deadline. A missing or mismatching read is not called verified.
  Native Quartz and AppKit receipts remain mandatory. DOM keyboard counts must
  also match AppKit; DOM events are not relabelled as NSTextView dispatch.
- Normal run `c52e219d-0910-4519-8c61-342184b79b3a` and rolling-Space run
  `a942e08b-45bb-4e12-b7e7-491e0f211c28` passed the same 93-character mixed phrase
  and independent auto-off controls. Both ended at [93, 0] with exact text and
  3 posts. Normal input had 3 fresh confirmations; rolling had 0, as expected
  after subsequent input. Both positive runs recorded 115 DOM keyDowns and
  118 keyUps, exactly matching native AppKit receipts including replacements.
  Both auto-off runs had 93/93 DOM/native events and zero conversions.
- The DOM count gate was added after inspecting those reports and re-evaluated
  them successfully without changing their original files or the oracles.
  A negative assessor test removes a DOM release while keeping the correct
  final text and verifies rejection. Further tests reject another backend's
  report, absent/untrusted DOM input, stale text and an unverified final read.
- Default NSTextView regression run `862b1c6a-357d-4d15-9c99-d3f54d112e5e`
  passed after adding the WebKit option: 3/3 verified automatic replacements
  and exact positive/auto-off results. 306 Swift and 48 Python tests passed;
  release builds used warnings-as-errors. Installed build 130 was restored
  with its unchanged SHA as PID 33466. No new build was installed.
- This validates automatic conversion in NSTextView and WebKit textarea, not
  Chromium/Electron/Codex, contenteditable, manual conversion, learning or all
  editing commands. Headless queue timing and the remaining release gates are
  still open. Next work can proceed without taking the desktop focus.

### Headless callback queue checkpoint (September 11, test-only)

- Physical input now has distinct arrival and processing stages. A
  `VirtualCallbackQueue` serializes processing and driver acknowledgements;
  the existing clock independently delivers input and synthetic editor events.
  A busy callback does not pause the input producer or the editor transport.
  Queue release is idempotent; incomplete input/callback work is invalid.
- `PhysicalTypingTiming` adds `conversionPrePostMicroseconds` and
  `conversionPostWorkMicroseconds`, defaulting to zero. They model work before
  publication and post/layout work before return, not a measured macOS replay.
  The validation suite uses an explicit 4+8 ms stress envelope with 1 ms editor
  delivery, 50 us synthetic intervals and a 20 ms readback. No oracle controls
  these clocks. Existing artificial late-delivery fault cases remain visible.
- Arrival-time text is translated independently of the layout at callback
  processing. Reports record both, plus processing time and actual delivered
  text. The same production `QueuedLayoutTransition` normalizes eligible
  queued keys; `no-queued-layout-sync` disables it only in the test interpreter.
  Automatic dead-key composition remains explicitly unsupported, including
  a starter captured before a queued layout change. Enter/Tab host semantics,
  external source/focus events and key-up ordering are still modeled contracts,
  not native coverage of every host or OS scheduling path.
- Physical suite `closed-loop-w3a3gcah` passed 29 harness controls. The busy
  profile reproduces the native failure class exactly when synchronization is
  disabled: `vы`, `кeview`, `jбсудим`. With synchronization, the full mixed phrase
  is exact with 3 posts and 0 stale confirmations. All input arrival times are
  unchanged; the three affected letters each wait 7 ms on the callback lane.
  Changing the oracle does not change execution. Auto-off retains the independent
  raw text. With all work costs zero, the old behavior falsely looks correct;
  that result is a demonstrated simulator limitation, not a release pass.
- A separate 30 ms delivery control still damages following text after the
  callback has returned and fails the independent oracle without confirmation.
  This is a configured hypothetical transport fault, **not** evidence that
  native macOS exhibits that exact delay/order. Do not conflate it with the
  first-letter race already fixed and observed in the external hosts.
- 310 Swift tests, 48 Python tests and 16 focused ASan tests passed. A release
  CLI invocation of the 93-character busy fixture took 0.15 seconds wall time
  (`.build/queued-layout-timed.time`), including startup/report generation; this
  is a single run, not a p95 or corpus throughput measurement. Production app,
  model, learned rules and installed build 130 were not changed in this step.

### Swift 6.4 release optimizer hazard (October 12, P01a)

- Swift 6.4 (swiftlang-6.4.0.34.1, Xcode 27.0) under `-O` and `-Osize`
  inverts one of a pair of bound `CharacterSet.contains` method references
  passed to `allSatisfy` and `contains(where:)`. `-Onone` is correct.
  Upstream: [swiftlang/swift#92539](https://github.com/swiftlang/swift/issues/92539);
  it reports `-Osize`, and `-O` was reproduced here. The bug depends on link
  order across object files, so module boundaries do not contain it.
- Release effect: `SmartTokenizer` returned an empty lexical core for every
  word, so decoding was wrong while debug tests stayed green. Release unit
  tests failed 96 of 320 cases. The release simulator's generated fixture set
  grew from 693 to 709 words (limit mode) because its filter keeps a mistyped
  word only when the lexical core has no probability, and an empty core passes.
- Rule: pass `contains` predicates as explicit closures
  (`allSatisfy { scalar in set.contains(scalar) }`), never a bound
  `set.contains`, `set.contains(_:)` or another `.contains(label:)` reference.
  `bash scripts/lint_bound_contains.sh` enforces it in CI repository checks;
  `scripts/tests/test_lint_bound_contains.py` pins which lines it must and
  must not report. At the d6630b6 base it reports all five former sites.
- Static functions and implicit-self methods passed by reference
  (`AutoConvertCandidateGenerator`, `LayoutDecoder`, `LearnedCorrectionsArchive`,
  `SiblingApplicationTracker`'s `filter(isSibling)`) showed no miscompile and
  are unchanged; they are watch items, not proven safe.
- CI job `release-build` on the `xcode-27` runner image runs
  `swift test -c release` and the release `RuSwitcherSimulator`, printing a
  counts-only summary (words total/passed/failed, phrases total/passed) and
  failing when the simulator fails. A final `App bundle` step (P01c) builds the
  unsigned bundle with `RUSWITCH_UNSIGNED_BUNDLE=1 bash build_app.sh` and runs
  `bash scripts/verify_v3_only_build.sh RuSwitcherPro.app`. `xcode-27` is a
  preview label: if it disappears the job queues instead of failing,
  `timeout-minutes` does not cover queue time, and no branch protection
  requires the job.
- Correct tokenization costs about 2.2 us/word in an in-package release
  measurement, above the plan's 2 us ceiling. The same cost appears on the base
  with only the `isMember` closure, so it predates this fix. The broken base
  measured 0.66 us/word only because empty cores skipped classification.

### False-green verification scripts (October 12, P01b)

- `scripts/verify_simulator_negative_control.sh` writes the simulator report to
  a fresh `mktemp -d` directory that an exit trap removes, so another run's
  report cannot satisfy it and nothing is left behind. It fails when `jq` is
  missing, when the simulator exits 0, and when the exit status is anything but
  1, the simulator's normal failure code, so a crash (134, 139) after a report
  was written no longer counts. It then requires `.failed == 1`, an empty
  `failures` list and `phraseFailures` holding only
  `intentional-negative-control`. The intentional phrase is reported under
  `phraseFailures`, not `failures`. Any other failing id is printed after `FAIL`.
- `scripts/verify_v3_only_build.sh` fails when the language model is missing
  from the bundle, when the bundle executable is missing or `lipo -archs`
  rejects it, and when `lipo -archs` does not list both `arm64` and `x86_64`
  because the release bundle is universal. `otool -L` exits 0 on a non-Mach-O
  file, so it is not a Mach-O gate. `otool` and `nm` output is captured before
  `grep`, so their errors fail the script. A missing default bundle prints
  `SKIP: app bundle checks` and the final line says the bundle was not checked;
  an explicit bundle argument that does not exist fails.
- `scripts/tests/test_verify_negative_control.py` and
  `scripts/tests/test_verify_v3_bundle_checks.py` run the real scripts against a
  stub `swift` and, for bundle checks, tiny universal `cc`-built binaries. They
  build nothing from this package and take a few seconds. In these two files a
  missing `jq`, `cc` or `lipo` fails the tests instead of skipping them. Of the 14 cases in the
  first version, 8 failed against the scripts at `2cfb588` (stale report, extra
  word failure, extra phrase failure, unrelated failure, no executable, text
  file, explicit missing bundle, missing SKIP line). The other 6 passed there
  and are regression guards: `testExactlyTheControlFailurePasses`,
  `testMalformedReportFails`, `testSimulatorAcceptingTheWrongExpectationFails`,
  `testCleanMachOBundlePasses`, `testCoreMLLinkStillFails` and
  `testAlternateDecoderSymbolStillFails`. The round-1 cases (crash after a
  report, rival writer at the old fixed path, leftover report, missing `jq`,
  missing model, single-architecture executable) each failed against the
  scripts at `8e63992`. The older `test_verify_v3_only_build.py` keeps the slow
  package-graph cases that run the real toolchain.
- On Swift 6.4, `swift build --arch arm64 --arch x86_64` writes products to
  `.build/out/Products/Release`, so the old hard-coded `.build/apple/...` path
  made `build_app.sh` stop with "built product not found". `build_app.sh` now
  asks `swift build ... --show-bin-path` for the directory (see Build, Signing
  and Installation).

### Event-tap latency checkpoint (build 144)

- The probe-only `CallbackPhaseProbe` marks phases inside a callback
  (`auto.*`, `preflight.*`, `post.*`, `layout.selected`); normal runs install no
  recorder and read no clock. `--external-native-probe` exports `phaseMarks`.
- Stack samples showed `NSWorkspace.frontmostApplication` making synchronous
  LaunchServices round trips on ordinary keys (1.4-4 ms spikes).
  `FrontmostApplicationTracker` caches pid/bundle from
  `didActivateApplicationNotification` (refreshed on wake/session resume) for
  KeyboardMonitor and the automatic gates. Manual-path and pre-post guards in
  TextConverter still query live. The status icon redraws after the callback.
- Native NSTextView runs (non-boundary keys, first key excluded): p50
  162-349 us -> 37-48 us, p95 0.7-1.8 ms -> 72-102 us, max 1.4-2.5 ms -> 155-179 us.
  The before/after fixtures differ (default closed-loop vs auto-code-switch).
- A converted word still costs ~2-15 ms, dominated by the synchronous
  `TISSelectInputSource` (1.2-7 ms) and sometimes the targeted post. The switch
  stays synchronous: deferring it reopens the queued-key layout race.
- Driver `scheduleTooLate` (>10 ms) invalidates some runs; that is an
  environment/harness result, not an app failure.

## Build, Signing and Installation

Before installation:

```bash
swift test
git diff --check
SIGN_ID='RuSwitcher Local Code Signing' bash build_app.sh
codesign --verify --deep --strict RuSwitcherPro.app
lipo -archs RuSwitcherPro.app/Contents/MacOS/RuSwitcherPro
```

Build and register the optional Input Method separately:

```bash
SIGN_ID='RuSwitcher Local Code Signing' bash build_input_method.sh
bash scripts/install_input_method.sh
```

The Input Method build enables hardened runtime only for Developer ID signing.
Its installer must verify both EN and RU sources after restarting the text-input
agents and roll back the previous bundle if registration fails. Do not add the
local self-signed identity to user or System trust: live AMFI testing proved that
it remains ineligible, so the trust expansion has no benefit.

`build_app.sh` stamps `version.json`, builds universal, copies model/licence
resources and signs the bundle. Increment the build number for every installed
binary change.

`build_app.sh` takes the products directory from
`swift build -c release --arch arm64 --arch x86_64 --product RuSwitcher --show-bin-path`
(`.build/out/Products/Release` on Swift 6.4), never from a fixed path. With no
`SIGN_ID` it looks for Developer ID, then `RuSwitcher Local Code Signing`, and
stops with `ERROR: no signing identity found.` when neither is valid; an empty
`SIGN_ID` is the same as unset and never skips signing. Ad-hoc signing
(`--sign -`) must not appear in the script. Auto-discovery uses
`security find-identity -v -p codesigning`, which lists valid identities only.
On the development Mac that command reports 0 valid identities, because
`RuSwitcher Local Code Signing` shows `CSSMERR_TP_NOT_TRUSTED`. A build there
needs an explicit `SIGN_ID='RuSwitcher Local Code Signing'`, which signs fine;
without it the script stops at `ERROR: no signing identity found.`

`RUSWITCH_UNSIGNED_BUNDLE=1 bash build_app.sh` is the CI-only opt-in. It skips
`codesign`, the `Authority` check and `spctl`, prints `UNSIGNED: bundle is for
CI checks only and is not installable`, and fails when combined with `SIGN_ID`.
A value other than `1` is ignored with a `NOTE:` line and the script then
requires a signing identity. The `App bundle` step of the `release-build` job
(`xcode-27`) uses it and then runs
`scripts/verify_v3_only_build.sh RuSwitcherPro.app`. Never install an unsigned
bundle. The bundle is not signed as a bundle, but its Mach-O keeps the linker's
own signature: `codesign -dv` shows `Signature=adhoc` with
`flags=0x20002(adhoc,linker-signed)` and `Info.plist=not bound`, while
`codesign --verify --deep --strict` prints `code object is not signed at all`
and fails. The `spctl` line does not discriminate on the development Mac, where
`spctl --assess` prints `accepted` with `override=security disabled` for signed
and unsigned bundles alike.

`scripts/tests/test_build_app.py` runs the real `build_app.sh` against a stub
`swift` (it supplies the `--show-bin-path` directory), a stub `security` and a
recording `codesign` wrapper that logs its arguments. It covers the products
directory lookup, the opt-in and its conflicts, the universal-binary check, the
version stamp, and the resources. It also covers the no-identity failure,
Local and Developer ID identity discovery (with the wrapper declining to sign),
and a runtime guard that no `codesign` call ever uses identity `-` when no
identity is found, `SIGN_ID` is empty or the opt-in is set. It does not run the
signed path. `codesign --verify`, the `Authority` check and `spctl` have been
checked only by live runs with an explicit `SIGN_ID`, not by any test.

`build_input_method.sh` still hardcodes `BUILD_DIR` to
`.build/apple/Products/Release`. On Swift 6.4 it fails the same way
`build_app.sh` did until a follow-up gives it the same `--show-bin-path`
lookup, so the Input Method build above does not work on that toolchain yet.

The external native harness builds its own probe from the same sources and
cannot launch the bundle `build_app.sh` produces, so only an operator
installation exercises the built bundle itself.

Install atomically:

1. Copy the built bundle to a unique staging path under `/Applications`.
2. Verify the staged signature.
3. Stop the running `RuSwitcher Pro` process.
4. Move the current app to a timestamped backup.
5. Move staging to `/Applications/RuSwitcherPro.app`; do not overwrite the
   author's `/Applications/RuSwitcher.app` or another fork's bundle.
6. Open the app and verify version, architectures, signature, SHA-256 and process.

Build 129 footprint: 11,520 KiB bundle (~11.25 MiB), 72,928 KiB settled RSS
(~71.2 MiB), 0.0–0.5% CPU across six two-second idle samples, and the same
7,405,428-byte V3 model. The installed executable SHA-256 is recorded above.
Always compare installed and freshly built hashes rather than trusting the build
number alone.
