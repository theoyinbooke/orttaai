#!/usr/bin/env python3
"""Builds the "realistic" ASR eval corpus: the tracked TTS items re-mixed the
way real dictation sounds, so the live finalize path meets what the clean
corpus never shows it — a room-noise floor, a key-hold gap of noise after the
last word, whispery speech, and recordings that contain no speech at all.

The clean corpus is digital silence with an instant key release, which cannot
reproduce the slow finalizes (5-9 s vs ~1 s) and stock-phrase hallucinations
("Thank you.", "you") seen in real usage. Everything here is derived at run
time from the checked-in corpus/*.wav (no `say`, no numpy, deterministic
per-item seeds) and written to corpus_realistic/, which is git-ignored:
generate it, never commit it.

Groups (id prefix == category):
  noisy-long-01..08  45-95 s: concatenated long-*/short items, 1.0-3.5 s natural
                     silence gaps between some, a continuous pink-ish noise
                     floor (RMS 0.004-0.012) mixed over the WHOLE file including
                     speech, ending in 0.5-2.5 s of trailing noise (key hold).
  hold-01..12        5-25 s speech + 0.3-2.0 s trailing room noise at RMS 0.006,
                     0.010, 0.015 (4 each) over a 0.004 floor.
  soft-last-01..06   the final word attenuated so its frames sit ~0.02-0.03 RMS
                     (3 items) or ~0.012 (3 items) over a 0.004 floor. These
                     MUST keep their last word: a guard against an over-eager
                     future tail gate.
  noise-only-01..06  empty reference: 3 s digital silence, noise-only 3-8 s at
                     RMS 0.003/0.006/0.010, and two 2 s noise clips at 0.012 /
                     0.006 containing only key-press transients (no speech).
  quiet-01..04       whispery speech (active-frame RMS ~0.025) over a 0.004
                     floor with a short noise tail.

Frame energy reference points (TranscriptionService): faint floor 0.005 RMS,
speech threshold 0.02 RMS, both over 100 ms frames.

Output manifest_realistic.json follows manifest.json's schema (wav,
duration_seconds, hard_terms, reference, ...) plus noise_rms ({floor, tail}).

Usage: python3 gauntlet/asr_eval/build_realistic_corpus.py
"""

from __future__ import annotations

import json
import math
import random
import sys
import zlib
from pathlib import Path

from build_corpus import SAMPLE_RATE, read_float32_wav, write_float32_wav

HERE = Path(__file__).resolve().parent
SOURCE_DIR = HERE / "corpus"
OUT_DIR = HERE / "corpus_realistic"

FRAME = SAMPLE_RATE // 100  # 10 ms analysis frames for level measurement
LEAD_SECONDS = 0.15
NATURAL_JOIN_SECONDS = 0.25
FLOOR_RMS = 0.004

NOISY_LONG_RECIPES = [
    # (source ids, floor RMS, max gap seconds)
    (["long-001", "tech-005", "num-005", "ev-004"], 0.004, 3.5),
    (["long-002", "long-003"], 0.005, 3.5),
    (["long-004", "long-005", "ev-007"], 0.006, 3.5),
    (["long-006", "long-010", "long-014"], 0.007, 1.8),
    (["long-007", "long-008", "pn-005"], 0.008, 3.5),
    (["long-011", "tech-008", "long-012"], 0.009, 3.5),
    (["long-015", "long-016", "num-002"], 0.010, 3.5),
    (["long-020", "long-021"], 0.012, 3.5),
]

HOLD_SOURCES = [
    ["num-001"], ["num-003"], ["num-004"], ["num-005"],
    ["num-008"], ["num-009"], ["num-010"], ["tech-005"],
    ["tech-001", "tech-002", "tech-003"],
    ["pn-001", "pn-004", "pn-007", "ev-005"],
    ["num-002", "num-006", "num-007", "num-011"],
    ["tech-010", "tech-012", "num-012", "pn-010", "ev-009"],
]
HOLD_TAIL_RMS = [0.006, 0.010, 0.015]

