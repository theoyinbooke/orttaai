#!/usr/bin/env python3
"""Scores a raw ASR eval run (produced by ASREvalRunnerTests) against the
corpus manifest and writes an aggregate results JSON.

Metrics per path (whole / live):
  - WER on normalized text (lowercase, punctuation stripped, number words
    converted toward digits, currency/percent/ordinal/time unification).
    Both reference and hypothesis pass through the SAME normalizer.
  - hard-vocab recall: fraction of per-item hard terms found in the
    hypothesis. Reported two ways:
      strict  — case-insensitive exact substring on whitespace-normalized text
      lenient — additionally space/hyphen-insensitive (so "use effect
                callback" counts for useEffectCallback: the words were
                recognized even if not joined)
  - finalization latency p50/p90 (live path).
  - hallucination artifacts, per item:
      repetition_loop — some 1..4-gram repeats consecutively >= 3 more times
                        in the hypothesis than in the reference
      invented_run    — >= 8 consecutive hypothesis words that are pure
                        insertions against the alignment with the reference

Usage:
  python3 gauntlet/asr_eval/score.py RAW_RUN.json [--label baseline] \
      [--out gauntlet/asr_eval/results.json] [--compare BASELINE.json]

--compare adds relative deltas and the new-hallucination check against a
previously written results file.
"""

from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
MANIFEST = HERE / "corpus" / "manifest.json"

UNITS = {
    "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
    "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
    "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
    "seventeen": 17, "eighteen": 18, "nineteen": 19,
}
TENS = {
    "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
    "seventy": 70, "eighty": 80, "ninety": 90,
}
SCALES = {"hundred": 100, "thousand": 1000, "million": 1_000_000, "billion": 1_000_000_000}
ORDINAL_WORDS = {
    "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
    "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11,
    "twelfth": 12, "thirteenth": 13, "fifteenth": 15, "twentieth": 20,
    "thirtieth": 30, "seventeenth": 17, "twenty-second": 22, "twenty-eighth": 28,
}


def words_to_digits(tokens: list[str]) -> list[str]:
    """Greedy left-to-right conversion of number-word runs to digit tokens."""
    out: list[str] = []
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if tok in ORDINAL_WORDS:
            out.append(str(ORDINAL_WORDS[tok]))
            i += 1
            continue
        if tok not in UNITS and tok not in TENS:
            out.append(tok)
            i += 1
            continue
        # Parse a number-word run.
        total = 0
        current = 0
        consumed = 0
        j = i
        while j < len(tokens):
            t = tokens[j]
            if t in UNITS:
                # "twenty twenty six" style year fragments break the run: a
                # unit directly after a completed tens+unit group starts a new
                # number, which we keep as separate tokens.
                if current % 10 != 0 and t in UNITS:
                    break
                current += UNITS[t]
            elif t in TENS:
                if 0 < current < 20 and current % 10 != 0:
                    break
                current += TENS[t]
            elif t in SCALES:
                current = max(current, 1) * SCALES[t]
                if SCALES[t] >= 1000:
                    total += current
                    current = 0
            elif t == "and" and consumed > 0 and j + 1 < len(tokens) and (
                tokens[j + 1] in UNITS or tokens[j + 1] in TENS
            ):
                j += 1
                consumed += 1
                continue
            else:
                break
            j += 1
            consumed = j - i
        if consumed == 0:
            out.append(tok)
            i += 1
        else:
            out.append(str(total + current))
            i = i + consumed
    return out


