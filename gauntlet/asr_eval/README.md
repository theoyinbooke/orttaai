# ASR eval — live-path accuracy and vocabulary biasing

Measures the transcription accuracy of Orttaai's two decode paths against
each other and against a recorded baseline:

- **whole** — `TranscriptionService.transcribe(audioSamples:)`, the single
  whole-utterance decode (the reference standard).
- **live** — the real live-session machinery: `beginLiveTranscriptionSession`,
  incremental `processLiveAudioSnapshot` polling (clips of up to 15 s, aligned to nearby quiet gaps, pause
  commits, speculative tail), then `finalizeLiveTranscription`.

The eval runs the REAL `TranscriptionService` actor inside the app process —
there is no reimplementation of the session logic in the harness. The only
divergence from production is pacing: the growing-snapshot poll loop feeds
250 ms of audio per poll but sleeps `250 ms / SPEEDUP` (default speedup 4), so
a 35 s recording feeds in ~9 s. Commit/pause/speculative behavior depends on
sample counts and audio content, not wall-clock, so the same machinery runs;
only the interleaving is compressed. Speedup is configurable
(`ORTTAAI_ASR_EVAL_SPEEDUP=1` gives true realtime).

## Pipeline

1. `corpus_texts.json` — 92 authored utterances: Yoruba/Igbo proper nouns
   (Olanrewaju, Oyinbooke, …), camelCase identifiers and product names,
   numbers/currency/dates, everyday sentences, 22 long multi-sentence
   passages (29–36 s, with genuine `[[slnc 900]]` pauses so pause commits and
   clip commits both trigger), and 10 adversarial items (mid-utterance
   silence gaps, noise-only tails, deliberate word repetition).
   `bias_vocabulary` (36 terms) doubles as the simulated user dictionary.
2. `build_corpus.py` — synthesizes `corpus/*.wav` (16 kHz mono Float32) with
   macOS `say` across 4 voices (Samantha/Daniel/Karen/Moira — US, GB, AU, IE)
   × 2 rates (170/205 wpm), deterministic assignment; writes
   `corpus/manifest.json`.
3. `OrttaaiTests/Eval/ASREvalRunnerTests.swift` — env-gated XCTest
   (`ORTTAAI_ASR_EVAL=1`, invoked with `TEST_RUNNER_` prefixes) that decodes
   every item through both paths and writes raw decode JSON. The normal unit
   suite skips it.