SOFT_LAST_RECIPES = [
    # (source id, target RMS of the final word's frames)
    ("ev-006", 0.025), ("ev-007", 0.020), ("tech-006", 0.030),
    ("ev-009", 0.012), ("pn-008", 0.012), ("ev-011", 0.012),
]

NOISE_ONLY_RECIPES = [
    # (description, seconds, noise RMS, key-press transients)
    ("digital silence", 3.0, 0.0, False),
    ("noise only", 5.0, 0.003, False),
    ("noise only", 4.0, 0.006, False),
    ("noise only", 8.0, 0.010, False),
    ("noise + key press", 2.0, 0.012, True),
    ("noise + key press", 2.0, 0.006, True),
]

QUIET_SOURCES = ["pn-001", "tech-005", "num-004", "ev-006"]
QUIET_SPEECH_RMS = 0.025


def seeded(item_id: str) -> random.Random:
    return random.Random(zlib.crc32(item_id.encode()))


def rms(samples: list[float]) -> float:
    if not samples:
        return 0.0
    return math.sqrt(sum(s * s for s in samples) / len(samples))


def frame_rms_list(samples: list[float]) -> list[float]:
    return [rms(samples[i:i + FRAME]) for i in range(0, len(samples) - FRAME + 1, FRAME)]


def active_rms(samples: list[float], threshold: float = 0.01) -> float:
    """RMS over the frames that carry speech (10 ms frames above threshold)."""
    active = [f for f in frame_rms_list(samples) if f >= threshold]
    if not active:
        return 0.0
    return math.sqrt(sum(f * f for f in active) / len(active))


def speech_end(samples: list[float], threshold: float = 0.005) -> int:
    """Sample index just past the last frame at or above threshold."""
    frames = frame_rms_list(samples)
    for index in range(len(frames) - 1, -1, -1):
        if frames[index] >= threshold:
            return (index + 1) * FRAME
    return 0


def pink_noise(count: int, target_rms: float, rng: random.Random) -> list[float]:
    """Pink-ish noise (Kellet's 3-pole filter over white noise), scaled to an
    exact RMS."""
    if count <= 0 or target_rms <= 0:
        return [0.0] * max(count, 0)
    b0 = b1 = b2 = 0.0
    out = []
    gauss = rng.gauss
    for _ in range(count):
        white = gauss(0.0, 1.0)
        b0 = 0.99765 * b0 + white * 0.0990460
        b1 = 0.96300 * b1 + white * 0.2965164
        b2 = 0.57000 * b2 + white * 1.0526913
        out.append(b0 + b1 + b2 + white * 0.1848)
    scale = target_rms / rms(out)
    return [s * scale for s in out]


def silence(seconds: float) -> list[float]:
    return [0.0] * int(round(seconds * SAMPLE_RATE))


def load_source(item_id: str) -> list[float]:
    """A corpus item with its dead-silent tail trimmed, so the gaps between
    concatenated items are exactly the ones this script inserts."""
    samples = read_float32_wav(SOURCE_DIR / f"{item_id}.wav")
    end = speech_end(samples, threshold=0.001)
    return samples[:min(len(samples), end + int(0.1 * SAMPLE_RATE))]


def concatenate(parts: list[list[float]], gaps: list[float]) -> list[float]:
    out: list[float] = []
    for index, part in enumerate(parts):
        out += part
        if index < len(gaps):
            out += silence(gaps[index])
    return out


def mix(speech: list[float], floor: list[float]) -> list[float]:
    return [a + b for a, b in zip(speech, floor)]


def with_floor_and_tail(
    speech: list[float], floor_rms: float, tail_seconds: float, tail_rms: float,
    rng: random.Random,
) -> list[float]:
    """Speech over a continuous noise floor, then a key-hold tail of noise."""
    lead = silence(LEAD_SECONDS)
    body = lead + speech
    mixed = mix(body, pink_noise(len(body), floor_rms, rng))
    return mixed + pink_noise(int(round(tail_seconds * SAMPLE_RATE)), tail_rms, rng)


