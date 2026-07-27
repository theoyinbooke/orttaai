#!/usr/bin/env python3
"""Eval harness for the local LLM polish stage (LocalLLMTextProcessor).

Runs every case in gauntlet/golden_set.json through the SAME pipeline the app
ships:

  1. The prompt template is extracted verbatim from
     Orttaai/Core/Transcription/LocalLLMTextProcessor.swift (makePolishPrompt),
     so the eval prompt is char-identical to production modulo the dynamic
     app-context line (eval always uses "Target app context: unknown", which is
     exactly what production sends when no target app is known).
  2. Production defaults (model, timeout, max chars) are parsed from
     Orttaai/Data/AppSettings.swift.
  3. Generation parameters mirror LocalLLMTextProcessor.process /
     OllamaClient.generate: temperature 0, think=false,
     num_predict = max(24, min(200, chars/2 + 24)) with the OllamaClient floor
     of 32, keep_alive "5m", stream=false.
  4. The sanitizer mirrors LocalLLMTextProcessor.sanitizePolishOutput:
     code-fence stripping, known-preamble stripping, 0.55x..1.8x+24 length
     band, and the digit/currency preservation check — a rejected response
     falls back to the raw (unpolished) text, exactly like the app.
  5. Inputs shorter than 8 chars or longer than localLLMPolishMaxChars skip
     polish entirely (output = raw), exactly like the app.

Note: production optionally runs SpokenFormattingFormatter after polish when
spokenFormattingEnabled is on. The golden set's raw text is post-rule-based
(spoken formatting already resolved), so that pass is a no-op for these cases
and is not replicated here.

A case PASSES only if all of these hold (see gauntlet/README.md scoring
intent):
  - digits_verbatim:   every digit/currency token in raw survives verbatim
  - propernouns_verbatim: mid-sentence capitalized tokens, camelCase/ALLCAPS
                       identifiers, @mentions and #channels survive verbatim
  - no_markers:        no answer/refusal/preamble phrasing absent from raw
  - no_fabrication:    every output word already occurs in raw or expected
  - no_lost_content:   every word of expected occurs in the output
  - fillers_removed:   words the golden polish dropped (disfluencies, false
                       starts) do not survive in the output
  - no_runaway:        no word repeated beyond max(raw, expected) counts
  - linebreaks_kept:   newline count matches expected
  - length_band:       final output within the production sanitizer band
  - terminal_punct:    if expected ends a sentence (. ! ?), the output must
                       end with sentence punctuation too (a "?" stays a
                       question mark: questions must remain questions)

Word-level checks compare lowercase, punctuation-stripped, apostrophe-
normalized tokens, so comma-vs-period and capitalization free variation
(allowed by the README) never fails a case, while added, lost, or unremoved
words do.

Usage:
  python3 gauntlet/polish_eval.py                 # full run, writes eval_results.json
  python3 gauntlet/polish_eval.py --model qwen3.5:0.8b --no-write
  python3 gauntlet/polish_eval.py --ids disfl-001 question-015
"""

from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
import time
import urllib.error
import urllib.request
from collections import Counter
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PROCESSOR_SWIFT = REPO / "Orttaai/Core/Transcription/LocalLLMTextProcessor.swift"
SETTINGS_SWIFT = REPO / "Orttaai/Data/AppSettings.swift"
GOLDEN_SET = REPO / "gauntlet/golden_set.json"
RESULTS = REPO / "gauntlet/eval_results.json"

OLLAMA_URL = "http://127.0.0.1:11434"

# ---------------------------------------------------------------------------
# Production parity: prompt + settings extracted from the Swift sources
# ---------------------------------------------------------------------------


def extract_prompt_template() -> str:
    """Pull the literal prompt out of makePolishPrompt in the Swift source."""
    src = PROCESSOR_SWIFT.read_text()
    fn = re.search(r"func makePolishPrompt\(.*?\n    \}", src, re.S)
    if not fn:
        sys.exit("FATAL: could not locate makePolishPrompt in the Swift source")
    body = fn.group(0)
    lit = re.search(r'return """\n(.*?)\n(\s*)"""', body, re.S)
    if not lit:
        sys.exit("FATAL: could not extract the prompt string literal")
    indent = lit.group(2)
    lines = lit.group(1).split("\n")
    # Swift multiline literals strip the closing-quote indentation from every line.
    stripped = [ln[len(indent):] if ln.startswith(indent) else ln for ln in lines]
    return "\n".join(stripped)


