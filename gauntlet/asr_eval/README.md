# ASR eval — live-path accuracy and vocabulary biasing

Measures the transcription accuracy of Orttaai's two decode paths against
each other and against a recorded baseline:

- **whole** — `TranscriptionService.transcribe(audioSamples:)`, the single
  whole-utterance decode (the reference standard).
- **live** — the real live-session machinery: `beginLiveTranscriptionSession`,
  incremental `processLiveAudioSnapshot` polling (15 s clip commits, pause
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