def key_press(rng: random.Random, amplitude: float = 0.08) -> list[float]:
    """A ~40 ms keyboard thump: a decaying noise burst."""
    tau = 0.004 * SAMPLE_RATE
    return [amplitude * math.exp(-i / tau) * rng.uniform(-1, 1) for i in range(int(0.04 * SAMPLE_RATE))]


def refs_of(ids: list[str], by_id: dict) -> str:
    return " ".join(by_id[i]["reference"] for i in ids)


def terms_of(ids: list[str], by_id: dict) -> list[str]:
    seen: list[str] = []
    for i in ids:
        for term in by_id[i]["hard_terms"]:
            if term not in seen:
                seen.append(term)
    return seen


def build_noisy_long(by_id: dict, entries: list) -> None:
    for index, (ids, floor_rms, max_gap) in enumerate(NOISY_LONG_RECIPES, start=1):
        item_id = f"noisy-long-{index:02d}"
        rng = seeded(item_id)
        gaps = [
            round(rng.uniform(1.0, max_gap), 1) if rng.random() < 0.6 else NATURAL_JOIN_SECONDS
            for _ in ids[:-1]
        ]
        tail = round(rng.uniform(0.5, 2.5), 1)
        speech = concatenate([load_source(i) for i in ids], gaps)
        samples = with_floor_and_tail(speech, floor_rms, tail, floor_rms, rng)
        entries.append(finish(
            item_id, "noisy-long", samples, refs_of(ids, by_id), terms_of(ids, by_id),
            {"floor": floor_rms, "tail": floor_rms}, f"sources={'+'.join(ids)} gaps={gaps} tail_s={tail}",
        ))


def build_hold(by_id: dict, entries: list) -> None:
    for index, ids in enumerate(HOLD_SOURCES, start=1):
        item_id = f"hold-{index:02d}"
        rng = seeded(item_id)
        tail_rms = HOLD_TAIL_RMS[(index - 1) % len(HOLD_TAIL_RMS)]
        tail = round(rng.uniform(0.3, 2.0), 1)
        gaps = [round(rng.uniform(0.5, 0.9), 1) for _ in ids[:-1]]
        speech = concatenate([load_source(i) for i in ids], gaps)
        assert 5 <= len(speech) / SAMPLE_RATE <= 25, (item_id, len(speech) / SAMPLE_RATE)
        samples = with_floor_and_tail(speech, FLOOR_RMS, tail, tail_rms, rng)
        entries.append(finish(
            item_id, "hold", samples, refs_of(ids, by_id), terms_of(ids, by_id),
            {"floor": FLOOR_RMS, "tail": tail_rms}, f"sources={'+'.join(ids)} tail_s={tail}",
        ))


