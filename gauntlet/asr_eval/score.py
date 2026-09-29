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

Realistic-corpus additions (build_realistic_corpus.py):
  - Items with an empty reference (noise-only recordings) have no WER; they
    are excluded from aggregate WER and instead counted as junk_only_outputs
    when the output is non-empty.
  - trailing_stock_phrase: the hypothesis ends with a stock phrase Whisper
    invents on noise ("thank you", "thanks", "you", "bye", "thanks for
    watching") that the reference does not end with.
  - by_group: per id-prefix group (long, noisy-long, hold, soft-last,
    noise-only, quiet, pn, adv, ...) latency p50/p90/max and, for the live
    path, the distribution of finalize_trace paths.
  - soft_last: the reference's final word must still end the hypothesis
    (strict) or appear in its last three words (lenient).

Usage:
  python3 gauntlet/asr_eval/score.py RAW_RUN.json [--label baseline] \
      [--out gauntlet/asr_eval/results.json] [--compare BASELINE.json] \
      [--manifest gauntlet/asr_eval/corpus_realistic/manifest_realistic.json] \
      [--group PREFIX]

--compare adds relative deltas and the new-hallucination check against a
previously written results file. --group scores only the items whose id
prefix (the id minus its trailing -NNN) equals PREFIX.
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


STOCK_PHRASES = [
    ["thanks", "for", "watching"],
    ["thank", "you"],
    ["thanks"],
    ["bye"],
    ["you"],
]


def group_of(item_id: str) -> str:
    """Id prefix: the id minus its trailing -NNN (noisy-long-01 -> noisy-long)."""
    return re.sub(r"-\d+$", "", item_id)


def percentile(sorted_values, p):
    if not sorted_values:
        return None
    return sorted_values[min(len(sorted_values) - 1, int(round(p * (len(sorted_values) - 1))))]


def trailing_stock_phrase(ref: list[str], hyp: list[str]) -> str | None:
    """The stock phrase the hypothesis ends with but the reference does not."""
    for phrase in STOCK_PHRASES:
        if hyp[-len(phrase):] == phrase and ref[-len(phrase):] != phrase:
            return " ".join(phrase)
    return None


def trace_label(trace: dict) -> str:
    label = trace["path"]
    if trace.get("fallback_reason"):
        label += ":" + trace["fallback_reason"]
    return label


def group_stats(entries):
    """entries: [(ms, finalize_trace or None)] for one group."""
    latencies = sorted(ms for ms, _ in entries)
    stats = {
        "count": len(entries),
        "ms_p50": statistics.median(latencies),
        "ms_p90": percentile(latencies, 0.9),
        "ms_max": latencies[-1],
    }
    paths: dict[str, int] = {}
    for _, trace in entries:
        if trace:
            label = trace_label(trace)
            paths[label] = paths.get(label, 0) + 1
    if paths:
        stats["finalize_paths"] = dict(sorted(paths.items()))
    return stats


def score_path(items, raw_by_id, path_key):
    per_item = {}
    group_entries: dict[str, list] = {}
    junk_ids: list[str] = []
    stock_ids: list[str] = []
    soft_last: dict[str, dict] = {}
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
        # An empty reference (noise-only item) has no WER; its output is
        # judged as junk instead.
        wer = errors / len(ref) if ref else None
        artifacts = hallucination_artifacts(ref, hyp)
        stock = trailing_stock_phrase(ref, hyp)
        if stock:
            stock_ids.append(item["id"])
        if not ref and hyp:
            junk_ids.append(item["id"])
        if group_of(item["id"]) == "soft-last" and ref:
            soft_last[item["id"]] = {
                "strict": hyp[-1:] == ref[-1:],
                "lenient": ref[-1] in hyp[-3:],
            }
        trace = raw_by_id[item["id"]].get("finalize_trace") if path_key == "live" else None
        group_entries.setdefault(group_of(item["id"]), []).append((raw["ms"], trace))
        terms = {}
        for term in item["hard_terms"]:
            s, l = term_recall(term, raw["text"])
            terms[term] = {"strict": s, "lenient": l}
            strict_total += 1
            strict_hits += s
            lenient_hits += l
        if ref:
            total_err += errors
            total_ref += len(ref)
        latencies.append(raw["ms"])
        per_item[item["id"]] = {
            "wer": round(wer, 4) if wer is not None else None,
            "errors": errors,
            "ref_len": len(ref),
            "ms": raw["ms"],
            "hallucination_artifacts": artifacts,
            "hard_terms": terms,
            "text": raw["text"],
            "error": raw.get("error"),
            "trailing_stock_phrase": stock,
            "finalize_trace": trace,
        }
    lat_sorted = sorted(latencies)

    def pct(p):
        return percentile(lat_sorted, p)

    result = {
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
        "junk_only_outputs": len(junk_ids),
        "junk_only_item_ids": sorted(junk_ids),
        "trailing_stock_phrase": len(stock_ids),
        "trailing_stock_phrase_item_ids": sorted(stock_ids),
        "by_group": {g: group_stats(e) for g, e in sorted(group_entries.items())},
    }
    if soft_last:
        result["soft_last"] = {
            "items": len(soft_last),
            "last_word_recall_strict": round(
                sum(v["strict"] for v in soft_last.values()) / len(soft_last), 4
            ),
            "last_word_recall_lenient": round(
                sum(v["lenient"] for v in soft_last.values()) / len(soft_last), 4
            ),
            "missed_item_ids": sorted(i for i, v in soft_last.items() if not v["strict"]),
        }
    return result


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("raw_run")
    ap.add_argument("--label", default="run")
    ap.add_argument("--out", default=str(HERE / "results.json"))
    ap.add_argument("--compare", help="previously scored results.json to diff against")
    ap.add_argument("--manifest", default=str(MANIFEST),
                    help="corpus manifest the raw run was made against "
                         "(default: corpus/manifest.json)")
    ap.add_argument("--group", metavar="PREFIX",
                    help="score only items whose id prefix equals PREFIX (e.g. noisy-long)")
    args = ap.parse_args()

    manifest = json.loads(Path(args.manifest).read_text())
    raw = json.loads(Path(args.raw_run).read_text())
    raw_by_id = {r["id"]: r for r in raw["items"]}
    items = [i for i in manifest["items"] if i["id"] in raw_by_id]
    if args.group:
        items = [i for i in items if group_of(i["id"]) == args.group]

    result = {
        "label": args.label,
        "model": raw["model"],
        "preset": raw["preset"],
        "speedup": raw["speedup"],
        "bias_enabled": raw["biasEnabled"],
        "bias_term_count": raw["biasTermCount"],
        "corpus_items": len(items),
        **({"group": args.group} if args.group else {}),
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
    for path in ("whole", "live"):
        p = result[path]
        if p["junk_only_outputs"] or p["trailing_stock_phrase"]:
            print(
                f"{path}: junk_only_outputs={p['junk_only_outputs']} "
                f"trailing_stock_phrase={p['trailing_stock_phrase']} "
                f"({', '.join(p['trailing_stock_phrase_item_ids'])})"
            )
        if "soft_last" in p:
            sl = p["soft_last"]
            print(
                f"{path}: soft-last last-word recall strict={sl['last_word_recall_strict']} "
                f"lenient={sl['last_word_recall_lenient']} missed={sl['missed_item_ids']}"
            )
    for group, g in result["live"]["by_group"].items():
        paths = " ".join(f"{k}={v}" for k, v in g.get("finalize_paths", {}).items())
        print(
            f"live finalize [{group}] n={g['count']} p50={g['ms_p50']}ms "
            f"p90={g['ms_p90']}ms max={g['ms_max']}ms {paths}"
        )
    if "live_vs_whole_relative_wer_gap" in result:
        print(f"live vs whole relative WER gap: {result['live_vs_whole_relative_wer_gap']}")
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
