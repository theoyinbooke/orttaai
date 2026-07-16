#!/usr/bin/env python3
"""Build a stratified dictation-polish eval set from the local Orttaai database.

Samples real transcripts into categories that stress a polish model's known
failure modes (answering questions, altering numbers, over-rewriting long
text). Output is JSONL written to the gitignored eval/ directory — it contains
personal dictation content and must never be committed or uploaded.

Usage:
  python3 scripts/build_polish_eval_set.py [--db PATH] [--out PATH] [--per-bucket N]
"""

import argparse
import json
import random
import re
import sqlite3
from pathlib import Path

DEFAULT_DB = Path.home() / "Library/Application Support/Orttaai/orttaai.db"
DEFAULT_OUT = Path(__file__).resolve().parent.parent / "eval/polish/eval-set.jsonl"

DISFLUENCY_RE = re.compile(
    r"\b(um+|uh+|you know|i mean|sort of|kind of|like,|basically|actually,)\b", re.I
)
NUMBER_RE = re.compile(r"\d")
QUESTION_RE = re.compile(r"\?|^(what|when|where|who|why|how|can you|could you|is it|are we|do we|does)\b", re.I)


def bucket_for(text: str) -> str:
    words = len(text.split())
    if QUESTION_RE.search(text):
        return "question"
    if NUMBER_RE.search(text):
        return "numbers"
    if DISFLUENCY_RE.search(text):
        return "disfluent"
    if words <= 12:
        return "short"
    if words >= 80:
        return "long"
    return "general"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--per-bucket", type=int, default=40)
    parser.add_argument("--seed", type=int, default=20260716)
    args = parser.parse_args()

    connection = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)
    rows = connection.execute(
        "SELECT id, text, targetAppName, recordingDurationMs FROM transcription "
        "WHERE LENGTH(TRIM(text)) >= 12 ORDER BY id"
    ).fetchall()
    connection.close()

    buckets: dict[str, list[dict]] = {}
    for row_id, text, app, duration_ms in rows:
        text = text.strip()
        item = {
            "id": row_id,
            "bucket": bucket_for(text),
            "text": text,
            "target_app": app or "",
            "recording_ms": duration_ms,
        }
        buckets.setdefault(item["bucket"], []).append(item)

    random.seed(args.seed)
    sampled: list[dict] = []
    for name in sorted(buckets):
        pool = buckets[name]
        take = min(args.per_bucket, len(pool))
        sampled.extend(random.sample(pool, take))
        print(f"{name}: {len(pool)} available, sampled {take}")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", encoding="utf-8") as handle:
        for item in sampled:
            handle.write(json.dumps(item, ensure_ascii=False) + "\n")

    print(f"\nWrote {len(sampled)} items to {args.out}")


if __name__ == "__main__":
    main()
