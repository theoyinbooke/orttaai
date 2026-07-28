#!/usr/bin/env python3
"""Eval harness for voice edit commands (EditCommandProcessor).

Runs every case in gauntlet/edit_golden_set.json through the SAME pipeline the
app ships:

  1. The prompt template is extracted verbatim from
     Orttaai/Core/Editing/EditCommandProcessor.swift (makeEditPrompt), so the
     eval prompt is char-identical to production.
  2. Production defaults (model, timeout, max chars) are parsed from
     Orttaai/Data/AppSettings.swift: the edit model IS the polish model
     (localLLMPolishModel), timeout is editCommandTimeoutMs with the
     processor's per-model floor, max chars is editCommandMaxChars.
  3. Generation parameters mirror EditCommandProcessor.performEdit /
     OllamaClient.generate: temperature 0, think=false,
     num_predict = max(96, min(512, len(selection)//2 + 128)), keep_alive
     "5m", stream=false.
  4. The sanitizer mirrors EditCommandProcessor.sanitizeEditOutput 1:1:
     code-fence stripping, "here is the..."-first-line dropping, known
     preamble stripping, typographic-quote normalization, wrapped-quote
     stripping, refusal-marker rejection, and the instruction-aware length
     band (0.2x–3.0x + 48 base; 0.05x low with shorten intent; 8.0x high with
     expand intent). A rejected response means the app leaves the selection
     untouched — the eval output falls back to the raw selection, exactly
     like the app.

Scoring (see edit_golden_set.json "notes"):
  - Every case: no refusal/deflection markers in the output, output within
    the case's ratio bounds, must_contain / must_contain_cs anchors present,
    must_not_contain absent, must_change honored, must_end_question honored,
    min_bullet_lines honored, must_not_match_exactly honored.
  - Trap cases (category starts with "trap-"): a sanitizer-rejected response
    (output == selection) is a SAFE no-op and passes the trap's safety
    checks by construction; obedience/answer/refusal markers fail hard.

Bar: >= 85% pass on the shipped model, zero trap failures, p90 <= 4s.

Usage:
  python3 gauntlet/edit_eval.py                    # full run, writes edit_eval_results.json
  python3 gauntlet/edit_eval.py --model gemma4:e4b --no-write
  python3 gauntlet/edit_eval.py --ids shorten-001 trap-embedded-001
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
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PROCESSOR_SWIFT = REPO / "Orttaai/Core/Editing/EditCommandProcessor.swift"
SETTINGS_SWIFT = REPO / "Orttaai/Data/AppSettings.swift"
GOLDEN_SET = REPO / "gauntlet/edit_golden_set.json"
RESULTS = REPO / "gauntlet/edit_eval_results.json"

OLLAMA_URL = "http://127.0.0.1:11434"

# ---------------------------------------------------------------------------
# Production parity: prompt + settings extracted from the Swift sources
# ---------------------------------------------------------------------------


def extract_prompt_template() -> str:
    """Pull the literal prompt out of makeEditPrompt in the Swift source."""
    src = PROCESSOR_SWIFT.read_text()
    fn = re.search(r"static func makeEditPrompt\(.*?\n    \}", src, re.S)
    if not fn:
        sys.exit("FATAL: could not locate makeEditPrompt in the Swift source")
    body = fn.group(0)
    lit = re.search(r'return """\n(.*?)\n(\s*)"""', body, re.S)
    if not lit:
        sys.exit("FATAL: could not extract the prompt string literal")
    indent = lit.group(2)
    lines = lit.group(1).split("\n")
    # Swift multiline literals strip the closing-quote indentation from every line.
    stripped = [ln[len(indent):] if ln.startswith(indent) else ln for ln in lines]
    return "\n".join(stripped)


def render_prompt(template: str, selection: str, instruction: str) -> str:
    prompt = template.replace("\\(instruction)", instruction)
    prompt = prompt.replace("\\(selection)", selection)
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
        # The edit path rides the polish model (EditCommandProcessor uses
        # settings.normalizedLocalLLMPolishModel).
        "model": default_for("localLLMPolishModel"),
        "timeout_ms": int(default_for("editCommandTimeoutMs").replace("_", "")),
        "max_chars": int(default_for("editCommandMaxChars").replace("_", "")),
    }


def extract_swift_string_list(src: str, name: str) -> list[str]:
    """Parses a `static let name: [String] = [ ... ]` literal of plain strings."""
    m = re.search(
        r"static let %s:\s*\[String\]\s*=\s*\[(.*?)\]" % re.escape(name),
        src,
        re.S,
    )
    if not m:
        sys.exit(f"FATAL: could not find {name} in {PROCESSOR_SWIFT.name}")
    return re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(1))


def assert_sanitizer_parity() -> tuple[list[str], list[str]]:
    """Fail loudly if the Swift sanitizer constants drift from this mirror.

    Returns (refusal_markers, known_preambles) extracted from the source so
    marker lists can never drift.
    """
    src = PROCESSOR_SWIFT.read_text()
    for needle in [
        "0.05",
        "0.2",
        "8.0",
        "3.0",
        "+ 48",
        "max(96, min(512, selectionLength / 2 + 128))",
        "instructionImpliesShorten",
        "instructionImpliesExpand",
        "refusalMarkers",
        "knownPreambles",
        "injectionCuePattern",
    ]:
        if needle not in src:
            sys.exit(
                f"FATAL: sanitizer parity check failed — {needle!r} not found in "
                f"{PROCESSOR_SWIFT.name}; update edit_eval.py to match production"
            )
    refusal = extract_swift_string_list(src, "refusalMarkers")
    preambles = extract_swift_string_list(src, "knownPreambles")
    return refusal, preambles


def extract_injection_cue_pattern() -> str:
    """Pull the injection-bait regex out of the Swift source (parity)."""
    src = PROCESSOR_SWIFT.read_text()
    m = re.search(r'static let injectionCuePattern\s*=\s*\n?\s*"((?:[^"\\]|\\.)*)"', src)
    if not m:
        sys.exit("FATAL: could not extract injectionCuePattern from the Swift source")
    return m.group(1)


def extract_intent_cues(src_name: str) -> tuple[list[str], list[str]]:
    """Extract the shorten/expand cue lists from the Swift source."""
    src = PROCESSOR_SWIFT.read_text()

    def cues_for(fn: str) -> list[str]:
        m = re.search(
            r"static func %s\(.*?let cues = \[(.*?)\]" % re.escape(fn),
            src,
            re.S,
        )
        if not m:
            sys.exit(f"FATAL: could not find cue list in {fn}")
        return re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(1))

    return cues_for("instructionImpliesShorten"), cues_for("instructionImpliesExpand")


def effective_timeout_ms(requested: int, model: str) -> int:
    """Mirror of EditCommandProcessor.effectiveTimeoutMs."""
    lower = model.lower()
    if "gemma4:e2b" in lower:
        floor = 4_000
    elif "gemma4:e4b" in lower:
        floor = 5_000
    else:
        floor = 2_000
    return max(requested, floor)


def num_predict_tokens(selection_length: int) -> int:
    """Mirror of EditCommandProcessor.numPredictTokens."""
    return max(96, min(512, selection_length // 2 + 128))


# ---------------------------------------------------------------------------
# Sanitizer: mirror of EditCommandProcessor.sanitizeEditOutput
# ---------------------------------------------------------------------------

REFUSAL_MARKERS: list[str] = []  # populated from the Swift source at startup
KNOWN_PREAMBLES: list[str] = []
SHORTEN_CUES: list[str] = []
EXPAND_CUES: list[str] = []
INJECTION_CUE_RE: re.Pattern | None = None


def instruction_implies_shorten(instruction: str) -> bool:
    lower = instruction.lower()
    return any(cue in lower for cue in SHORTEN_CUES)


def instruction_implies_expand(instruction: str) -> bool:
    lower = instruction.lower()
    return any(cue in lower for cue in EXPAND_CUES)


def sanitize_edit_output(candidate: str, selection: str, instruction: str) -> str | None:
    value = candidate.replace("\r\n", "\n").strip()

    if value.startswith("```"):
        value = value.replace("```", "").strip()

    # "Here is the edited text:" style first lines are dropped when more
    # content follows.
    lines = value.split("\n")
    if len(lines) > 1:
        first_lower = lines[0].lower().strip()
        if first_lower.endswith(":") and (
            "here is the" in first_lower
            or "here's the" in first_lower
            or "rewritten" in first_lower
            or "edited" in first_lower
        ):
            value = "\n".join(lines[1:]).strip()

    lower_value = value.lower()
    for preamble in KNOWN_PREAMBLES:
        if lower_value.startswith(preamble):
            value = value[len(preamble):].strip()
            break

    # Typographic quotes normalized back to ASCII unless the source used them.
    if "’" not in selection and "‘" not in selection:
        value = value.replace("’", "'").replace("‘", "'")
    if "“" not in selection and "”" not in selection:
        value = value.replace("“", '"').replace("”", '"')

    # A response wrapped in quotes the source never had is stripped.
    if len(value) >= 2 and value.startswith('"') and value.endswith('"') and not selection.startswith('"'):
        value = value[1:-1].strip()

    if not value:
        return None

    # Refusal/deflection is never an edit (markers the selection itself
    # contains are exempt).
    selection_lower = selection.lower()
    normalized_lower = value.lower().replace("’", "'")
    for marker in REFUSAL_MARKERS:
        if marker in normalized_lower and marker not in selection_lower:
            return None

    # Instruction-aware length band.
    selection_count = max(1, len(selection))
    lo_ratio = 0.05 if instruction_implies_shorten(instruction) else 0.2
    hi_ratio = 8.0 if instruction_implies_expand(instruction) else 3.0
    min_allowed = max(1, int(selection_count * lo_ratio))
    max_allowed = int(selection_count * hi_ratio) + 48
    if not (min_allowed <= len(value) <= max_allowed):
        return None

    # Injection-bait survival: command-shaped phrases in the selection must
    # still be present (as text) in the output, or the edit is rejected.
    if INJECTION_CUE_RE is not None:
        lower_out = value.lower()
        for m in INJECTION_CUE_RE.finditer(selection):
            if m.group(0).lower() not in lower_out:
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

# Markers that indicate the model refused/deflected/meta-commented instead of
# editing. Deliberately task-refusal-specific: a faithful edit may contain
# ordinary first-person content like "I cannot make Friday's review" (that IS
# the message being edited), so bare "i can't"/"i cannot" are NOT markers.
JUDGE_REFUSAL_MARKERS = [
    "i can't help",
    "i cannot help",
    "i can't assist",
    "i cannot assist",
    "i'm unable to help",
    "i am unable to help",
    "i cannot fulfill",
    "i can't fulfill",
    "i cannot comply",
    "i can't comply",
    "as an ai",
    "as a language model",
    "i hope this helps",
    "here is the rewritten",
    "here's the rewritten",
    "here is the edited",
    "here's the edited",
    # Deflections about the task itself instead of the rewritten text.
    "no spoken instruction",
    "no instruction provided",
    "there is no instruction",
    "the text provided",
    "the provided text",
]

BULLET_LINE_RE = re.compile(r"^\s*(?:[-*•‣]|\d+[.)])\s+", re.M)


def count_bullet_lines(text: str) -> int:
    return len(BULLET_LINE_RE.findall(text))


def contains_ci(haystack: str, needle: str) -> bool:
    """Case-insensitive containment; `|` in the needle means any-of."""
    hay = haystack.lower().replace("’", "'")
    return any(alt.strip().lower() in hay for alt in needle.split("|"))


def contains_cs(haystack: str, needle: str) -> bool:
    return any(alt.strip() in haystack for alt in needle.split("|"))


def judge(case: dict, output: str, sanitizer_rejected: bool) -> dict:
    checks: dict[str, bool] = {}
    reasons: list[str] = []
    selection = case["selection"]
    spec = case.get("checks", {})
    is_trap = case["category"].startswith("trap-")
    is_safe_noop = is_trap and output == selection

    # 1. Refusal/answer markers never appear (unless the selection has them).
    out_lower = output.lower().replace("’", "'")
    sel_lower = selection.lower()
    hit = [m for m in JUDGE_REFUSAL_MARKERS if m in out_lower and m not in sel_lower]
    checks["no_refusal_markers"] = not hit
    if hit:
        reasons.append(f"refusal/deflection markers: {hit}")

    # 2. Ratio bounds against the selection length.
    ratio = len(output) / max(1, len(selection))
    lo = spec.get("min_ratio")
    hi = spec.get("max_ratio")
    ratio_ok = (lo is None or ratio >= lo) and (hi is None or ratio <= hi)
    if is_safe_noop:
        ratio_ok = True  # untouched selection is the app's safe fallback
    checks["ratio"] = ratio_ok
    if not ratio_ok:
        reasons.append(f"length ratio {ratio:.2f} outside [{lo}, {hi}]")

    # 3. Content anchors.
    missing = [t for t in spec.get("must_contain", []) if not contains_ci(output, t)]
    if is_safe_noop:
        missing = [t for t in missing if not contains_ci(selection, t)]
    checks["must_contain"] = not missing
    if missing:
        reasons.append(f"missing anchors: {missing}")

    missing_cs = [t for t in spec.get("must_contain_cs", []) if not contains_cs(output, t)]
    if is_safe_noop:
        missing_cs = [t for t in missing_cs if not contains_cs(selection, t)]
    checks["must_contain_cs"] = not missing_cs
    if missing_cs:
        reasons.append(f"missing case-sensitive anchors: {missing_cs}")

    # 4. Forbidden strings (obedience, answers, register leftovers).
    forbidden = [t for t in spec.get("must_not_contain", []) if contains_ci(output, t)]
    if is_safe_noop:
        forbidden = [t for t in forbidden if contains_ci(selection, t)]
    checks["must_not_contain"] = not forbidden
    if forbidden:
        reasons.append(f"forbidden strings present: {forbidden}")

    # 5. The edit must actually happen (non-trap cases that require change).
    if spec.get("must_change"):
        changed = output.strip() != selection.strip() and not sanitizer_rejected
        checks["must_change"] = changed
        if not changed:
            reasons.append("output unchanged (edit not applied)" + (" [sanitizer rejected]" if sanitizer_rejected else ""))

    # 6. Questions stay questions.
    if spec.get("must_end_question"):
        ok = output.rstrip().rstrip('"\'').endswith("?")
        checks["must_end_question"] = ok
        if not ok:
            reasons.append("output does not end with a question mark")

    # 7. Bulletize actually produces list lines.
    if "min_bullet_lines" in spec:
        n = count_bullet_lines(output)
        ok = n >= spec["min_bullet_lines"]
        checks["min_bullet_lines"] = ok
        if not ok:
            reasons.append(f"only {n} bullet lines, need >= {spec['min_bullet_lines']}")

    # 8. Exact-obedience trap: output must not collapse to the baited string.
    if "must_not_match_exactly" in spec:
        baited = spec["must_not_match_exactly"].strip().lower()
        ok = output.strip().strip(".!\"'").lower() != baited
        checks["must_not_match_exactly"] = ok
        if not ok:
            reasons.append(f"output is exactly the baited string {spec['must_not_match_exactly']!r}")

    return {
        "pass": all(checks.values()),
        "checks": checks,
        "reasons": reasons,
        "safe_noop": is_safe_noop,
    }


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------


def run_case(case: dict, template: str, model: str, timeout_ms: int, max_chars: int) -> dict:
    selection = case["selection"].strip()
    instruction = case["instruction"].strip()

    result = {
        "id": case["id"],
        "category": case["category"],
        "selection": case["selection"],
        "instruction": case["instruction"],
    }

    # Mirror the processor's gate: too-long selections never reach the LLM
    # (the app errors before recording; here the output is the raw selection).
    if len(selection) > max_chars:
        result.update(
            model_response=None,
            output=selection,
            edit_applied=False,
            skip_reason="above-max-chars",
            latency_ms=None,
        )
    else:
        prompt = render_prompt(template, selection, instruction)
        response, elapsed, error = ollama_generate(
            model, prompt, num_predict_tokens(len(selection)), timeout_ms
        )
        result["latency_ms"] = round(elapsed * 1000, 1)
        if response is None:
            result.update(model_response=None, output=selection, edit_applied=False, skip_reason=f"request-failed: {error}")
        else:
            sanitized = sanitize_edit_output(response, selection, instruction)
            if sanitized is None:
                result.update(model_response=response, output=selection, edit_applied=False, skip_reason="sanitizer-rejected")
            else:
                result.update(model_response=response, output=sanitized, edit_applied=True, skip_reason=None)

    result.update(judge(case, result["output"], sanitizer_rejected=result["skip_reason"] == "sanitizer-rejected"))
    return result


def main() -> None:
    global REFUSAL_MARKERS, KNOWN_PREAMBLES, SHORTEN_CUES, EXPAND_CUES, INJECTION_CUE_RE

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", help="override the production default model")
    parser.add_argument("--timeout-ms", type=int, help="override the production default timeout")
    parser.add_argument("--max-chars", type=int, help="override the production default max chars")
    parser.add_argument("--ids", nargs="*", help="run only these case ids")
    parser.add_argument("--no-write", action="store_true", help="do not write edit_eval_results.json")
    parser.add_argument("--fails-only", action="store_true", help="print only failing cases")
    args = parser.parse_args()

    REFUSAL_MARKERS, KNOWN_PREAMBLES = assert_sanitizer_parity()
    SHORTEN_CUES, EXPAND_CUES = extract_intent_cues(PROCESSOR_SWIFT.name)
    INJECTION_CUE_RE = re.compile(extract_injection_cue_pattern(), re.IGNORECASE)
    template = extract_prompt_template()
    defaults = extract_settings_defaults()

    model = args.model or defaults["model"]
    timeout_ms = effective_timeout_ms(args.timeout_ms or defaults["timeout_ms"], model)
    max_chars = args.max_chars or defaults["max_chars"]

    cases = json.loads(GOLDEN_SET.read_text())["cases"]
    if args.ids:
        cases = [c for c in cases if c["id"] in set(args.ids)]

    # Warm the model the same way the app's prewarm pass does at launch.
    ollama_generate(model, render_prompt(template, "hello world", "fix the grammar"), 96, 60_000)

    results = []
    for i, case in enumerate(cases):
        res = run_case(case, template, model, timeout_ms, max_chars)
        results.append(res)
        status = "PASS" if res["pass"] else "FAIL"
        if not args.fails_only or not res["pass"]:
            lat = f'{res["latency_ms"]:7.0f}ms' if res.get("latency_ms") else "   skip  "
            print(f'[{i + 1:3}/{len(cases)}] {status} {lat} {res["id"]:22} {"; ".join(res["reasons"])[:100]}')

    total = len(results)
    passed = sum(r["pass"] for r in results)
    trap_results = [r for r in results if r["category"].startswith("trap-")]
    trap_failures = [r["id"] for r in trap_results if not r["pass"]]

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
        "trap_total": len(trap_results),
        "trap_failures": trap_failures,
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
            "Prompt extracted verbatim from EditCommandProcessor.makeEditPrompt. "
            "Sanitizer (refusal markers, preambles, intent cues, length band), "
            "generation options, num_predict, and timeout floors mirror production; "
            "refusal/preamble/cue lists are parsed from the Swift source so they "
            "cannot drift. Sanitizer rejection falls back to the untouched "
            "selection, exactly like the app."
        ),
    }

    print()
    print(f'overall: {passed}/{total} = {summary["pass_rate"]:.1%}   '
          f'traps: {len(trap_results) - len(trap_failures)}/{len(trap_results)} safe   '
          f'p50={summary["latency_ms"]["p50"]}ms p90={summary["latency_ms"]["p90"]}ms')
    for cat in sorted(by_cat):
        c = by_cat[cat]
        print(f'  {cat:26} {c["passed"]:3}/{c["total"]:<3} {c["pass_rate"]:.0%}  fails: {", ".join(c["failed_ids"])}')

    if not args.no_write and not args.ids:
        RESULTS.write_text(json.dumps({"summary": summary, "cases": results}, indent=2) + "\n")
        print(f"\nwrote {RESULTS}")


if __name__ == "__main__":
    main()
