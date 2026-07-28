#!/usr/bin/env python3
"""Builds the ASR eval audio corpus from corpus_texts.json using macOS `say`.

Each item is synthesized at 16 kHz mono Float32 WAV (the exact sample format
TranscriptionService consumes) with a deterministic voice/rate assignment:
voices rotate over [Samantha, Daniel, Karen, Moira] (4 voices, US/GB/AU/IE
accents) and rates alternate between 170 and 205 wpm, both keyed on the item's
position so rebuilding the corpus is reproducible.

[[slnc N]] embedded commands in the text produce genuine silence gaps (pause
commits and the adversarial silence-gap items depend on them); they are
stripped from the reference transcript.

Adversarial post-processing:
  - noise_tail: 4.0 s of Gaussian noise at RMS 0.012 is appended — above the
    app's faint-energy floor (0.005) so it is NOT trimmed, below the speech
    threshold (0.02) so it is never treated as speech. This is the
    "background noise only, no speech" tail the hallucination check targets.

Writes corpus/<id>.wav plus corpus/manifest.json with the reference text,
hard-vocab terms, voice, rate, duration, category, and adversarial kind.

Usage: python3 gauntlet/asr_eval/build_corpus.py
"""

from __future__ import annotations

import json
import math
import re
import struct
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CORPUS_DIR = HERE / "corpus"
VOICES = ["Samantha", "Daniel", "Karen", "Moira"]
RATES = [170, 205]
NOISE_TAIL_SECONDS = 4.0
NOISE_RMS = 0.012
SAMPLE_RATE = 16000

SLNC_RE = re.compile(r"\s*\[\[slnc \d+\]\]\s*")


def reference_text(text: str) -> str:
    return SLNC_RE.sub(" ", text).strip()


def read_float32_wav(path: Path) -> list[float]:
    data = path.read_bytes()
    # Minimal RIFF parse: find the 'data' chunk after 'fmt '.
    assert data[:4] == b"RIFF" and data[8:12] == b"WAVE", path
    pos = 12
    samples = b""
    fmt_code = None
    while pos + 8 <= len(data):
        chunk_id = data[pos:pos + 4]
        size = struct.unpack("<I", data[pos + 4:pos + 8])[0]
        body = data[pos + 8:pos + 8 + size]
        if chunk_id == b"fmt ":
            fmt_code = struct.unpack("<H", body[0:2])[0]
            channels = struct.unpack("<H", body[2:4])[0]
            rate = struct.unpack("<I", body[4:8])[0]
            assert channels == 1 and rate == SAMPLE_RATE, (channels, rate, path)
        elif chunk_id == b"data":
            samples = body
        pos += 8 + size + (size & 1)
    assert fmt_code == 3, f"expected IEEE float wav, got fmt {fmt_code} in {path}"
    count = len(samples) // 4
    return list(struct.unpack(f"<{count}f", samples[:count * 4]))


def write_float32_wav(path: Path, samples: list[float]) -> None:
    body = struct.pack(f"<{len(samples)}f", *samples)
    byte_rate = SAMPLE_RATE * 4
    header = b"RIFF" + struct.pack("<I", 4 + 8 + 16 + 8 + len(body)) + b"WAVE"
    fmt = b"fmt " + struct.pack("<IHHIIHH", 16, 3, 1, SAMPLE_RATE, byte_rate, 4, 32)
    data = b"data" + struct.pack("<I", len(body))
    path.write_bytes(header + fmt + data + body)


def gaussian_noise(count: int, rms: float, seed: int) -> list[float]:
    # Deterministic Box-Muller noise, no numpy dependency.
    import random

    rng = random.Random(seed)
    out = []
    for _ in range(count):
        u1 = max(rng.random(), 1e-12)
        u2 = rng.random()
        out.append(rms * math.sqrt(-2.0 * math.log(u1)) * math.cos(2 * math.pi * u2))
    return out


def main() -> int:
    spec = json.loads((HERE / "corpus_texts.json").read_text())
    CORPUS_DIR.mkdir(exist_ok=True)
    manifest_items = []

    for index, item in enumerate(spec["items"]):
        item_id = item["id"]
        voice = VOICES[index % len(VOICES)]
        rate = RATES[index % len(RATES)]
        wav_path = CORPUS_DIR / f"{item_id}.wav"

        subprocess.run(
            [
                "say", "-v", voice, "-r", str(rate),
                "-o", str(wav_path),
                f"--data-format=LEF32@{SAMPLE_RATE}",
                item["text"],
            ],
            check=True,
        )

        samples = read_float32_wav(wav_path)
        if item.get("adversarial") == "noise_tail":
            samples += gaussian_noise(int(NOISE_TAIL_SECONDS * SAMPLE_RATE), NOISE_RMS, seed=index)
            write_float32_wav(wav_path, samples)

        duration = len(samples) / SAMPLE_RATE
        manifest_items.append({
            "id": item_id,
            "category": item["category"],
            "adversarial": item.get("adversarial"),
            "hard_terms": item["hard_terms"],
            "reference": reference_text(item["text"]),
            "wav": wav_path.name,
            "voice": voice,
            "rate_wpm": rate,
            "duration_seconds": round(duration, 2),
        })
        print(f"{item_id}: {voice}@{rate}wpm {duration:.1f}s", file=sys.stderr)

    manifest = {
        "sample_rate": SAMPLE_RATE,
        "bias_vocabulary": spec["bias_vocabulary"],
        "items": manifest_items,
    }
    (CORPUS_DIR / "manifest.json").write_text(json.dumps(manifest, indent=2))
    total = sum(i["duration_seconds"] for i in manifest_items)
    print(f"Built {len(manifest_items)} items, {total/60:.1f} min of audio", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