def render_prompt(template: str, text: str) -> str:
    prompt = template.replace("\\(contextLine)", "Target app context: unknown")
    prompt = prompt.replace("\\(text)", text)
    if "\\(" in prompt:
        sys.exit("FATAL: unresolved interpolation in prompt template")
    return prompt


def extract_settings_defaults() -> dict:
    src = SETTINGS_SWIFT.read_text()

    def default_for(key: str) -> str:
        m = re.search(
            r'@AppStorage\("%s"\)\s+var\s+\w+:\s*\w+\s*=\s*(.+)$' % re.escape(key),
            src,
            re.M,
        )
        if not m:
            sys.exit(f"FATAL: could not find @AppStorage default for {key}")
        return m.group(1).strip().strip('"')

    return {
        "model": default_for("localLLMPolishModel"),
        "timeout_ms": int(default_for("localLLMPolishTimeoutMs")),
        "max_chars": int(default_for("localLLMPolishMaxChars")),
    }


def assert_sanitizer_parity() -> None:
    """Fail loudly if the Swift sanitizer constants drift from this mirror."""
    src = PROCESSOR_SWIFT.read_text()
    for needle in ["0.55", "1.8", "+ 24", "corrected transcript:", "requiredNumberTokens"]:
        if needle not in src:
            sys.exit(
                f"FATAL: sanitizer parity check failed — {needle!r} not found in "
                f"{PROCESSOR_SWIFT.name}; update polish_eval.py to match production"
            )


def effective_timeout_ms(requested: int, model: str) -> int:
    """Mirror of LocalLLMTextProcessor.effectiveTimeoutMs."""
    lower = model.lower()
    if "qwen3.5:0.8b" in lower:
        floor = 1_300
    elif "qwen3.5:2b" in lower:
        floor = 1_400
    elif "qwen3.5:4b" in lower:
        floor = 1_500
    elif "gemma4:e2b" in lower:
        floor = 2_500
    elif "gemma4:e4b" in lower:
        floor = 3_000
    else:
        floor = 600
    return max(requested, floor)


# ---------------------------------------------------------------------------
# Sanitizer: mirror of LocalLLMTextProcessor.sanitizePolishOutput
# ---------------------------------------------------------------------------

KNOWN_PREAMBLES = [
    "corrected transcript:",
    "corrected text:",
    "revised transcript:",
    "revised text:",
]

DIGIT_TOKEN_RE = re.compile(r"[0-9][0-9.,:/\-]*[0-9]|[0-9]")
CURRENCY_RE = re.compile(r"[$€£₦]")


def number_tokens(text: str) -> list[str]:
    """Mirror of the digit/currency token extraction used by the sanitizer."""
    return DIGIT_TOKEN_RE.findall(text) + CURRENCY_RE.findall(text)


GLUED_TIME_RE = re.compile(r"([0-9][0-9:.]*)(am|pm)", re.IGNORECASE)


def repair_split_time_tokens(value: str, original: str) -> str:
    """Mirror of LocalLLMTextProcessor.repairSplitTimeTokens."""
    for match in GLUED_TIME_RE.finditer(original):
        token = match.group(0)
        if token in value:
            continue
        digits = re.escape(match.group(1))
        letter = match.group(2)[0]
        cls = f"[{letter.lower()}{letter.upper()}]"
        # "3 PM" and "3 p.m." both collapse back to "3pm"; the dotted
        # alternative must not swallow a sentence-ending period.
        split_re = re.compile(rf"{digits}\s*(?:{cls}\.[mM]\.|{cls}[mM])")
        value = split_re.sub(token, value, count=1)
    return value


def sanitize_polish_output(candidate: str, original: str) -> str | None:
    value = candidate.replace("\r\n", "\n").strip()

    if value.startswith("```"):
        value = value.replace("```", "").strip()

    # List formatting the speaker didn't dictate is stripped.
    for marker in ("- ", "* ", "• "):
        if value.startswith(marker) and not original.startswith(marker):
            value = value[len(marker):].strip()
            break

    # Typographic quotes are normalized back to ASCII unless dictated.
    if "’" not in original and "‘" not in original:
        value = value.replace("’", "'").replace("‘", "'")
    if "“" not in original and "”" not in original:
        value = value.replace("“", '"').replace("”", '"')

    # A response wrapped in quotes the speaker never dictated is stripped.
    if len(value) >= 2 and value.startswith('"') and value.endswith('"') and not original.startswith('"'):
        value = value[1:-1].strip()

    # Glued time tokens ("3pm") the model split/recased ("3 PM") are stitched
    # back — dictated times must stay verbatim.
    value = repair_split_time_tokens(value, original)

    lower = value.lower()
    for preamble in KNOWN_PREAMBLES:
        if lower.startswith(preamble):
            value = value[len(preamble):].strip()
            break

    if not value:
        return None

    original_count = max(1, len(original))
    min_allowed = int(original_count * 0.55)
    max_allowed = int(original_count * 1.8) + 24
    if not (min_allowed <= len(value) <= max_allowed):
        return None

    # Digit/currency preservation: every number token of the input must
    # survive verbatim (count-aware), or the polish is rejected.
    if Counter(number_tokens(original)) - Counter(number_tokens(value)):
        return None

    return value