4. `score.py` — WER (normalized: lowercase, punctuation stripped, hypothesis
   number-words folded toward the digit-form references, currency/ordinal/
   time unification), hard-vocab recall (strict = case-insensitive verbatim
   substring; lenient = additionally space/hyphen-insensitive so a split
   camelCase counts as recognized words), finalize-latency p50/p90, and
   hallucination artifacts (consecutive n-gram repetition loops beyond the
   reference's own repetition, and runs of ≥8 pure-insertion words).

## Running

```bash
python3 gauntlet/asr_eval/build_corpus.py          # once, deterministic
./gauntlet/asr_eval/run_eval.sh /tmp/raw.json      # ~20 min on M4 w/ large-v3
./gauntlet/asr_eval/run_eval.sh /tmp/raw.json ORTTAAI_ASR_EVAL_BIAS=1  # biased
python3 gauntlet/asr_eval/score.py /tmp/raw.json --label final \
    --out gauntlet/asr_eval/results.json --compare gauntlet/asr_eval/baseline.json
```

`baseline.json` was recorded from the pre-change code (git HEAD in a clean
worktree: no context conditioning, no vocabulary biasing — the runner's one
`setVocabularyBias` call stubbed out since the API did not exist yet) and is
the fixed reference for all improvement claims. `results.json` is the latest
scored run including `vs_baseline` deltas and the new-hallucination check.

Prompt budget note: the pinned WhisperKit's `Constants.maxTokenContext` is
224, so its prompt cap is `224/2 - 1 = 111` tokens and anything longer is
suffix-trimmed (dropping the front — exactly where the bias terms sit). The
production budget is therefore 110 total: bias terms fitted first (<= 70),
committed-context tail takes the remainder.

Model: `openai_whisper-large-v3` (the user's active model, already on disk);
preset `balanced` (the user's active preset); language `en`.

## Realistic corpus

The clean corpus is TTS over digital silence with an instant key release, so
it cannot reproduce two things seen in real usage history: ~30% of dictations
longer than ~30-45 s taking 5-9 s to finalize (vs ~1 s), and ~1% ending in a
hallucinated "Thank you." / "you". `build_realistic_corpus.py` re-mixes the
tracked corpus wavs (pure Python, deterministic per-item seeds, no numpy) into
`corpus_realistic/` + `manifest_realistic.json`. The directory is git-ignored:
generate it, never commit it.

| group | what it is |
| --- | --- |
| `noisy-long-01..08` | 45-95 s: concatenated long items, 1.0-3.5 s silence gaps, pink-ish noise floor (RMS 0.004-0.012) over the whole file, 0.5-2.5 s trailing noise (the key-hold gap) |
| `hold-01..12` | 5-25 s speech + 0.3-2.0 s trailing noise at RMS 0.006 / 0.010 / 0.015 (4 each) |
| `soft-last-01..06` | final word attenuated to ~0.02-0.03 RMS (3) or ~0.012 (3); must keep the last word |
| `noise-only-01..06` | empty reference: digital silence, noise-only at RMS 0.003-0.012, two key-press-only clips |
| `quiet-01..04` | whispery speech (~0.025 RMS) |

Reference points: the finalize path trims tails below the 0.005 RMS faint
floor and treats 100 ms frames above 0.02 RMS as speech, so the tail noise
levels straddle both.

```bash
python3 gauntlet/asr_eval/build_realistic_corpus.py
./gauntlet/asr_eval/run_eval.sh /tmp/raw_real.json ORTTAAI_ASR_EVAL_PATHS=live \
  ORTTAAI_ASR_EVAL_MANIFEST=$PWD/gauntlet/asr_eval/corpus_realistic/manifest_realistic.json
python3 gauntlet/asr_eval/score.py /tmp/raw_real.json --label realistic \
  --manifest gauntlet/asr_eval/corpus_realistic/manifest_realistic.json \
  --out /tmp/results_realistic.json [--group noisy-long]
```

The runner records a `finalize_trace` per item (from
`TranscriptionService.finalizeLiveTranscriptionDetailed`): the finalize path
(`reused_speculative`, `tail_decoded`, `tail_empty_no_audio`,
`whole_fallback` + `fallback_reason`, `no_live_session`), tail sample count
and peak/median 100 ms frame RMS, whether the relaxed retry ran, and the
per-stage milliseconds (awaiting commit, awaiting speculative, tail decode,
fallback decode, total). Items whose finalize throws (e.g. pure digital
silence) carry no trace, only the error. `score.py` adds, without changing
existing outputs: WER excluded for empty references with `junk_only_outputs`
counted instead, `trailing_stock_phrase` (hypothesis ends in thank you /
thanks / you / bye / thanks for watching but the reference does not),
`by_group` latency p50/p90/max plus finalize-path distribution per id prefix,
and `soft_last` last-word recall. In production the same traces append to
`finalize-trace.jsonl` in the app's Application Support folder (numbers and
enums only, 1 MB cap, rotated to `finalize-trace.1.jsonl`), so real-usage
finalize paths can be compared to these results.

The `finalize_trace` numbers are telemetry only; finalize behavior is the same
as before the trace was added, so realistic-corpus results are comparable to
`baseline.json`-era builds.

## Full-precision model comparison

`model_comparison.json` records the 2026-07-28 run of the same 92-item
corpus against full-precision `openai_whisper-large-v3` and
`openai_whisper-small.en`.

For the production live path, `small.en` measured 4.76% WER versus 4.36% for
`large-v3`, while median finalization fell from 2,042 ms to 241 ms. That makes
`small.en` a defensible English Quick Start model. It is not a universal
replacement: on the whole-utterance path it measured 9.68% WER and one
long-item hallucination. Capable Macs therefore upgrade to full-precision
`large-v3-turbo`, and normal dictation must continue to use the segmented live
session.

The macOS XCTest host is deliberately inert: unit tests and ASR evaluations
must never register Orttaai's global hotkeys, capture a live microphone, open
application UI, synchronize user data, or inject text.

## Live-path vocabulary prompt on large-v3-turbo (2026-09-28)

The live clip/tail decodes carry no vocabulary prompt. Re-measured on
`openai_whisper-large-v3-v20240930` (turbo, Release, 92-item corpus, bias
prompt of the 36 manifest terms applied to every live clip and tail decode):
live WER 3.85% -> 54.4%, strict hard-vocab recall 43.0% -> 26.6%, median
finalize 907 ms -> 1843 ms, and every long-* and adv-* item degraded (the
prompt is re-applied per clip and the decoder degenerates). Do not re-enable
it; vocabulary recall on the live path comes from the deterministic fuzzy
dictionary pass in the rule-based text processor instead.


## Speech accuracy tuning (2026-10-02)

See [the speech accuracy investigation](../../docs/speech-accuracy-investigation.md)
for the Accuracy preset correction, pause-aligned clipping, protection against
empty speech commits, quiet-ending regression checks, and measured WER/latency
comparisons. The live path still decodes without vocabulary prompt tokens.

## Dictionary pass and Fluid Speech Mini (2026-10-23)

`OrttaaiTests/Eval/DictionaryPassEvalTests.swift` runs saved decodes through the
production `RuleBasedTextProcessor` with the manifest's `bias_vocabulary` as
dictionary entries (only the dictionary stage: exact replacements, then the
fuzzy matcher), writing `<input>_dict.json` for `score.py`:

```bash
env TEST_RUNNER_ORTTAAI_DICT_EVAL_MANIFEST=$PWD/gauntlet/asr_eval/corpus/manifest.json \
  TEST_RUNNER_ORTTAAI_DICT_EVAL_IN=/tmp/raw_a.json,/tmp/raw_b.json \
  xcodebuild -project Orttaai.xcodeproj -scheme Orttaai -destination 'platform=macOS' \
  -only-testing:OrttaaiTests/DictionaryPassEvalTests test
```

`fluidbench/` decodes the corpora with Fluid Speech Mini (FluidAudio), plain and
with CTC Word Boost. Results: `fluid_speech_mini_comparison.json` (models),
`fluid_boost_experiment.json` (Word Boost, Phonon-2) and
`fluid_dictionary_baseline.json` (every engine with the dictionary pass). With the
dictionary, large-v3-turbo measured 2.68% clean / 2.24% realistic WER; Mini with
Word Boost 2.85% / 3.46%, and 2.55% / 3.21% with a simulated real-word guard,
with 84% / 88% hard-vocab recall against turbo's 62% / 68%.

## Real-voice corpus (P0.4)

`record_real_corpus.py` records 50 sentences in the user's own voice (names,
identifiers, numbers, long passages, 10 with another voice in the room, 5 with a
quiet ending) into `corpus_real/` with `manifest_real.json`, in the same schema
and 16 kHz mono Float32 format as the synthetic corpora. `corpus_real/` is
git-ignored: it is the user's voice. Takes are captured by `record_take.swift`
(AVAudioEngine, compiled once into `corpus_real/.bin/`) from the Mac's current
input device; ffmpeg is only used for level checks. Needs microphone access for
the terminal.

```bash
python3 gauntlet/asr_eval/record_real_corpus.py list     # the script
python3 gauntlet/asr_eval/record_real_corpus.py record   # guided, resumable
python3 gauntlet/asr_eval/record_real_corpus.py status
```

Score it like the realistic corpus, passing
`ORTTAAI_ASR_EVAL_MANIFEST=$PWD/gauntlet/asr_eval/corpus_real/manifest_real.json`
to `run_eval.sh` and `--manifest` to `score.py`.

Real-voice results (2026-10-23, `fluid_real_voice.json`, 50 recordings): Mini with
Word Boost 10.46% WER and 82% hard-vocab recall at 143 ms p50, against
large-v3-turbo with the dictionary pass at 12.06%, 51% and 572 ms. With another
voice in the room: 8.0% against 12.4%.

## Express through the production path (P1.6)

`ORTTAAI_ASR_EVAL_MODEL=fluid-speech-mini` runs the eval through
`TranscriptionService`'s Express backend, installing the pinned Fluid Speech
Mini package into `ORTTAAI_ASR_EVAL_MODEL_ROOT` with `ExpressModelStore` when it
is missing:

```bash
./gauntlet/asr_eval/run_eval.sh /tmp/raw_express.json ORTTAAI_ASR_EVAL_MODEL=fluid-speech-mini \
  ORTTAAI_ASR_EVAL_MODEL_ROOT=/path/to/storage-base
```

`express_production_eval.json` (2026-10-23): 5.19% clean, 5.36% realistic and
16.22% real-voice WER, matching the standalone `fluidbench` run within 0.05
points on the synthetic corpora; the real-voice set is 0.40 points better
because of the `<unk>` apostrophe cleanup. Word Boost is not in the app yet
(tracker Phase 2).

## Word Boost (Phase 2)

With `ORTTAAI_ASR_EVAL_BIAS=1`, a `fluid-speech-mini` run passes the manifest's
`bias_vocabulary` to Express's Word Boost. `word_boost_guard.json` holds the
134 replacements FluidAudio's rescorer proposed across the three corpora, with
the acoustic margins `WordBoostGuard` was fitted on (keeps 103 of 104 correct
ones, none of the 30 wrong ones). `express_word_boost_eval.json` (2026-10-23):
2.41% clean, 3.02% realistic and 9.25% real-voice WER with 84% / 90% / 81%
hard-vocab recall, and no dictionary term inserted where the reference lacks it.

## Number formatting (P3.2)

`ExpressNumberFormatter` writes the numbers Fluid Speech Mini spells out or
dots the way Whisper writes them (`555-0143`, `$2,450`, `March 15th`,
`3:30 p.m.`). It runs on Express output only. `express_number_formatting.json`
(2026-10-23): real-voice WER 9.25% -> 7.91%, and the real-voice number group
12 -> 2 errors in 68 words, level with turbo. Clean 2.41% -> 2.14%, realistic
3.02% -> 2.53%. All 11 changed outputs were number fixes. Date order is left
as written ("the 3rd of March"), which accounts for most of what remains in
the clean number group.

## Polish after Express (P3.1)

`build_polish_corpus.py` voices the polish golden set (`gauntlet/golden_set.json`,
the 139 cases without line breaks) into `corpus_polish/`. Transcribe it with
`ORTTAAI_ASR_EVAL_RULES=1`, which also records each transcript after the app's
rule stage, then score the whole chain with
`gauntlet/polish_eval.py --transcripts RAW.json --out RESULTS.json`
(`--no-polish` scores the rule-stage text alone):

```bash
python3 gauntlet/asr_eval/build_polish_corpus.py
./gauntlet/asr_eval/run_eval.sh /tmp/raw_polish_express.json ORTTAAI_ASR_EVAL_MODEL=fluid-speech-mini \
  ORTTAAI_ASR_EVAL_MODEL_ROOT=/path/to/storage-base ORTTAAI_ASR_EVAL_PATHS=whole ORTTAAI_ASR_EVAL_RULES=1 \
  ORTTAAI_ASR_EVAL_MANIFEST=$PWD/gauntlet/asr_eval/corpus_polish/manifest_polish.json
python3 gauntlet/polish_eval.py --transcripts /tmp/raw_polish_express.json --out /tmp/polish_express.json
```

`express_polish_eval.json` (2026-10-23, gemma4:e2b): polish lifts Express from
45.3% to 49.6% and turbo from 52.5% to 55.4%, so polish needs no change for
Express. The 5.8-point end-to-end gap is already there in the transcripts (no
Word Boost here, since the golden set has no dictionary). End to end, Express
finishes in 96 ms p50 / 171 ms p90 against turbo's 725 ms / 963 ms.

## Long recordings and quiet endings (Phase 4)

`build_long_corpus.py` joins the realistic clips into 10- and 31-minute
recordings in `corpus_long/` (git-ignored). Run them through the live path,
as dictation does, to measure finalize time and memory; each item's raw JSON
now carries the process footprint (`footprint_mb`, `peak_footprint_mb`) and the
run records `footprint_before_load_mb`:

```bash
python3 gauntlet/asr_eval/build_long_corpus.py
./gauntlet/asr_eval/run_eval.sh /tmp/raw_long.json ORTTAAI_ASR_EVAL_MODEL=fluid-speech-mini \
  ORTTAAI_ASR_EVAL_MODEL_ROOT=/path/to/storage-base ORTTAAI_ASR_EVAL_BIAS=1 ORTTAAI_ASR_EVAL_PATHS=live \
  ORTTAAI_ASR_EVAL_MANIFEST=$PWD/gauntlet/asr_eval/corpus_long/manifest_long.json
```

`express_long_recordings_eval.json` (2026-10-23): Word Boost now scores each
15 s chunk while the user speaks, so a 10-minute recording finalizes in 1.9 s
instead of 7.3 s (30 minutes: 5.5 s instead of 22.2 s) with identical text.
Taking a recording copy only when a chunk completes cut the 10-minute peak
footprint from 2.9 GB to 723 MB. Lifting a quiet last word keeps 6 of 6
synthetic soft endings (3 before) and takes realistic WER from 2.53% to 2.34%,
with no change on real voice.
Whisper's live path now copies only the audio after its committed clips:
turbo's transcripts are identical on all 129 items checked, and its 10-minute
peak footprint drops from 4.4 GB to 2.2 GB (2.1 GB on short clips).

## Voice stamps spike (P5.2)

`OrttaaiTests/Eval/VoiceStampSpikeTests.swift` (env-gated) cuts one-shot
"voice stamps" out of Parakeet CTC 110M posteriors for every vocabulary term
spoken in two or more real-voice recordings, and matches each against every
recording with subsequence DTW; `voice_stamp_spike.py` scores it against a
production Express + Word Boost run:

```bash
TEST_RUNNER_ORTTAAI_VOICESTAMP_SPIKE=1 \
TEST_RUNNER_ORTTAAI_VOICESTAMP_MANIFEST=$PWD/gauntlet/asr_eval/corpus_real/manifest_real.json \
TEST_RUNNER_ORTTAAI_VOICESTAMP_MODEL_ROOT=/path/to/storage-base \
TEST_RUNNER_ORTTAAI_VOICESTAMP_OUT=/tmp/spike.json \
xcodebuild ... -only-testing:OrttaaiTests/VoiceStampSpikeTests test
python3 gauntlet/asr_eval/voice_stamp_spike.py /tmp/spike.json /tmp/raw_express_real.json \
  --manifest gauntlet/asr_eval/corpus_real/manifest_real.json
```

`voice_stamp_spike.json` (2026-10-23): with the blank token removed, stamps
recover 5 of the 9 occurrences Word Boost misses at 0.1 false alarms per
recording, meeting the go rule set before the run; with the blank kept they
find nothing. Four of the five are product terms, though, and only one missed
name (Folasade) is recovered, so the verdict is a prototype measured with
deliberate three-take recordings, not a shipped feature.

## Express live segments

With the "Decode while I speak" setting on, Express decodes each stretch of
speech at the speaker's pauses while they are still talking, so finalize only
decodes the audio after the last pause. `ORTTAAI_ASR_EVAL_EXPRESS_SEGMENTS=1`
runs the live path that way; the whole path stays one decode, the reference:

```bash
./gauntlet/asr_eval/run_eval.sh /tmp/raw_segments.json ORTTAAI_ASR_EVAL_MODEL=fluid-speech-mini \
  ORTTAAI_ASR_EVAL_MODEL_ROOT=/path/to/storage-base ORTTAAI_ASR_EVAL_EXPRESS_SEGMENTS=1
```

`express_live_segments_eval.json` (2026-10-23) records four rounds. Each
segment is decoded with the 3 s before it and the 2 s after it, and
neighbouring decodes are stitched in the middle of the longest run of words
they agree on; with no agreement the whole recording is decoded instead.
Against the whole decode: real voice 14.88% both (49 of 50 identical),
clean 4.72% vs 4.92%, realistic 4.38% vs 4.58%, real voice with Word Boost
7.91% both. Segmented recordings finalize in 100 ms instead of 270 ms
(realistic p50) and 122 ms instead of 174 ms (clean). Keeping words by token
timings instead of stitching duplicated and dropped words at the cuts, and
Word Boost run per segment missed two dictionary names, so segments stay off
while Word Boost has dictionary words.
