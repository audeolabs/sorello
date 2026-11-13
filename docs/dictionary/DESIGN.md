# Custom dictionary: design contract

This is the current contract for the custom dictionary on macOS, iOS and
Linux: word boosting, casing restoration, correction candidates,
verification, storage and the correction flow. Code comments cite it as
"DESIGN §x". The pinned interpretations it relies on are in
[DESIGN-pins.md](DESIGN-pins.md) and are cited as "pin Px". For the experiments
behind the shipped design, see [../word-boosting.md](../word-boosting.md).

How to read it:

- Every rule names the code, test or shared-vector section that pins it.
  Swift code is in this repository and is named as a symbol and a file:
  paths are relative to the repository root, except that files under
  `Sources/DictionaryKit/` are named from there after their first mention.
  Swift tests are named as `Suite.test` in `Tests/DictionaryKitTests/` or
  `Tests/SpeechEngineTests/`. Rust code is the Linux implementation, in its
  own repository; it is named as a symbol plus `file:line` under
  `linux/crates/`, and line numbers drift as that code changes.
- **Inferred** marks a statement read from the code's behavior when no
  comment, test or vector states it.
- Section numbers match the citations in the code. No code cites §2.1–§2.3
  or §3.3; they are numbered to keep the sequence.
- Swift means `Sources/DictionaryKit/` and `Sources/SpeechEngine/`, which
  the Mac app uses and an iPhone app can share. Rust means the Linux
  implementation's `linux/crates/` workspace.

## §1 Shared algorithms (all platforms)

Swift and Rust implement §1 independently. The shared vectors (§1.7) are
how both are held to it.

### §1.0 Text units

- Characters are Unicode scalars. Strings compare by exact scalar sequence,
  with no normalization: canonically equivalent spellings differ.
  (`DictionaryText`, `Sources/DictionaryKit/DictionaryText.swift`; the
  `lf_text::dictionary` module doc, `linux/crates/lf-text/src/dictionary.rs:6-8`)
- `fold(s)`: each scalar through its full lowercase mapping. Folding can
  lengthen text: `İ` folds to `i` + U+0307. (`DictionaryText.fold`,
  `DictionaryText.swift`; `fold`, `lf-text/src/dictionary.rs:99-102`)
- `upper1(s)`: the first scalar through its full uppercase mapping, the rest
  unchanged. (`DictionaryText.upper1`, `DictionaryText.swift`;
  `upper1`, `lf-text/src/dictionary.rs:104-112`)
- Whitespace is the Unicode `White_Space` property. A letter is general
  category L\*. A word character is L\*, M\*, Nd or Pc. A control character
  is Cc. Uppercase is the Unicode `Uppercase` property (pin P5).
  (`DictionaryText.isWhitespace`, `isLetter`, `isWordCharacter`,
  `isUppercase` and `isControl`, `DictionaryText.swift`;
  `is_whitespace`, `is_letter` and `is_word_char`,
  `lf-text/src/dictionary.rs:114-133`)
- Edge punctuation is exactly `. , ; : ! ? " ' “ ” ‘ ’ ( ) [ ] { } … — – « »`.
  Other symbols, such as `# + & / @ - _`, are kept.
  (`DictionaryText.edgePunctuation`, `DictionaryText.swift`;
  `is_edge_punct`, `lf-text/src/dictionary.rs:135-160`)
- `words(s)`: split on whitespace, with empty pieces dropped.
  (`DictionaryText.words`, `DictionaryText.swift`; `words`,
  `lf-text/src/dictionary.rs:171-174`)
- `norm(w)`: `fold(w)` with leading and trailing edge punctuation removed.
  (`DictionaryText.norm`, `DictionaryText.swift`; `norm`,
  `linux/crates/lf-dictation/src/correction.rs:101-105`)

Tests: `EntryTests.textUnits`, plus the
`lf-asr` unit tests.

### §1.1 Entries, validation and limits

An entry is a text and an f32 strength. Its **identity key** is
`fold(text)`. Two entries are the same entry when their keys are equal
scalar sequences. (`DictionaryEntry.key`,
`Sources/DictionaryKit/DictionaryEntry.swift`; `DictionaryEntry::key`
and `identity_key`, `lf-text/src/dictionary.rs:47-51,245-249`)

Validation runs these steps in order, and the first failure wins. The
shared vector error names are in brackets.

1. If `words(text)` is empty: `empty`. If it has more than 8 words:
   `too-many-words`. The normalized text is the words joined by one U+0020.
2. If the normalized text has more than 100 scalars: `too-long`. If it has
   no letter: `no-letter`.
3. If the normalized text contains a control character: `unencodable`,
   whether or not a vocabulary is loaded (pin P6). If it encodes with
   `<unk>` under the model vocabulary (§1.3): `unencodable`.
4. If the strength is not finite or lies outside [0.25, 8]: `bad-strength`.

The stored text is the normalized text. (`DictionaryEntryError` and
`DictionaryValidation.validate`, `DictionaryEntry.swift`;
`normalize`, `encodable`, `check_strength` and `validate`,
`lf-text/src/dictionary.rs:176-241`; vectors `validation`; `EntryTests.validation`)

Some callers have no vocabulary: loading before the speech model is on the
Mac, or the Linux `localflowctl dict list` without the model. These callers skip
the `<unk>` check in step 3 and nothing else.
(`DictionaryValidation.validate` with a nil encoder,
`DictionaryEntry.swift`; `parse` with no tokenizer,
`linux/crates/lf-daemon/src/dictionary.rs:332-334`) An edit is never
accepted without a vocabulary (§3.3).