def last_word_start(samples: list[float], end: int) -> int:
    """Start of the final word: the last low-energy dip (>= 30 ms below a fifth
    of the median speech frame) at least 120 ms before the speech end. Falls
    back to the last 350 ms when the item has no usable dip."""
    frames = frame_rms_list(samples[:end])
    speech_frames = sorted(f for f in frames if f >= 0.01)
    if not speech_frames:
        return max(0, end - int(0.35 * SAMPLE_RATE))
    dip = speech_frames[len(speech_frames) // 2] * 0.2
    min_word_frames = 12
    run = 0
    for index in range(len(frames) - 1 - min_word_frames, -1, -1):
        run = run + 1 if frames[index] < dip else 0
        if run >= 3:
            return (index + run) * FRAME
    return max(0, end - int(0.35 * SAMPLE_RATE))


def build_soft_last(by_id: dict, entries: list) -> None:
    for index, (source_id, target_rms) in enumerate(SOFT_LAST_RECIPES, start=1):
        item_id = f"soft-last-{index:02d}"
        rng = seeded(item_id)
        speech = load_source(source_id)
        end = speech_end(speech)
        start = last_word_start(speech, end)
        word = speech[start:end]
        gain = target_rms / active_rms(word)
        # Fade to the attenuated level across the low-energy dip just before
        # the word, so the step is inaudible and no loud audio leaks through.
        ramp = min(start, FRAME * 2)
        for offset in range(ramp):
            speech[start - ramp + offset] *= 1.0 + (gain - 1.0) * (offset / ramp)
        for offset in range(len(word)):
            speech[start + offset] *= gain
        measured = active_rms(speech[start:end], threshold=0.003)
        tail = round(rng.uniform(0.4, 0.8), 1)
        samples = with_floor_and_tail(speech, FLOOR_RMS, tail, FLOOR_RMS, rng)
        entries.append(finish(
            item_id, "soft-last", samples, by_id[source_id]["reference"], by_id[source_id]["hard_terms"],
            {"floor": FLOOR_RMS, "tail": FLOOR_RMS},
            f"source={source_id} last_word_target_rms={target_rms} measured={measured:.4f} "
            f"word_s={(end - start) / SAMPLE_RATE:.2f}",
        ))


def build_noise_only(entries: list) -> None:
    for index, (label, seconds, noise_rms, presses) in enumerate(NOISE_ONLY_RECIPES, start=1):
        item_id = f"noise-only-{index:02d}"
        rng = seeded(item_id)
        count = int(seconds * SAMPLE_RATE)
        samples = pink_noise(count, noise_rms, rng) if noise_rms > 0 else [0.0] * count
        if presses:
            # Press near the start and release near the end, like a key-hold.
            for at in (0.25, seconds - 0.35):
                thump = key_press(rng)
                begin = int(at * SAMPLE_RATE)
                for offset, value in enumerate(thump):
                    samples[begin + offset] += value
        entries.append(finish(
            item_id, "noise-only", samples, "", [],
            {"floor": noise_rms, "tail": noise_rms}, label,
        ))


def build_quiet(by_id: dict, entries: list) -> None:
    for index, source_id in enumerate(QUIET_SOURCES, start=1):
        item_id = f"quiet-{index:02d}"
        rng = seeded(item_id)
        speech = load_source(source_id)
        gain = QUIET_SPEECH_RMS / active_rms(speech)
        speech = [s * gain for s in speech]
        tail = round(rng.uniform(0.4, 0.8), 1)
        samples = with_floor_and_tail(speech, FLOOR_RMS, tail, FLOOR_RMS, rng)
        entries.append(finish(
            item_id, "quiet", samples, by_id[source_id]["reference"], by_id[source_id]["hard_terms"],
            {"floor": FLOOR_RMS, "tail": FLOOR_RMS},
            f"source={source_id} speech_rms={QUIET_SPEECH_RMS} gain={gain:.3f}",
        ))


def finish(
    item_id: str, category: str, samples: list[float], reference: str, hard_terms: list[str],
    noise_rms: dict, note: str,
) -> dict:
    write_float32_wav(OUT_DIR / f"{item_id}.wav", samples)
    duration = len(samples) / SAMPLE_RATE
    print(f"{item_id}: {duration:.1f}s  {note}", file=sys.stderr)
    return {
        "id": item_id,
        "category": category,
        "adversarial": None,
        "hard_terms": hard_terms,
        "reference": reference,
        "wav": f"{item_id}.wav",
        "voice": "mixed",
        "rate_wpm": 0,
        "duration_seconds": round(duration, 2),
        "noise_rms": noise_rms,
        "note": note,
    }


def main() -> int:
    source = json.loads((SOURCE_DIR / "manifest.json").read_text())
    by_id = {item["id"]: item for item in source["items"]}
    OUT_DIR.mkdir(exist_ok=True)

    entries: list[dict] = []
    build_noisy_long(by_id, entries)
    build_hold(by_id, entries)
    build_soft_last(by_id, entries)
    build_noise_only(entries)
    build_quiet(by_id, entries)

    for entry in entries:
        if entry["category"] == "noisy-long":
            assert 45 <= entry["duration_seconds"] <= 95, entry

    manifest = {
        "sample_rate": SAMPLE_RATE,
        "bias_vocabulary": source["bias_vocabulary"],
        "items": entries,
    }
    (OUT_DIR / "manifest_realistic.json").write_text(json.dumps(manifest, indent=2))
    total = sum(e["duration_seconds"] for e in entries)
    print(f"Built {len(entries)} items, {total / 60:.1f} min of audio in {OUT_DIR}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
