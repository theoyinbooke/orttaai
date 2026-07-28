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