| Limit | Value | Source |
|---|---|---|
| Words per entry | 8 | `DictionaryValidation.maxWords` (`DictionaryEntry.swift`), `MAX_WORDS` (`lf-text/src/dictionary.rs:19`) |
| Scalars per entry (normalized) | 100 | `DictionaryValidation.maxScalars` (`DictionaryEntry.swift`), `MAX_SCALARS` (`lf-text/src/dictionary.rs:21`) |
| Strength range | 0.25 to 8, inclusive | `DictionaryValidation.minStrength`/`maxStrength` (`DictionaryEntry.swift`), `MIN_STRENGTH`/`MAX_STRENGTH` (`lf-text/src/dictionary.rs:22-23`) |
| Default strength | 1 | `DictionaryValidation.defaultStrength` (`DictionaryEntry.swift`), `DEFAULT_STRENGTH` (`lf-text/src/dictionary.rs:24`) |
| Strength presets | 0.5, 1, 1.41, 2, 2.83, 4, 5.66, 8 | `DictionaryValidation.presets` (`DictionaryEntry.swift`), `STRENGTH_PRESETS` (`lf-text/src/dictionary.rs:26`) |
| Entry capacity | 1000 | `DictionaryValidation.capacity` (`DictionaryEntry.swift`), `MAX_ENTRIES` (`lf-text/src/dictionary.rs:15`) |
| Ignore-list capacity | 1000 keys | `DictionaryValidation.ignoreCapacity` (`DictionaryEntry.swift`), `MAX_IGNORED` (`lf-text/src/dictionary.rs:17`) |
| Stored key | ≤ 300 scalars, ≤ 8 fields split at U+0020, empty fields included (pin P6) | `DictionaryKey.isValid` (`DictionaryText.swift`), `valid_key` and `MAX_KEY_SCALARS` (`lf-text/src/dictionary.rs:204-217`) |

Dictionary rules:

- Saving an entry replaces the entry with the same key in place. Otherwise
  the entry is appended, unless the dictionary already holds 1000 entries
  (`full`). If the key is invalid under pin P6, nothing changes.
  (`CustomDictionary.upsert`, `DictionaryEntry.swift`; `Store::add`,
  `lf-daemon/src/dictionary.rs:149-161`)
- The ignore list holds identity keys that are never suggested. Adding a
  key that is already present is a no-op. The list fills at 1000 keys, and
  a key invalid under pin P6 is refused. (`CustomDictionary.addIgnore`,
  `DictionaryEntry.swift`; `Store::ignore`,
  `lf-daemon/src/dictionary.rs:177-188`)
- Errors never quote the entry. (`DictionaryChangeError.message`,
  `DictionaryEditor.swift`; `DictionaryEntryError.message`,
  `DictionaryEntry.swift`; the `EntryError` `Display` impl,
  `lf-text/src/dictionary.rs:84-94`)

### §1.2 Bias graph and scoring

Surfaces and phrases:

- An entry is boosted as up to four **surfaces**, without repeats and in
  this order: the text, `fold(text)`, `upper1(text)`, and each U+0020-separated
  word through `upper1`. (`BiasGraph.surfaces`, `BiasGraph.swift`;
  `surfaces`, `lf-text/src/dictionary.rs:251-262`)
- Each surface is encoded (§1.3). A sequence that is empty or contains
  `<unk>` is skipped. When two surfaces give the same token sequence, the
  largest strength is kept. (`BiasGraph.phrases`, `BiasGraph.swift`;
  `phrases`, `lf-text/src/dictionary.rs:264-280`; vectors `phrases`)

The graph is an Aho-Corasick trie over token ids, with failure links.
(`BiasGraph`, `BiasGraph.swift`; the `lf_cpu::bias` module doc,
`linux/crates/lf-cpu/src/bias.rs:2-21`) Each phrase must be non-empty,
with every id below the non-blank vocabulary size (1024), and a finite
positive strength. Otherwise construction fails. (`BiasGraph.init`,
`BiasGraph.swift`; `BiasGraph::new`, `lf-cpu/src/bias.rs:48-65`)

Scores:

- `σ(n)` is the largest strength among the phrases whose path passes
  through or ends at state `n`. Entries that share a token prefix are
  therefore coupled through `σ`.
- `own(n) = σ(n) · (C + D · ln d(n))`, where `d(n) ≥ 1` is the depth of
  `n`. The root has `own(root) = 0`.
- `score(n) = max(own(n), score(fail(n)))`, computed breadth-first, so the
  result does not depend on phrase order.
- A non-blank token `t` taken from state `s` earns
  `α · score(goto(s, t))`, or 0 when `goto` returns to the root. The bonus
  is computed in f64 and stored as f32. A blank earns nothing and leaves
  the state unchanged.

(`BiasGraph.init` and `BiasGraph.step`, `BiasGraph.swift`; the
`lf_cpu::bias` module doc, `lf-cpu/src/bias.rs:8-22`; vectors `graph`)

| Constant | Value | Source |
|---|---|---|
| α (overall weight) | 1.414 | `BiasGraph.alpha` (`BiasGraph.swift`), `ALPHA` (`lf-cpu/src/bias.rs:26`), vectors `constants.alpha` |
| C (context score) | 1.0 | `BiasGraph.contextScore` (`BiasGraph.swift`), `CONTEXT_SCORE` (`lf-cpu/src/bias.rs:28`), vectors `constants.context_score` |
| D (depth scaling) | 3.0 | `BiasGraph.depthScaling` (`BiasGraph.swift`), `DEPTH_SCALING` (`lf-cpu/src/bias.rs:30`), vectors `constants.depth_scaling` |
| Blank row | 1024 | `SpeechCore.blank` (`Sources/SpeechEngine/SpeechCore.swift`), vectors `constants.blank` |

Worked example (vector G1): one phrase `[1, 2, 3]` at strength 1. The three
bonuses are `1.414 · (1 + 3 ln 1) = 1.414`, `1.414 · (1 + 3 ln 2) ≈ 4.3543`
and `1.414 · (1 + 3 ln 3) ≈ 6.0743`.

**Decision rule.** Take the argmax over rows 0…1024 (1024 is blank) of
`f64(logit) + f64(bonus)`, with blank's bonus 0. The first maximum wins.
(`BiasGraph.biasedArgmax`, `BiasGraph.swift`; `token_decision`,
`linux/crates/lf-cpu/src/decoder.rs:995-1009`; vectors `decision`)

