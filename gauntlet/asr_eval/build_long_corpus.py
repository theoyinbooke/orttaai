#!/usr/bin/env python3
"""Builds long hands-free recordings for the finalize-time and memory checks
(tracker P4.3): the realistic corpus's speech items joined end to end, with
0.8 s of the same room-noise floor between them, until each recording reaches
its target length. Hands-free dictation runs up to 30 minutes, so the corpus
has a 10-minute and a 30-minute recording; the 30-minute one cycles through
the items more than once.

Reads corpus_realistic/ (run build_realistic_corpus.py first) and writes
corpus_long/<id>.wav plus corpus_long/manifest_long.json (git-ignored).

Usage: python3 gauntlet/asr_eval/build_long_corpus.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

from build_corpus import SAMPLE_RATE, gaussian_noise, read_float32_wav, write_float32_wav

HERE = Path(__file__).resolve().parent
SOURCE_DIR = HERE / "corpus_realistic"
CORPUS_DIR = HERE / "corpus_long"
GAP_SECONDS = 0.8
GAP_RMS = 0.004
TARGETS = {"long-10min": 600, "long-30min": 1800}


def main() -> int:
    source = json.loads((SOURCE_DIR / "manifest_realistic.json").read_text())
    speech = [item for item in source["items"] if item["reference"].strip()]
    clips = [(item["reference"], read_float32_wav(SOURCE_DIR / item["wav"])) for item in speech]
    CORPUS_DIR.mkdir(exist_ok=True)
    items = []

    for item_id, seconds in TARGETS.items():
        samples: list[float] = []
        references: list[str] = []
        index = 0
        while len(samples) < seconds * SAMPLE_RATE:
            reference, audio = clips[index % len(clips)]
            if samples:
                samples += gaussian_noise(int(GAP_SECONDS * SAMPLE_RATE), GAP_RMS, seed=index)
            samples += audio
            references.append(reference)
            index += 1
        write_float32_wav(CORPUS_DIR / f"{item_id}.wav", samples)
        items.append({
            "id": item_id,
            "category": "long",
            "adversarial": None,
            "hard_terms": [],
            "reference": " ".join(references),
            "wav": f"{item_id}.wav",
            "duration_seconds": round(len(samples) / SAMPLE_RATE, 2),
        })
        print(f"{item_id}: {len(samples) / SAMPLE_RATE / 60:.1f} min from {index} clips", file=sys.stderr)

    manifest = {"sample_rate": SAMPLE_RATE, "bias_vocabulary": source["bias_vocabulary"], "items": items}
    (CORPUS_DIR / "manifest_long.json").write_text(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