# ---------------------------------------------------------------------------
# Ollama call: mirror of OllamaClient.generate as invoked by the processor
# ---------------------------------------------------------------------------


def ollama_generate(model: str, prompt: str, num_predict: int, timeout_ms: int) -> tuple[str | None, float, str | None]:
    payload = {
        "model": model,
        "prompt": prompt.strip(),
        "stream": False,
        "options": {
            "temperature": 0,
            "num_predict": max(32, min(16_000, num_predict)),
        },
        "keep_alive": "5m",
        "think": False,
    }
    req = urllib.request.Request(
        OLLAMA_URL + "/api/generate",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    started = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=timeout_ms / 1000.0) as resp:
            body = json.load(resp)
        return body.get("response", ""), time.monotonic() - started, None
    except Exception as err:  # timeout, connection refused, HTTP error
        return None, time.monotonic() - started, f"{type(err).__name__}: {err}"


# ---------------------------------------------------------------------------
# Judge
# ---------------------------------------------------------------------------

WORD_RE = re.compile(r"[A-Za-z0-9@#'’][A-Za-z0-9@#'’._/:\-]*")

REFUSAL_ANSWER_MARKERS = [
    "i can't help",
    "i cannot help",
    "i can't assist",
    "i cannot assist",
    "i'm sorry",
    "i am sorry",
    "i apologize",
    "as an ai",
    "as a language model",
    "i'm unable to",
    "i am unable to",
    "i'm not able to",
    "here is the",
    "here's the",
    "here is your",
    "sure, here",
    "sure! here",
    "certainly, here",
    "certainly! here",
    "corrected transcript",
    "corrected text",
    "revised transcript",
    "the corrected version",
    "i hope this helps",
    "let me know if",
    "the answer is",
    "great question",
]


def norm_words(text: str) -> list[str]:
    """Lowercase word tokens with edge punctuation and apostrophes removed.

    Comma/period/capitalization/hyphenation variation disappears; added,
    lost, or unremoved words do not. Digit-bearing tokens keep hyphens (a
    phone number must not split).
    """
    words = []
    for match in WORD_RE.finditer(text.replace("’", "'")):
        tok = match.group(0)
        parts = [tok] if any(ch.isdigit() for ch in tok) else tok.split("-")
        for part in parts:
            w = part.strip(".,;:!?'\"-_/").replace("'", "").lower()
            if w:
                words.append(w)
    return words


SENTENCE_ENDERS = (".", "!", "?", ")", '"')


def _proper_noun_tokens(raw: str) -> list[str]:
    """Tokens that must survive verbatim: mid-sentence Capitalized words,
    camelCase/ALLCAPS identifiers, @mentions, #channels."""
    required = []
    sentence_start = True
    for match in WORD_RE.finditer(raw):
        tok = match.group(0).rstrip(".,;:!?'’\"")
        starts_sentence = sentence_start
        # Establish whether the *next* token starts a sentence.
        trailing = raw[match.end():match.end() + 2]
        sentence_start = tok.endswith((".", "!", "?")) or trailing.startswith(("\n",)) or any(
            trailing.startswith(p) for p in (". ", "! ", "? ", ".\n", "!\n", "?\n")
        )
        if not tok:
            continue
        if tok.startswith(("@", "#")):
            required.append(tok)
            continue
        has_inner_upper = any(c.isupper() for c in tok[1:])
        if has_inner_upper:  # camelCase, ALLCAPS, OAuth, PR — never sentence-cased
            required.append(tok)
            continue
        if (
            tok[0].isupper()
            and not starts_sentence
            and tok not in ("I",)
            and not tok.startswith("I'")
            and tok.lower() not in ("um", "uh", "er", "ah")  # capitalized fillers
        ):
            required.append(tok)
    return required