A dictionary with no entries, or none whose surfaces encode, has no graph.
Decoding then takes the unbiased path. (`BiasGraph.build`,
`BiasGraph.swift`; `SpeechEngine.work(for:model:)` and `BiasGraphCache`,
`Sources/SpeechEngine/SpeechEngine.swift`)

### §1.3 BPE encoding

The vocabulary has 1024 pieces. A piece's id is its merge rank, and lower
ids merge first. Id 0 is `<unk>`, which a merge never produces. Empty
pieces are ignored, and a repeated piece keeps its lowest id.
(`BPEEncoder.init(pieces:)`, `Sources/DictionaryKit/BPEEncoder.swift`;
`Tokenizer::from_pieces`, `linux/crates/lf-text/src/tokenizer.rs:84-89`;
vectors `vocab`)

- Sorello reads `vocabulary.json` from the model bundle, shaped
  `{"0": piece, …, "1023": piece}`. It must be at most 1 MiB and have
  exactly 1024 keys. (`BPEEncoder.init(vocabularyFile:)`,
  `BPEEncoder.swift`)
- Linux reads `tokenizer.vocab`. After `<unk>`, scores must fall strictly
  with the id, so the id order is SentencePiece's merge order.
  (`Tokenizer::from_vocab_file`, `tokenizer.rs:63-81`)

To encode text:

1. Prefix the text with U+2581, and replace each U+0020 (only that
   character) with U+2581.
2. Make one symbol per scalar.
3. Repeatedly merge the adjacent pair whose concatenation is the piece with
   the lowest id; on ties, take the leftmost pair.
4. Map each symbol to its id. A maximal run of symbols that are not pieces
   becomes one `<unk>` (pin P4).

No other normalization is applied. Empty text encodes as U+2581 alone
(pin P7). (`BPEEncoder.encode`, `BPEEncoder.swift`;
`Tokenizer::encode`, `tokenizer.rs:130-206`; vectors `encode`;
`EntryTests.encoderHandCases`)

"Encodes without `<unk>`" means the result is non-empty and contains no id 0.
(`BPEEncoder.encodesWithoutUnknown`, `BPEEncoder.swift`; `encodable`,
`lf-text/src/dictionary.rs:197-202`)

### §1.4 Casing restoration

