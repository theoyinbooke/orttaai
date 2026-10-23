#!/usr/bin/env python3
"""Scores the voice-stamp spike (tracker P5.2).

Inputs: the JSON from VoiceStampSpikeTests (stamp-to-recording DTW matches)
and a raw Express + Word Boost decode of the same corpus from run_eval.sh,
which shows the occurrences Word Boost still gets wrong.

A match counts as a detection when its cost is at or below the threshold and
its span overlaps where the CTC spotter placed the term in that recording.
False alarms are matches at or below the threshold in recordings that never
say the term. The decision rule was fixed before the run: go if, at a
threshold with at most 1% false alarms, stamps recover at least half of the
occurrences Word Boost misses.

Usage:
  python3 gauntlet/asr_eval/voice_stamp_spike.py SPIKE.json EXPRESS_RAW.json \
      --manifest gauntlet/asr_eval/corpus_real/manifest_real.json
"""

from __future__ import annotations

import argparse
import json
import re
from collections import defaultdict
from pathlib import Path

MAX_FALSE_ALARM_RATE = 0.01
MIN_RECOVERED_SHARE = 0.5


def spoken(term: str, text: str) -> bool:
    return re.search(r"\b" + re.escape(term) + r"\b", text, re.IGNORECASE) is not None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("spike")
    ap.add_argument("express_raw")
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--out")
    args = ap.parse_args()

    spike = json.loads(Path(args.spike).read_text())
    raw = {item["id"]: item for item in json.loads(Path(args.express_raw).read_text())["items"]}
    truth = {(o["term"], o["clip"]): (o["startFrame"], o["endFrame"]) for o in spike["occurrences"]}

    # Occurrences Express + Word Boost wrote wrong.
    missed = {
        (term, clip) for (term, clip) in truth
        if clip in raw and not spoken(term, (raw[clip].get("whole") or raw[clip].get("live") or {}).get("text", ""))
    }

    report = {"occurrences": len(truth), "word_boost_missed": sorted(f"{t} @ {c}" for t, c in missed), "variants": {}}
    for variant in sorted({m["variant"] for m in spike["matches"]}):
        matches = [m for m in spike["matches"] if m["variant"] == variant]
        positives = [m for m in matches if m["clipHasTerm"]]
        negatives = [m for m in matches if not m["clipHasTerm"]]

        def localized(m: dict) -> bool:
            start, end = truth.get((m["term"], m["clip"]), (None, None))
            return start is not None and m["startFrame"] <= end + 1 and m["endFrame"] >= start - 1

        # Threshold: the largest cost that keeps false alarms within budget.
        negative_costs = sorted(m["cost"] for m in negatives)
        allowed = int(len(negative_costs) * MAX_FALSE_ALARM_RATE)
        threshold = negative_costs[allowed] - 1e-6 if allowed < len(negative_costs) else float("inf")
        if allowed == 0:
            threshold = negative_costs[0] - 1e-6

        detected = [m for m in positives if m["cost"] <= threshold and localized(m)]
        false_alarms = [m for m in negatives if m["cost"] <= threshold]

        # A stamp only needs one good example per occurrence: count an
        # occurrence as recovered if any of its stamps finds it.
        found_occurrences = {(m["term"], m["clip"]) for m in detected}
        recovered = found_occurrences & missed

        # Ranking view: is the right recording the stamp's best match?
        by_stamp = defaultdict(list)
        for m in matches:
            by_stamp[(m["term"], m["stampClip"])].append(m)
        top1 = sum(
            1 for ms in by_stamp.values()
            if min(ms, key=lambda m: m["cost"])["clipHasTerm"] and localized(min(ms, key=lambda m: m["cost"]))
        )

        report["variants"][variant] = {
            "threshold": round(threshold, 4),
            "positive_pairs": len(positives),
            "detected_pairs": len(detected),
            "negative_pairs": len(negatives),
            "false_alarms": len(false_alarms),
            "occurrences_found": len(found_occurrences),
            "word_boost_missed": len(missed),
            "word_boost_misses_recovered": len(recovered),
            "recovered": sorted(f"{t} @ {c}" for t, c in recovered),
            "stamps": len(by_stamp),
            "best_match_is_right_recording": top1,
            "go": bool(missed) and len(recovered) >= MIN_RECOVERED_SHARE * len(missed),
        }

    text = json.dumps(report, indent=2)
    print(text)
    if args.out:
        Path(args.out).write_text(text + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