def judge(case: dict, output: str) -> dict:
    raw = case["raw"]
    expected = case["expected"]
    checks: dict[str, bool] = {}
    reasons: list[str] = []

    # 1. digits / currency verbatim
    missing_numbers = Counter(number_tokens(raw)) - Counter(number_tokens(output))
    checks["digits_verbatim"] = not missing_numbers
    if missing_numbers:
        reasons.append(f"lost number tokens: {sorted(missing_numbers)}")

    # 2. proper nouns verbatim (case-sensitive substring survival)
    missing_propn = [t for t in _proper_noun_tokens(raw) if t not in output]
    checks["propernouns_verbatim"] = not missing_propn
    if missing_propn:
        reasons.append(f"lost proper nouns: {sorted(set(missing_propn))}")

    # 3. refusal / answer / preamble markers not present in raw
    out_lower = output.lower()
    raw_lower = raw.lower()
    hit_markers = [m for m in REFUSAL_ANSWER_MARKERS if m in out_lower and m not in raw_lower]
    checks["no_markers"] = not hit_markers
    if hit_markers:
        reasons.append(f"answer/refusal/preamble markers: {hit_markers}")

    raw_words = Counter(norm_words(raw))
    exp_words = Counter(norm_words(expected))
    out_words = Counter(norm_words(output))

    # 4. fabrication: every output word must already exist in raw or expected
    fabricated = [w for w in out_words if w not in raw_words and w not in exp_words]
    checks["no_fabrication"] = not fabricated
    if fabricated:
        reasons.append(f"fabricated words: {sorted(fabricated)}")

    # 5. lost content: every expected word must appear in the output
    lost = exp_words - out_words
    checks["no_lost_content"] = not lost
    if lost:
        reasons.append(f"lost content words: {sorted(lost)}")

    # 6. fillers/false starts the golden polish dropped must be dropped.
    # Connectives are exempt: at a run-on split, "..., and I think" versus
    # "... . I think" is free variation the README explicitly allows.
    CONNECTIVES = {"and", "but", "so", "or"}
    dropped = (raw_words - exp_words)
    for conn in CONNECTIVES:
        dropped.pop(conn, None)
    survived = {w: out_words[w] - exp_words[w] for w in dropped if out_words[w] > exp_words[w]}
    checks["fillers_removed"] = not survived
    if survived:
        reasons.append(f"unremoved disfluencies/false starts: {sorted(survived)}")

    # 7. runaway repetition
    runaway = [w for w, c in out_words.items() if c > max(raw_words[w], exp_words[w])]
    checks["no_runaway"] = not runaway
    if runaway:
        reasons.append(f"repeated words beyond input: {sorted(runaway)}")

    # 8. line breaks preserved
    checks["linebreaks_kept"] = output.count("\n") == expected.count("\n")
    if not checks["linebreaks_kept"]:
        reasons.append(
            f"line-break count {output.count(chr(10))} != expected {expected.count(chr(10))}"
        )

    # 9. length band (mirrors the production sanitizer, incl. raw fallback)
    original = raw.strip()
    lo = int(max(1, len(original)) * 0.55)
    hi = int(max(1, len(original)) * 1.8) + 24
    checks["length_band"] = lo <= len(output) <= hi
    if not checks["length_band"]:
        reasons.append(f"length {len(output)} outside band [{lo}, {hi}]")

    # 10. terminal punctuation: a finished sentence stays finished, a question
    # stays a question.
    exp_end = expected.rstrip()[-1:] if expected.strip() else ""
    out_end = output.rstrip()[-1:] if output.strip() else ""
    if exp_end == "?":
        checks["terminal_punct"] = out_end == "?"
    elif exp_end in (".", "!"):
        checks["terminal_punct"] = out_end in (".", "!", "?")
    else:
        checks["terminal_punct"] = True
    if not checks["terminal_punct"]:
        reasons.append(f"terminal punctuation {out_end!r} vs expected {exp_end!r}")

    return {"pass": all(checks.values()), "checks": checks, "reasons": reasons}


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------