Casing restoration runs on the raw transcript before post-processing
(macros, formatting, Return). It runs on every dictation on every platform.
(`CasingRestorer`, `CasingRestorer.swift`;
`SpeechEngine.finishWork`, `Sources/SpeechEngine/SpeechEngine.swift`;
the worker's `run`, `linux/crates/lf-daemon/src/worker.rs:427-429`)

Sorello also restores casing on every verification re-decode, with the
same entries the decode used (`SpeechEngine.suggestCorrection`). Linux compares the re-decode's raw
text (`AsrRecognizer::redecode`,
`linux/crates/lf-daemon/src/recognizer.rs:114-132`). Restoration keeps the
fold of the text unchanged and norms fold case, so this does not change
acceptance (§1.6.4) (inferred).

- Only entries containing a scalar that folding changes take part.
  Lowercase-only entries are inert.
- Candidate entries are ordered longest first by scalar count, then by entry
  text in scalar order.
- The scan runs left to right. A match can start only at a position that
  begins the transcript or follows a non-word character. The first entry
  matches if its fold equals the folds of a run of transcript scalars
  starting there; each transcript scalar's fold is consumed whole. The run
  must end the transcript or be followed by a non-word character. The run
  is replaced by the entry text, and the scan continues after it without
  rescanning the replacement.

(`CasingRestorer.apply`, `Sources/DictionaryKit/CasingRestorer.swift`;
`apply_casing`, `linux/crates/lf-dictation/src/correction.rs:33-81`;
vectors `casing`; `GraphTests.casingHandCases`)

### §1.5 Correction candidates and alignment

The inputs are the typed text (what Sorello inserted), the edited text
(the user's correction), the dictionary, the ignore list and the
vocabulary. The output is a list of candidates in text order.
(`CorrectionCandidates.find`,
`Sources/DictionaryKit/CorrectionCandidates.swift`;
`correction_candidates`, `linux/crates/lf-dictation/src/correction.rs:227-287`;
vectors `candidates`)

**§1.5.1 Bounds.** If either side has more than 4096 UTF-8 bytes or more
than 200 words, there are no candidates. (`CorrectionCandidates.maxBytes`,
`maxWords` and `withinBounds`, `CorrectionCandidates.swift`;
`MAX_CORRECTION_BYTES` and `MAX_CORRECTION_WORDS`,
`correction.rs:22-25,237-241`)

**§1.5.2 Words.** Each side is split with `words()`. Every word keeps its
split index. Words whose norm is empty are dropped, and the others keep
their original index. (`DictionaryWord.split`,
`CorrectionCandidates.swift`; `tokenize`, `correction.rs:107-127`)

**§1.5.3 Alignment.** A word-level Levenshtein alignment of the norms, with
unit costs and the pinned backtrack order (pin P2).
(`WordAlignment.align`, `CorrectionCandidates.swift`; `align`,
`correction.rs:132-196`)

**§1.5.4 Rewrite check.** Let `longest` be the word count of the longer side
(after §1.5.2) and `edits` the number of non-match alignment operations
(substitutions, deletions and insertions). If `longest ≥ 5` and
`2 · edits > longest`, there are no candidates. For example, `a b c d e` to
`b c x y e` has 3 edits against `longest` 5, so it is rejected. (in
`CorrectionCandidates.find`, `CorrectionCandidates.swift`;
`REWRITE_MIN_WORDS`, `correction.rs:26-27,242-254`)

**§1.5.5 Blocks.** A block is a maximal run of alignment operations that are
substitutions, deletions, insertions, or norm matches whose edge-stripped
surfaces differ (pin P1). (`inBlock` in `CorrectionCandidates.find`,
`CorrectionCandidates.swift`; `is_edit` in `correction_candidates`,
`correction.rs:256-287`)

**§1.5.6 Qualifying a block.** A block becomes a candidate only if all of
these hold:

- Each side has 1 to 3 words.
- The surface is the edited side's words joined by U+0020, with edge
  punctuation stripped from both ends. It passes §1.1 validation at
  strength 1.
- Its key is not already in the dictionary or the ignore list.

The candidate's kind is **casing** when the two sides have equal norms.
Such a block qualifies only if the surface has an uppercase scalar after
its first (pins P1 and P5). Every other qualifying block is a **replace**
candidate.

Each candidate records `before_range`, the half-open range of the typed
words' split indices, and `before_words`, the norms of those words.
(`CorrectionCandidates.candidate`, `CorrectionCandidates.swift`;
`qualify`, `correction.rs:289-326`; `CorrectionTests.candidateHandCases`)

### §1.6 Verify decision, strength ladder and budgets

A casing candidate needs no audio. It is accepted at strength 1 and never
decoded. A replace candidate is accepted only if re-decoding the retained
audio, with the dictionary snapshot plus the candidate, recovers the
candidate exactly where the user corrected it.
(`VerifyDecision`, `Sources/DictionaryKit/VerifyDecision.swift`;
`Expected` and `verify_decision`,
`linux/crates/lf-dictation/src/correction.rs:328-463`; vectors `verify`)

**§1.6.1 Base.** `B` is the norms of the dictation's transcript after
casing restoration and before post-processing.
(`VerifyDecision.accepts`, `VerifyDecision.swift`;
`SpeechEngine.finishWork`;
`Retained::raw`, `linux/crates/lf-daemon/src/worker.rs:33-43`)

**§1.6.2 Mapping.** Align the norms of the typed text to `B` (§1.5.3). Every
word of the block must align as an exact match, and the matched words must
form one contiguous run `B[i..<j]` equal to `before_words`. If they do not,
the candidate cannot be attempted (pin P8). (`VerifyDecision.mapBlock`,
`VerifyDecision.swift`; `Expected::new`, `correction.rs:351-393`)

**§1.6.3 Expected transcript.** `E = B[..<i] + x + B[j...]`, where `x` is the
norms of the candidate surface. (`VerifyDecision.accepts`,
`VerifyDecision.swift`; `Expected` and `Expected::new`,
`correction.rs:328-346,383-392`)

**§1.6.4 Acceptance.** For one re-decode `N` (casing-restored in Swift,
raw on Linux; see §1.4),
align `norms(N)` to `E` and set `lo = max(0, i − 2)` and
`hi = min(|E|, i + |x| + 2)`. `N` is accepted when both hold:

- (a) No substitution or insertion touches `E[lo..<hi]`, and no `N`-only
  word sits before `E[p]` for any `lo ≤ p ≤ hi` (pin P3).
- (b) Every other edit block has `before_words` as its `E` side and `x` as
  its `N` side; that is, the same correction recovered elsewhere.

(`VerifyDecision.accepts`, `VerifyDecision.swift`;
`VERIFY_CONTEXT_WORDS` and `Expected::accepts`,
`correction.rs:30-31,396-458`; `CorrectionTests.verifyHandCases`)

**§1.6.5 Strength ladder.** Strengths are tried in this order: 1.0, 1.41,
2.0, 2.83, 4.0, 5.66, 8.0. The first accepted strength becomes the
suggestion's strength. (`VerifyDecision.strengths`,
`VerifyDecision.swift`; `VERIFY_STRENGTHS`, `worker.rs:28-29`; vectors
`constants.verify_strengths`) iOS "Find strength" reuses the ladder with
its own acceptance rule (`StrengthProbe.accepts` and `StrengthProbe.find`,
`StrengthProbe.swift`; see the platform differences).

**§1.6.6 Budgets.**

- At most 3 candidates are attempted, in text order. Candidates that cannot
  be attempted are dropped first and do not count toward the cap (pin P8).
- Each candidate gets at most 7 decodes, one per strength.
- The whole check gets 3 s of elapsed time from its start.
- The check stops when cancelled.
- The budget and cancellation are checked before every decode, after every
  decode (before its result counts), and before a casing candidate is
  accepted.
- A decode error ends the check with no suggestion.

(`DictionarySuggestionFinder.maxCandidates`, `maxSeconds` and `find`,
`VerifyDecision.swift`; `MAX_VERIFY_CANDIDATES`, `VERIFY_BUDGET`
and `verify_with_clock`, `worker.rs:24-31,308-386`;
`CorrectionTests.suggestionBudgets`; `CorrectionTests.verificationOrder`)

The shared vectors test single decisions. Each platform tests ordering and
budgets with a mocked clock (vectors `verify` description). Two parts of
verification are Sorello's only (§3.4 and the platform differences):

- When the dictionary is full, nothing is verified.
  (`DictionarySuggestionFinder.find`, `VerifyDecision.swift`)
- Within one dictation, a candidate that failed at every strength is
  remembered and skipped. (`ExhaustedCandidates`,
  `VerifyDecision.swift`)

### §1.7 Shared vectors

`Tests/Vectors/dictionary-vectors.json` (version 1), the same file as the
Linux implementation's `linux/testdata/dictionary-vectors.json`, has these
sections:
`constants`, `vocab`, `encode`, `validation`, `phrases`, `graph`,
`decision`, `casing`, `candidates`, `verify` and `keys`. The file's
`description` array defines each section's exact semantics. All text in it
is invented.

- Consumers: `VectorTests` in `Tests/DictionaryKitTests/VectorTests.swift`,
  `linux/crates/lf-asr/tests/dictionary_vectors.rs` and
  `linux/crates/lf-dictation/tests/dictionary_vectors.rs`.
- Validation error names are the raw values of `DictionaryEntryError`
  (`DictionaryEntry.swift`).
- Graph bonuses must match within 1 ULP of f32. Expected values are exact
  f64 math cast to f32 (vectors `graph` description).
- Because both suites read this one file, a change to any §1 rule needs the
  vectors and both implementations changed together (inferred).

## §2 Linux daemon

### §2.1 Storage

- The dictionary is stored in `$XDG_DATA_HOME/localflow/dictionary.json`,
  shaped `{"version":1,"entries":[{"text":…,"strength":…}],"ignore":[…]}`.
- A missing data directory is created with mode 0700. An existing one must
  be a directory owned by the effective uid, with no group or other access,
  so stricter modes are accepted. (`ensure_private_dir` and
  `check_private_dir`, `linux/crates/lf-daemon/src/paths.rs:64-101`)
- The file is opened with `O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC`. It must be
  a regular file owned by the effective uid, with mode exactly 0600, and
  at most 2 MiB (`MAX_FILE_BYTES`). That is above the largest file a full
  dictionary serializes to (1000 entries of 100 scalars and 1000 ignored
  keys of 300 scalars, at most 4 bytes each, come to about 1.7 MiB with
  the pretty-printed framing), so whatever was saved loads again
  (`a_full_dictionary_reloads`). A missing file is an empty dictionary.
- Loading requires version 1 and at most 1000 entries. Each entry must be
  valid under §1.1 and stored already normalized, and no two entries may
  share a key. The ignore list may hold at most 1000 keys, each valid under
  pin P6, without repeats. Any other content is an error that quotes no
  content.
- A change is written to a 0600 temporary file, synced, renamed over the
  file, and the directory is synced. Only then is the change published.
  - A failed write changes nothing.
  - If only the directory sync fails, the rename is undone and the change
    is refused (`error storage`). Memory never changes.
  - If the rename cannot be undone, the file on disk may hold the refused
    change. The store is marked broken, the daemon replies `error storage`
    and stops, and its next start loads that file.

(The `lf_daemon::dictionary` module doc and `MAX_FILE_BYTES`,
`linux/crates/lf-daemon/src/dictionary.rs:2-23,38-40`; `Store::recover` and
`Store::is_broken`, `dictionary.rs:230-280`; test
`a_failed_directory_sync_is_undone_and_refused`, `dictionary.rs:736-780`)

### §2.2 Snapshots

Each published change is a new immutable `Snapshot`, identified by a
revision. A dictation decodes with the snapshot taken when its recording
started: it is transcribed while it is recorded. (`Snapshot`,
`lf-daemon/src/dictionary.rs:61-67`; `Controller::start_recording`,
`lf-daemon/src/controller.rs:1218-1247`; `Controller::finish`,
`controller.rs:1533-1555`)

Agent-link project words are boosted together with the dictionary, and the
dictionary's strength wins on overlap. They are not dictionary changes.
(the `lf_daemon::controller` module doc and `Controller::finish`,
`controller.rs:81-85,1239-1242`)

### §2.3 Decoding

Casing is restored on the raw transcript before `lf_dictation::process`
(§1.4; the worker's `finish`, `lf-daemon/src/worker.rs:787-791`). The biased
decision rule is §1.2's (`token_decision`, `lf-cpu/src/decoder.rs:995-1009`).

### §2.4 Correction session

- At most one session exists: the last typed dictation, held in memory
  only. It never reaches logs, `watch`, history or `Debug` output.
  (`CorrectionSession`, `controller.rs:131-138`; `Retained`,
  `worker.rs:33-43`)
- A dictation is kept only if all of these hold (`eligible` in the
  worker's `finish`, `worker.rs:792-799`; `Controller::finish`,
  `controller.rs:1533-1555`):
  - it is not a macro;
  - it does not press Return;
  - its output is non-empty, at most 4096 bytes and free of control
    characters;
  - the dictionary revision has not changed since its recording started.
- The session lasts 120 s (`CORRECTION_WINDOW`). It is discarded earlier
  by a new recording, a cancel, or any published dictionary change.
  Discarding cancels its check, or marks the check stale.
  (`CORRECTION_WINDOW`, `discard_correction`, `expire_correction`,
  `apply_change`, `start_recording` and `cancel`,
  `controller.rs:127-129,419-443,595-605,1017-1025,1130-1131`)
- The retained audio is the encoder projection of each of the dictation's
  15 s windows, at most 16 MiB together (`MAX_RETAINED_BYTES`). A longer
  dictation is still typed but not kept. (`MAX_RETAINED_BYTES` and
  `Windows::transcribe`, `worker.rs:36-38,598-640`)
- `correct-submit` computes every candidate. The worker drops the ones it
  cannot attempt, then takes at most three (pin P8). A newer submit cancels
  a pending check. (`submit_correction`, `controller.rs:501-553`)

### §2.5 Dictionary and correction commands

The text commands are `correct-begin`, `correct-submit`, `correct-result`,
`dict-add`, `dict-remove`, `dict-ignore` and `dict-unignore`.
(the `lf_daemon::protocol` module doc, `linux/crates/lf-daemon/src/protocol.rs:43-72`)

- Text travels percent-encoded. Strengths are `<dec>` values within
  [0.25, 8], carried internally as milli-units (`format_dec`, `parse_dec`
  and `STRENGTH_RANGE`, `protocol.rs:830-862`).
- Error codes include `invalid-entry`, `full`, `not-found`, `storage`,
  `stale` and `too-long`.

`localflowctl correct` drives the user flow through a picker (rofi or wofi;
fuzzel and tofi can show only the second prompt):

- It works within two minutes of a dictation.
- The user edits the dictation's text there; the text already typed into
  the other app is never changed.
- A second prompt offers "Add", "Not now" or "Don't suggest" for one
  verified suggestion.

(`linux/README.md:199-222`, "Teaching it from a correction")

## §3 Sorello (macOS)

The Swift implementation is Sorello's: `DictionaryKit` holds the dictionary,
its file, the correction decisions and the correction watch, and
`SpeechEngine` holds decoding and the retained audio. ARCHITECTURE.md is the
contract for how the app wires them; where it and this section disagree
about where the dictionary is stored or what happens to an unreadable file,
ARCHITECTURE.md section 7 wins.

### §3.1 Decoder hook

Biased greedy TDT decoding uses the same loop and limits as the unbiased
decode, including at most 10 symbols per frame. The differences:

- The token is §1.2's biased argmax over the exposed logits.
- The bias state follows non-blank emissions, and a blank keeps it.

(`SpeechCore.decode(length:bias:predict:joint:check:)`,
`Sources/SpeechEngine/SpeechCore.swift`; `CoreTests.biasedDecode`)

Each transcription decodes with one immutable `DictionarySnapshot`
(entries, revision and the app of §3.6), taken when its stream opens. The
graph is built on the engine's executor and cached by revision and app
(`BiasGraphCache`, §3.6). (`DictionaryStore.snapshot(for:)`,
`DictionaryStore.swift`; `SpeechEngine.work(for:model:)`,
`Sources/SpeechEngine/SpeechEngine.swift`; `EngineTests.dictionarySnapshotIsTakenAtOpen`)

### §3.2 Storage

The dictionary is one file, `dictionary.json`, in the app's directory under
Application Support, which only the user can read
(`DictionaryStore`, `DictionaryFile`, `DictionaryStore.swift` and
`DictionaryFile.swift`):

```
{"apps":[{"id":…,"name":…}],
 "entries":[{"apps":[…],"strength":…,"text":…}],
 "ignore":[…],
 "version":1}
```

It is JSON with sorted keys. An entry's `apps` is absent when it applies
everywhere, and sorted otherwise (§3.6). Loading accepts the file only up to
16 MiB (`DictionaryFile.maxBytes`). Saving does not check the size; the cap
is above the largest file a full dictionary encodes to (1000 entries of 100
four-byte scalars, each limited to 32 apps with 155-character identifiers,
1000 ignored keys of 300 four-byte scalars and 32 apps with 100-scalar
names: about 7 MiB), so whatever was saved loads again
(`StoreTests.fullFileLoadsAgain`).

Loading validates everything:

- version 1, all four keys present, at most 1000 entries, 1000 ignored keys
  and 32 apps;
- every entry valid under §1.1 and stored already normalized, with no
  duplicate keys;
- every ignore key valid under pin P6 and stored exactly as saved, with no
  repeats;
- the apps and each entry's apps as §3.6 says.

A missing file is an empty dictionary. A file that is there but cannot be
opened (a permission problem, not damage) is left alone: it is not moved,
deleted or written over, the dictionary is empty meanwhile, and each change
tries to open it again first (`StoreTests.unopenableFileIsLeftAlone`). A
file that opens but fails any of these is moved aside, beside it, as
`dictionary-unreadable-<seconds since 1970>.json` (never over another
file), and replaced with an empty dictionary, so the app always launches.
If it cannot be moved, it is left in place and the store refuses every
change until the next launch, so nothing is ever saved over it.
(`DictionaryStore.init`; `StoreTests.unreadableFileIsMovedAside` and
`StoreTests.unmovableFileIsLeftAlone`)

A change is written to a new file readable only by the user, flushed, and
renamed over `dictionary.json`; only then is it published. A failed write
refuses the change (`notSaved`) and changes nothing in memory.
(`DictionaryStore.writeAtomically`; `StoreTests.refusedChangesChangeNothing`)

Turning correction suggestions on or off is an app setting, on by default.

### §3.3 Editing

Every change goes through `DictionaryStore`, which validates it with the
editor (`ScopedDictionaryEditor` over `DictionaryEditor`), writes it, then
publishes it with a new revision. An edit that changes nothing is neither
written nor published. The app, after a published change, stops all
correction work and withdraws any visible suggestion.

- Without a vocabulary nothing can be edited.
- Errors are content-free (`DictionaryChangeError.message`).
- Settings shows inline validation once something is typed.

(`DictionaryStore` and `DictionaryEditor.swift`;
`StoreTests.editsNeedVocabulary`)

### §3.4 Retained correction sessions

A dictation's audio is retained only if its stream asked for it
(`SpeechStreamOptions.retainForCorrection`). The app asks when suggestions
are on and Accessibility is trusted, when the dictation starts.

- **What is kept.** The per-chunk encoder projections (frames × 640 f32),
  the snapshot, and the base text (§1.6.1).
  (`SpeechEngine.retain` and `SpeechEngine.transcribe(_:work:model:check:)`)
- **Size.** Retention is dropped once the projections exceed 16 MiB; the
  dictation is still transcribed. A dictation with no text keeps nothing.
- **One session.** The engine holds at most one: the newest recording that
  asked. Opening a newer recording voids the older one at once, and a late
  result from an older recording never replaces a newer one's. A Run Log
  retry is not a recording and releases nothing.
- **Lifetime.** 90 s, enforced by deadline and by a scheduled expiry that
  never drops a newer session.

(`SpeechEngine` and `RetentionGate`, `Sources/SpeechEngine/SpeechEngine.swift`;
`EngineTests.retainedAudioFindsTheSuggestion`,
`EngineTests.aNewerRecordingReleasesTheOlderOne`,
`EngineTests.releasesAndDiscards`, `EngineTests.keptAudioExpires`,
`EngineTests.retentionHasLimits`)

A finished dictation is watched only if all of these hold
(`CorrectionEligibility.isEligible`, `SuggestionPresentation.swift`;
`CorrectionTests.eligibilityWindow`; ARCHITECTURE.md section 4,
"Insertion"):

- suggestions are on;
- the speech result carries a correction id (the audio was retained);
- the dictionary revision is the one the audio was decoded with;
- nothing was cancelled since its text was composed;
- it is not a macro and does not press Return;
- its output is non-empty and at most 4096 bytes;
- the inserter reported it `inserted` and read the destination field.

Otherwise its audio is released.

The session is released when:

- a suggestion is claimed;
- the watch's last check finishes (`isLast`);
- the watch ends or never starts (`releaseCorrection`);
- a new recording starts;
- the dictation is cancelled after its result was made;
- suggestions are turned off, the dictionary changes, or the Run Log is
  cleared (`discardCorrection`);
- the app quits.

Each release takes effect at once, from any thread; the memory is freed on
the engine's executor right after. (`SpeechEngine.suggestCorrection`,
`discardCorrection` and `releaseCorrection`)

A watch can be anchored and still fail to begin, for example because the
paste never ends at the caret within the start attempts. The app then
releases the audio, or it stays until the 90 s expiry or one of the events
above.

### §3.5 Correction watcher and suggestion presentation

The watcher is high risk: it reads another app's text field through
Accessibility. It reads only through `TextFieldReading`
(`TextFieldReading.swift`), which MacPlatform implements. Text it reads
stays in the session record and local variables, is cleared when the watch
finishes, and is never logged, persisted or transmitted.
(`CorrectionWatchSession.swift` and `CorrectionWatcher.swift`)

The watcher never looks for the focused field itself. The inserter reads
the destination field and its selection before it pastes (ARCHITECTURE.md
section 4, "Insertion"), within its own 0.3 s deadline; the app turns that
reading into an anchor (`CorrectionWatcher.anchor`), and the watch follows
the paste from there.

| Watcher constant | Value | Source |
|---|---|---|
| Start attempts after the paste | 0.15, 0.4, 1 and 2 s | `CorrectionWatcher.startAttempts` and `start` |
| Poll interval | 0.5 s | `CorrectionWatcher.pollInterval` |
| Longest watch | 60 s | `CorrectionWatchSession.maxDuration` |
| Quiet period before an edit is checked | 1.5 s | `CorrectionWatchSession.quietPeriod` |
| Checks per paste (the last ends the watch) | 3 | `CorrectionWatchSession.maxChecks` |
| Longest paste watched | 4097 UTF-16 units (4096 bytes plus the trailing space) | `CorrectionWatchSession.maxPastedUnits` |
| Context kept on each side | 40 units | `CorrectionWatchSession.contextUnits` |
| Span growth or shrinkage tolerated | 200 units | `CorrectionWatchSession.maxGrowth` |
| Read window at begin / per poll | 4200 / 4600 units | `CorrectionWatchSession.beginWindowLimit`/`pollWindowLimit` |

**Watching**

- Only another app's focused, editable text area, text field or combo box
  is watched, never a secure one. Whether two readings name the same field
  is the reader's answer (`TextFieldReading.check`).
- Only bounded reads are made: the character count, the selection, and the
  text of a range. A whole value is never requested.
- At begin, the pasted text must end exactly at an empty selection. A
  browser can update the field's text a moment after the paste, so a start
  that finds the old text or a failed read is tried again at the next
  attempt; any other failure, or a cancel, ends it. A retry must find the
  paste where the selection started just before it (read by the inserter),
  so a caret moved meanwhile cannot bind it to an older copy of the same
  text; if that selection could not be read, there is no retry.
  (`CorrectionWatcher.start`, `CorrectionDiscardReason.allowsStartRetry`,
  `CorrectionAnchor.insertionPoint`;
  `WatcherTests.startRetriesWhileTheFieldCatchesUp`)
- A no-break space (U+00A0) read from the field, or in the paste, counts as
  a space. Browsers show trailing and repeated spaces that way and switch
  them back as the text changes; a switch alone is not an edit.
  (`WatchSessionTests.noBreakSpacesCountAsSpaces`)
- Each poll locates the span from its recorded context. The before-context
  must sit right before the span (or the span starts the document). The
  after-context must occur exactly once (or the span runs to the end).
  (`CorrectionWatchSession.begin` and `locate`; `WatchSessionTests.spanTracking`)
- Before every read, three things are checked: permission, the same process
  and element, and a non-secure field. Cancellation is checked before and
  after that safety check. Past the 60 s window, no text is read.
  (`CorrectionWatchSession.poll`, `guardedRead` and `safetyCheck`;
  `WatchSessionTests.deadlineStopsReads`)
- An edit unchanged for the quiet period is reported for checking, and the
  watch continues. (`WatchSessionTests.keepsWatchingAfterACheck`)

**Ending a watch**

- When a stop does not forbid captured text, an unchecked edit already read
  is finalized from memory.
- Cancel, lost permission and a secure field discard everything and abandon
  edits already reported: the watch is made stale on the watcher's own
  queue, so no result for it can be used, and the app is told to stop.
  (`CorrectionDiscardReason.forbidsCapturedText`;
  `WatchSessionTests.watchEndsWithCapturedEdit`;
  `WatcherTests.forbiddenStopAbandonsReportedEdits`)

**Checks**

- Each reported edit starts a check that cancels any older one; starting a
  recording, finishing a dictation and `discardCorrection` cancel it too.
- Nothing is checked unless a suggestion may be presented, Accessibility is
  trusted, and the dictionary has room.
- A result is used only if its watch can be claimed atomically. Claiming
  ends the watch, so there is one suggestion per dictation.

(`SpeechEngine.beginCorrectionCheck` and `suggestCorrection`;
`CorrectionWatcher.claim`; `WatcherTests.claimingAWatch`;
`EngineTests.correctionChecksKeepTheirOrder`)

**Presentation**

- A suggestion may show only when suggestions are on, the dictionary is
  editable, and no dictation is under way. A dictation counts as under way
  while recording or transcribing, while a shortcut start is pending, and
  during a shortcut session. (`CorrectionSuggestionTiming.mayPresent`)
- The pill holds the only copy of a suggestion, bound to an id.
- A withdrawal is a recording press or start, a dictionary edit, or turning
  the setting off. A presentation requested before a withdrawal never
  shows.
- After 12 s a suggestion resolves as "Not now". However it leaves the
  screen, the word is cleared.
  (`SuggestionPresentationGate` and its `lifetime`,
  `SuggestionPresentation.swift`; `CorrectionTests.suggestionGate`;
  `CorrectionTests.suggestionWithdrawal`)
- The actions are:
  - **Add:** saves the word at the verified strength, through §3.3. When the
    dictation had an app, it is **Add to <App>**, beside **Add everywhere**
    (§3.6).
  - **Don't suggest:** adds the key to the ignore list.
  - **Not now:** does nothing.

### §3.6 App-specific words

A word can be limited to apps, so it is boosted only when dictating into
them. A word with no apps applies everywhere. iOS and Linux have no app
limits, and §1 is unchanged.

**Apps**

- An app is a bundle identifier and the last name seen for it. A bundle
  identifier is 1 to 155 ASCII letters, digits, `.` and `-`. A name is
  trimmed, has its control characters removed and is cut to 100 scalars; an
  empty name falls back to the bundle identifier.
- At most 32 apps are known (`appsFull`). An app stays known, with its
  words, after it is deleted from the Mac, under its last name.
- An app is added from Settings (a running app, or one chosen in
  /Applications) or by accepting "Add to <App>". Adding a known app updates
  its name.

**Words**

- Each entry has a set of app bundle identifiers; empty means everywhere.
  Every app in a set is known (`unknownApp` otherwise), and the sets live
  beside the entries, keyed by identity key.
- The 1000-entry capacity (§1.1) counts every entry, whatever its apps. The
  ignore list stays global.
- Saving an entry sets its apps. Editing an entry's text keeps its apps
  under the new key. Removing an entry removes its apps.
- Removing an app removes it from every set. An entry whose only app it was
  is removed too; it never becomes global.

**Which words a dictation uses**

- The app is the frontmost app when the recording begins, unless it is
  Sorello itself or has no valid bundle identifier; then there is none.
  Switching apps during the recording changes nothing.
- The snapshot holds the entries that apply everywhere plus those limited to
  that app, in entry order. It records the app only when that app has
  limited words, so every other app shares the global graph.
- The graph cache holds up to 4 graphs for the current revision, keyed by
  revision and app; a new revision drops the older graphs.
- A retried Run Log entry uses the words that apply everywhere.

**Suggestions**

- Correction checks run against the dictation's snapshot, so a word limited
  to another app can still be suggested. A suggestion is offered only if the
  word does not already apply in the dictation's app and is not ignored, and
  only while the whole dictionary has room.
- With an app, the actions are **Add to <App>**, **Add everywhere**, **Not
  now** and **Don't suggest**. Without one, they are **Add**, which adds
  everywhere, **Not now** and **Don't suggest**.
- Add to <App> registers the app. For a new word it saves the word limited
  to that app. For an existing word it keeps the word's text, raises its
  strength to the verified one if that is higher, and adds the app unless
  the word already applies everywhere.
- Add everywhere saves a new word everywhere, or makes an existing word
  apply everywhere, with the same strength rule.

**Storage**

The apps and each entry's apps are part of `dictionary.json` (§3.2). The
file's `apps` lists the known apps in the order they became known; an
entry's `apps` lists its bundle identifiers, sorted, and is absent when the
entry applies everywhere. Loading validates:

- at most 32 apps, each stored exactly as normalized, with no repeated
  bundle identifiers;
- each entry's `apps`, when present, non-empty, all known, with no repeats.

Anything else that fails makes the whole file unreadable, as in §3.2.

Edits go through `DictionaryStore`, which follows §3.3 and refuses
everything without a vocabulary. Errors never quote a word or an app.

(`DictionaryApp`, `DictionaryAppScopes`, `ScopedDictionary` and
`ScopedDictionaryEditor`, `DictionaryApps.swift`; `DictionaryFile`;
`BiasGraphCache`, `Sources/SpeechEngine/SpeechEngine.swift`; tests in
`AppScopeTests` and `EngineTests.graphCache`)

## Platform differences

| Aspect | Sorello (macOS) | iOS | Linux |
|---|---|---|---|
| Implementation | Swift, `Sources/DictionaryKit` and `Sources/SpeechEngine` | Swift sharing the same rules (`iOS/ARCHITECTURE.md`, "Custom dictionary") | Rust: `lf-asr`, `lf-cpu`, `lf-dictation`, `lf-daemon` |
| Storage | `dictionary.json` with entries, app limits and the ignore list; an unreadable file is moved aside and replaced (§3.2) | two UserDefaults keys in the host app's UserDefaults, never the App Group | one 0600 file with entries and ignore list (§2.1) |
| Vocabulary file | `vocabulary.json` | `vocabulary.json` | `tokenizer.vocab`, with scores checked (§1.3) |
| How corrections are found | Accessibility watcher on the pasted text (§3.5) | none: entries are added by hand | user-initiated `localflowctl correct` (§2.5) |
| Strength calibration | the strength verified from a correction | "Find strength": one recording, `StrengthProbe.accepts` accepts a decode that has at least one edit block against the unboosted transcript, where every edit block has the word as its new side and replaces at most `maxExtraReplacedWords` (2) extra words (`StrengthProbe.swift`, `CorrectionTests.strengthProbe*`) | the strength verified from a correction |
| Retained audio | projections ≤ 16 MiB, 90 s, the newest recording only (§3.4) | for "Find strength" only: the recorded samples and the encoder output live only while the probe task runs (`StrengthProbeModel.done`, `iOS/App/DictionaryModel.swift:104-122`; Sorello's `SpeechEngine.probeStrength` keeps them only while it runs); the finished result keeps only texts, shown until the sheet closes | projections of the last typed dictation, ≤ 16 MiB, 120 s (§2.4) |
| Candidates that failed at every strength | remembered per dictation (`ExhaustedCandidates`) | not applicable | not remembered (inferred: no such cache in `verify_with_clock`, `worker.rs`) |
| Full dictionary | nothing verified or offered (`DictionarySuggestionFinder.find`) | not applicable | still verified; `dict-add` then fails with `full` (inferred: no capacity check in `submit_correction` or `verify_with_clock`) |
| Phrase order before building the graph | first seen (`BiasGraph.phrases`) | first seen | sorted by token sequence (`phrases`); the graph does not depend on order (vectors `graph`, "G2 reversed") |
| Suggestion UI | a notice on the pill, 12 s, Add (or Add to <App> / Add everywhere) / Not now / Don't suggest | not applicable | picker dialog (rofi, fuzzel, wofi or tofi), Add / Not now / Don't suggest |
| Project words | none | none | agent-link words are boosted and never end a session (§2.2) |
| App-specific words | words limited to apps, chosen by the frontmost app at recording start (§3.6) | none | none |