def normalize(text: str) -> list[str]:
    t = text.lower()
    t = t.replace("’", "'").replace("‘", "'")
    t = re.sub(r"\[blank_audio\]", " ", t)
    # Currency: $1,250.50 -> 1250.50 dollars ; $2.4 million -> 2.4 million dollars
    def currency(m: re.Match) -> str:
        amount = m.group(1).replace(",", "")
        scale = m.group(2) or ""
        return f"{amount} {scale} dollars".replace("  ", " ")
    t = re.sub(r"\$\s?([\d,]+(?:\.\d+)?)\s*(million|billion|thousand)?", currency, t)
    t = t.replace("%", " percent ")
    t = re.sub(r"(\d),(\d)", r"\1\2", t)          # 1,847 -> 1847
    t = re.sub(r"(\d+):(\d+)", r"\1 \2", t)        # 3:30 -> 3 30
    t = re.sub(r"(\d+)(st|nd|rd|th)\b", r"\1", t)  # 22nd -> 22
    t = re.sub(r"\ba\.m\b\.?", " am ", t)
    t = re.sub(r"\bp\.m\b\.?", " pm ", t)
    t = re.sub(r"(\d)\s*(am|pm)\b", r"\1 \2", t)   # 9am -> 9 am
    t = re.sub(r"(\d)\s*(?:point|\.)\s*(\d)", r"\1.\2", t)  # two point four normalized later
    t = t.replace("-", " ").replace("/", " ")
    t = re.sub(r"[^a-z0-9.' ]", " ", t)
    t = re.sub(r"(?<!\d)\.(?!\d)", " ", t)         # keep decimal points only
    tokens = [tok.strip(".'") for tok in t.split()]
    tokens = [tok for tok in tokens if tok]
    tokens = words_to_digits(tokens)
    # "point" between digits: 2 point 4 -> 2.4
    merged: list[str] = []
    k = 0
    while k < len(tokens):
        if (
            k + 2 < len(tokens) and tokens[k].isdigit() and tokens[k + 1] == "point"
            and tokens[k + 2].isdigit()
        ):
            merged.append(f"{tokens[k]}.{tokens[k + 2]}")
            k += 3
        else:
            merged.append(tokens[k])
            k += 1
    # "N dollars and M cents" -> "N.MM dollars" (matches "$N.MM" -> "N.MM dollars")
    joined: list[str] = []
    k = 0
    while k < len(merged):
        if (
            k + 4 < len(merged) and merged[k].isdigit() and merged[k + 1] == "dollars"
            and merged[k + 2] == "and" and merged[k + 3].isdigit() and merged[k + 4] == "cents"
        ):
            joined.append(f"{merged[k]}.{int(merged[k + 3]):02d}")
            joined.append("dollars")
            k += 5
        else:
            joined.append(merged[k])
            k += 1
    # Canonicalize pure-digit tokens (strip leading zeros: "05" == "5").
    return [str(int(tok)) if tok.isdigit() else tok for tok in joined]


def align(ref: list[str], hyp: list[str]) -> tuple[int, list[str]]:
    """Levenshtein distance and per-hyp-token op tags ('m','s','i')."""
    rows, cols = len(ref) + 1, len(hyp) + 1
    dist = [[0] * cols for _ in range(rows)]
    for i in range(rows):
        dist[i][0] = i
    for j in range(cols):
        dist[0][j] = j
    for i in range(1, rows):
        for j in range(1, cols):
            sub = dist[i - 1][j - 1] + (ref[i - 1] != hyp[j - 1])
            dist[i][j] = min(sub, dist[i - 1][j] + 1, dist[i][j - 1] + 1)
    # Backtrace for hyp-token tags.
    tags: list[str] = []
    i, j = len(ref), len(hyp)
    while i > 0 or j > 0:
        if i > 0 and j > 0 and dist[i][j] == dist[i - 1][j - 1] + (ref[i - 1] != hyp[j - 1]):
            tags.append("m" if ref[i - 1] == hyp[j - 1] else "s")
            i, j = i - 1, j - 1
        elif j > 0 and dist[i][j] == dist[i][j - 1] + 1:
            tags.append("i")
            j -= 1
        else:
            i -= 1  # deletion: no hyp token
    tags.reverse()
    return dist[len(ref)][len(hyp)], tags


def max_consecutive_ngram_repeat(tokens: list[str], n: int) -> int:
    if len(tokens) < n * 2:
        return 1
    best = 1
    i = 0
    while i + n <= len(tokens):
        gram = tokens[i:i + n]
        count = 1
        j = i + n
        while j + n <= len(tokens) and tokens[j:j + n] == gram:
            count += 1
            j += n
        best = max(best, count)
        i += 1
    return best


def hallucination_artifacts(ref: list[str], hyp: list[str]) -> list[str]:
    artifacts = []
    for n in range(1, 5):
        if max_consecutive_ngram_repeat(hyp, n) >= max_consecutive_ngram_repeat(ref, n) + 3:
            artifacts.append(f"repetition_loop_{n}gram")
            break
    _, tags = align(ref, hyp)
    run = 0
    for tag in tags:
        run = run + 1 if tag == "i" else 0
        if run >= 8:
            artifacts.append("invented_run")
            break
    return artifacts


