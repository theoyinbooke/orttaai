#!/usr/bin/env python3
"""Voices the polish golden set (gauntlet/golden_set.json) so the polish stage
can be scored on what each speech engine actually hears.

Each case's `raw` text is spoken with macOS `say` exactly like the clean
corpus (build_corpus.py): 16 kHz mono Float32 WAV, voices rotating over
Samantha/Daniel/Karen/Moira, rates alternating 170/205 wpm. The manifest's
`reference` is the golden `raw`, so score.py can also report each engine's
WER on it.

Cases whose raw text contains line breaks are skipped: their breaks and list
markers come from spoken-formatting commands, and the golden set does not
record what was said to produce them.

Writes corpus_polish/<id>.wav plus corpus_polish/manifest_polish.json
(git-ignored). Transcribe it with run_eval.sh, then score polish with
`gauntlet/polish_eval.py --transcripts RAW.json --out RESULTS.json`.

Usage: python3 gauntlet/asr_eval/build_polish_corpus.py
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

from build_corpus import RATES, SAMPLE_RATE, VOICES, read_float32_wav

HERE = Path(__file__).resolve().parent
GOLDEN_SET = HERE.parent / "golden_set.json"
CORPUS_DIR = HERE / "corpus_polish"


def main() -> int:
    cases = json.loads(GOLDEN_SET.read_text())["cases"]
    CORPUS_DIR.mkdir(exist_ok=True)
    items = []
    skipped = []

    for index, case in enumerate(cases):
        text = case["raw"].strip()
        if "\n" in text:
            skipped.append(case["id"])
            continue
        voice = VOICES[index % len(VOICES)]
        rate = RATES[index % len(RATES)]
        wav_path = CORPUS_DIR / f'{case["id"]}.wav'
        subprocess.run(
            ["say", "-v", voice, "-r", str(rate), "-o", str(wav_path), f"--data-format=LEF32@{SAMPLE_RATE}", text],
            check=True,
        )
        duration = len(read_float32_wav(wav_path)) / SAMPLE_RATE
        items.append({
            "id": case["id"],
            "category": case["category"],
            "adversarial": None,
            "hard_terms": [],
            "reference": text,
            "wav": wav_path.name,
            "voice": voice,
            "rate_wpm": rate,
            "duration_seconds": round(duration, 2),
        })

    manifest = {"sample_rate": SAMPLE_RATE, "bias_vocabulary": [], "items": items}
    (CORPUS_DIR / "manifest_polish.json").write_text(json.dumps(manifest, indent=2))
    total = sum(i["duration_seconds"] for i in items)
    print(f"Built {len(items)} items, {total / 60:.1f} min of audio; skipped {len(skipped)} with line breaks", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