def run_case(case: dict, template: str, model: str, timeout_ms: int, max_chars: int) -> dict:
    raw = case["raw"]
    normalized = raw.strip()

    result = {
        "id": case["id"],
        "category": case["category"],
        "raw": raw,
        "expected": case["expected"],
    }

    # Mirror the processor's skip gates: output stays the rule-based text.
    if len(normalized) < 8 or len(normalized) > max_chars:
        result.update(
            model_response=None,
            output=raw,
            polish_applied=False,
            skip_reason="below-min-chars" if len(normalized) < 8 else "above-max-chars",
            latency_ms=None,
        )
    else:
        prompt = render_prompt(template, normalized)
        num_predict = max(24, min(200, len(normalized) // 2 + 24))
        response, elapsed, error = ollama_generate(model, prompt, num_predict, timeout_ms)
        result["latency_ms"] = round(elapsed * 1000, 1)
        if response is None:
            result.update(model_response=None, output=raw, polish_applied=False, skip_reason=f"request-failed: {error}")
        else:
            sanitized = sanitize_polish_output(response, normalized)
            if sanitized is None:
                result.update(model_response=response, output=raw, polish_applied=False, skip_reason="sanitizer-rejected")
            else:
                result.update(model_response=response, output=sanitized, polish_applied=True, skip_reason=None)

    result.update(judge(case, result["output"]))
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", help="override the production default model")
    parser.add_argument("--timeout-ms", type=int, help="override the production default timeout")
    parser.add_argument("--max-chars", type=int, help="override the production default max chars")
    parser.add_argument("--ids", nargs="*", help="run only these case ids")
    parser.add_argument("--no-write", action="store_true", help="do not write eval_results.json")
    parser.add_argument("--fails-only", action="store_true", help="print only failing cases")
    args = parser.parse_args()

    assert_sanitizer_parity()
    template = extract_prompt_template()
    defaults = extract_settings_defaults()

    model = args.model or defaults["model"]
    timeout_ms = effective_timeout_ms(args.timeout_ms or defaults["timeout_ms"], model)
    max_chars = args.max_chars or defaults["max_chars"]

    cases = json.loads(GOLDEN_SET.read_text())["cases"]
    if args.ids:
        cases = [c for c in cases if c["id"] in set(args.ids)]

    # Warm the model the same way the app's prewarm pass does at launch.
    ollama_generate(model, render_prompt(template, "hello world this is a warm up"), 32, 60_000)

    results = []
    for i, case in enumerate(cases):
        res = run_case(case, template, model, timeout_ms, max_chars)
        results.append(res)
        status = "PASS" if res["pass"] else "FAIL"
        if not args.fails_only or not res["pass"]:
            lat = f'{res["latency_ms"]:7.0f}ms' if res.get("latency_ms") else "   skip  "
            print(f'[{i + 1:3}/{len(cases)}] {status} {lat} {res["id"]:12} {"; ".join(res["reasons"])[:110]}')

    total = len(results)
    passed = sum(r["pass"] for r in results)
    by_cat: dict[str, dict] = {}
    for r in results:
        c = by_cat.setdefault(r["category"], {"total": 0, "passed": 0, "failed_ids": []})
        c["total"] += 1
        if r["pass"]:
            c["passed"] += 1
        else:
            c["failed_ids"].append(r["id"])
    for c in by_cat.values():
        c["pass_rate"] = round(c["passed"] / c["total"], 4)

    latencies = sorted(r["latency_ms"] for r in results if r.get("latency_ms") is not None)

    def pct(p: float) -> float | None:
        if not latencies:
            return None
        return round(latencies[min(len(latencies) - 1, int(round(p * (len(latencies) - 1))))], 1)

    summary = {
        "model": model,
        "timeout_ms": timeout_ms,
        "max_chars": max_chars,
        "prompt_template": template,
        "prompt_source": str(PROCESSOR_SWIFT.relative_to(REPO)),
        "endpoint": OLLAMA_URL,
        "total": total,
        "passed": passed,
        "pass_rate": round(passed / total, 4) if total else None,
        "categories": by_cat,
        "latency_ms": {
            "count": len(latencies),
            "p50": pct(0.50),
            "p90": pct(0.90),
            "p99": pct(0.99),
            "mean": round(statistics.fmean(latencies), 1) if latencies else None,
            "max": latencies[-1] if latencies else None,
        },
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "notes": (
            "Prompt extracted verbatim from LocalLLMTextProcessor.makePolishPrompt "
            "with the dynamic app-context line fixed to 'unknown'. Sanitizer, skip "
            "gates, generation options, and timeout mirror production. "
            "SpokenFormattingFormatter post-pass not replicated: golden raw text is "
            "post-rule-based, so it is a no-op for these cases."
        ),
    }

    print()
    print(f'overall: {passed}/{total} = {summary["pass_rate"]:.1%}   '
          f'p50={summary["latency_ms"]["p50"]}ms p90={summary["latency_ms"]["p90"]}ms')
    for cat in sorted(by_cat):
        c = by_cat[cat]
        print(f'  {cat:18} {c["passed"]:3}/{c["total"]:<3} {c["pass_rate"]:.0%}  fails: {", ".join(c["failed_ids"])}')

    if not args.no_write and not args.ids:
        RESULTS.write_text(json.dumps({"summary": summary, "cases": results}, indent=2) + "\n")
        print(f"\nwrote {RESULTS}")


if __name__ == "__main__":
    main()