def squash(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip().lower()


def term_recall(term: str, hyp_text: str) -> tuple[bool, bool]:
    hyp = squash(hyp_text)
    strict = term.lower() in hyp
    # lenient: also match ignoring spaces/hyphens (camelCase split by ASR)
    flat_hyp = re.sub(r"[\s\-]", "", hyp)
    flat_term = re.sub(r"[\s\-]", "", term.lower())
    lenient = strict or flat_term in flat_hyp
    return strict, lenient


def score_path(items, raw_by_id, path_key):
    per_item = {}
    total_err = 0
    total_ref = 0
    latencies = []
    strict_hits = strict_total = lenient_hits = 0
    for item in items:
        raw = raw_by_id.get(item["id"], {}).get(path_key)
        if raw is None:
            continue
        ref = normalize(item["reference"])
        hyp = normalize(raw["text"])
        errors, _ = align(ref, hyp)
        wer = errors / max(len(ref), 1)
        artifacts = hallucination_artifacts(ref, hyp)
        terms = {}
        for term in item["hard_terms"]:
            s, l = term_recall(term, raw["text"])
            terms[term] = {"strict": s, "lenient": l}
            strict_total += 1
            strict_hits += s
            lenient_hits += l
        total_err += errors
        total_ref += max(len(ref), 1)
        latencies.append(raw["ms"])
        per_item[item["id"]] = {
            "wer": round(wer, 4),
            "errors": errors,
            "ref_len": len(ref),
            "ms": raw["ms"],
            "hallucination_artifacts": artifacts,
            "hard_terms": terms,
            "text": raw["text"],
            "error": raw.get("error"),
        }
    lat_sorted = sorted(latencies)
    def pct(p):
        if not lat_sorted:
            return None
        return lat_sorted[min(len(lat_sorted) - 1, int(round(p * (len(lat_sorted) - 1))))]
    return {
        "aggregate_wer": round(total_err / max(total_ref, 1), 4),
        "total_errors": total_err,
        "total_ref_words": total_ref,
        "items_scored": len(per_item),
        "hard_vocab_recall_strict": round(strict_hits / strict_total, 4) if strict_total else None,
        "hard_vocab_recall_lenient": round(lenient_hits / strict_total, 4) if strict_total else None,
        "hard_vocab_occurrences": strict_total,
        "latency_ms_p50": statistics.median(lat_sorted) if lat_sorted else None,
        "latency_ms_p90": pct(0.9),
        "hallucination_item_ids": sorted(
            i for i, v in per_item.items() if v["hallucination_artifacts"]
        ),
        "per_item": per_item,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("raw_run")
    ap.add_argument("--label", default="run")
    ap.add_argument("--out", default=str(HERE / "results.json"))
    ap.add_argument("--compare", help="previously scored results.json to diff against")
    args = ap.parse_args()

    manifest = json.loads(MANIFEST.read_text())
    raw = json.loads(Path(args.raw_run).read_text())
    raw_by_id = {r["id"]: r for r in raw["items"]}
    items = [i for i in manifest["items"] if i["id"] in raw_by_id]

    result = {
        "label": args.label,
        "model": raw["model"],
        "preset": raw["preset"],
        "speedup": raw["speedup"],
        "bias_enabled": raw["biasEnabled"],
        "bias_term_count": raw["biasTermCount"],
        "corpus_items": len(items),
        "whole": score_path(items, raw_by_id, "whole"),
        "live": score_path(items, raw_by_id, "live"),
    }

    w, l = result["whole"], result["live"]
    if w["items_scored"] and l["items_scored"] and w["aggregate_wer"] > 0:
        result["live_vs_whole_relative_wer_gap"] = round(
            (l["aggregate_wer"] - w["aggregate_wer"]) / w["aggregate_wer"], 4
        )

    if args.compare:
        base = json.loads(Path(args.compare).read_text())
        cmp = {}
        for path in ("whole", "live"):
            b, c = base[path], result[path]
            if b["aggregate_wer"]:
                cmp[f"{path}_wer_relative_change"] = round(
                    (c["aggregate_wer"] - b["aggregate_wer"]) / b["aggregate_wer"], 4
                )
            for metric in ("hard_vocab_recall_strict", "hard_vocab_recall_lenient"):
                if b.get(metric) is not None and c.get(metric) is not None:
                    cmp[f"{path}_{metric}_delta"] = round(c[metric] - b[metric], 4)
            base_h = set(b.get("hallucination_item_ids", []))
            cur_h = set(c.get("hallucination_item_ids", []))
            cmp[f"{path}_new_hallucination_items"] = sorted(cur_h - base_h)
            if b.get("latency_ms_p50") and c.get("latency_ms_p50"):
                cmp[f"{path}_latency_p50_relative_change"] = round(
                    (c["latency_ms_p50"] - b["latency_ms_p50"]) / b["latency_ms_p50"], 4
                )
            if b.get("latency_ms_p90") and c.get("latency_ms_p90"):
                cmp[f"{path}_latency_p90_relative_change"] = round(
                    (c["latency_ms_p90"] - b["latency_ms_p90"]) / b["latency_ms_p90"], 4
                )
        result["vs_baseline"] = cmp

    Path(args.out).write_text(json.dumps(result, indent=2))
    for path in ("whole", "live"):
        p = result[path]
        print(
            f"{path}: WER={p['aggregate_wer']} recall_strict={p['hard_vocab_recall_strict']} "
            f"recall_lenient={p['hard_vocab_recall_lenient']} p50={p['latency_ms_p50']}ms "
            f"p90={p['latency_ms_p90']}ms halluc={len(p['hallucination_item_ids'])}"
        )
    if "live_vs_whole_relative_wer_gap" in result:
        print(f"live vs whole relative WER gap: {result['live_vs_whole_relative_wer_gap']}")
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
