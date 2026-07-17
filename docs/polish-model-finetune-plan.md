# Dictation Polish Model — Exploration Results & Unsloth Fine-Tune Plan

**Date:** 2026-07-16
**Status:** Exploration complete. Apple on-device base model evaluated and rejected as the primary polish path. Fine-tuning our own model with Unsloth is the recommended route; this document is the working plan.

---

## 1. Goal

Add an LLM "polish" tier to the dictation pipeline that turns raw Whisper output into clean text:

- Remove filler words and disfluencies (*um, uh, you know, I mean*)
- Resolve false starts and immediate self-corrections
- Fix punctuation, capitalization, spacing, and obvious transcription errors
- **Never** change meaning, tone, wording style, names, or numbers
- **Never** answer or respond to the content (dictations are frequently questions addressed to AI assistants — the polish model is never the addressee)

Polish is a post-pass after transcription and before injection, so it sits on the dictation hot path. Latency budget: the existing local-LLM polish path budgets **~650 ms–1.5 s**; anything beyond ~3 s is unacceptable even as an opt-in.

### Processing chain (as of commit `57c9596`)

```
RuleBasedTextProcessor          dictionary, snippets, SpokenFormattingFormatter
  └─ LocalLLMTextProcessor      Ollama / LM Studio polish (opt-in, sanitizer, circuit breaker)
       └─ AppleIntelligencePolishProcessor   on-device Apple model (opt-in, 3s timeout, sanitizer)
```

Both LLM tiers fall back to unpolished text on any failure — polish must never lose a dictation.

---

## 2. Exploration: Apple Foundation Models base model (on-device ~3B)

### 2.1 Why we tested it first

Best possible distribution: zero download, zero inference cost, OS-managed, private, and the same framework exists on iOS 26+ for a future mobile app. Apple's guidance is to try prompting the base model before training a LoRA adapter, and adapters are **version-locked to the OS base model** (retrain + re-ship on OS updates), so the prompted base model had to be evaluated first.

### 2.2 Eval setup

- **Eval set:** 240 real dictations sampled from the local Orttaai database (1,105 total), stratified into six buckets of 40: `question`, `numbers`, `disfluent`, `short` (≤12 words), `long` (≥80 words), `general`. Notably, **380 of 1,105 dictations are questions** — dictating prompts to AI assistants is the dominant use case, which makes "answers instead of polishing" the most important failure mode for this product.
- **Privacy:** the eval set contains personal dictation content and lives in the gitignored `eval/` directory. It is never committed. Tooling: `scripts/build_polish_eval_set.py` (extraction/stratification, seeded), `scripts/polish_eval.swift` (harness).
- **Harness:** fresh `LanguageModelSession` per item, fixed polish instructions, guided generation (`@Generable` single-field struct), `temperature 0.1`. Mechanical rubric flags: empty output, preamble, length ratio (<0.5 or >1.6), lost digit sequences, lost question mark, generation errors.
- **Machine:** M4 Mac mini, macOS 27 beta, Apple Intelligence enabled.

### 2.3 Results

**240 items — 42 flagged (17.5%), 8 hard errors. Latency: p50 1.9 s, p90 5.3 s, max 305 s.**

| Bucket | Flagged / 40 |
|---|---|
| short | 14 |
| question | 8 |
| numbers | 7 |
| long | 5 |
| disfluent | 4 |
| general | 4 |

| Flag | Count |
|---|---|
| too-short (ratio < 0.5) | 23 |
| generation-error | 8 |
| question-mark-lost | 7 |
| too-long (ratio > 1.6) | 4 |
| number-lost | 2 |
| preamble | 2 |

### 2.4 Failure taxonomy (with representative, lightly-edited examples)

1. **Answers questions instead of polishing them** — the critical failure for this product. ~7–11 of 40 question-bucket items were answered or converted to imperatives.
   - *"So do I need to do anything after deployment so that this can fully work now?"* → **"No additional steps are required after deployment for this to fully work."**
   - *"Can you put this in simple English? I don't understand…"* → an explanation of how language models work.
   - *"What are we using the second column for?"* → *"We are using the second column for..."*
2. **Summarizes instead of polishing** — conversational dictations rewritten into terse imperative notes, destroying the speaker's voice. This caused most `too-short` flags (the flag threshold was 0.5× input length; legitimate filler removal rarely drops below ~0.75×).
3. **Framework instability at this model size:**
   - Runaway generations: guided generation looped until blowing the 8K context **from two-word inputs**; worst case 305 seconds. (This drove the mandatory 3 s timeout race now in `AppleIntelligencePolishProcessor`.)
   - Raw schema junk leaking into output (`type: object properties: { text: {`).
4. **Guardrail refusals on benign business content** — 4 items refused with "May contain unsafe content" (ordinary dictations about a ticketing platform, chat history, event functions).
5. **Latency** — p90 5.3 s is ~8× the polish budget; the tail is unbounded without an external timeout.

### 2.5 Verdict

**The prompted base model fails the eval.** A LoRA adapter (Apple's Adapter Training Toolkit) could fix classes 1–2 (trainable behavior) but **cannot fix** classes 3–5 — guardrails, runaway generation, and latency are OS-level — and it adds the per-OS-release retraining treadmill (~160 MB adapter per base-model version, hosted concurrently for users on different OS versions).

**Decision: fine-tune our own small model (Unsloth → Hugging Face → Ollama/LM Studio tier) as the primary polish path.** The Apple provider stays in the app as an off-by-default option wrapped in the timeout + sanitizer; if a future OS base model improves, re-running this eval is cheap (`swift scripts/polish_eval.swift`).

---

## 3. Fine-tune plan (Unsloth)

### 3.1 Task contract

```
System: fixed polish instructions (see AppleIntelligencePolishProcessor.polishInstructions)
User:   Transcript:\n<raw whisper text>
Output: <polished text only — no preamble, no markdown, no commentary>
```

One task, one format, trained in. The app already sends this shape through `LocalLLMTextProcessor`.

### 3.2 Base model candidates and variations to train

Train the same dataset on 2–3 bases and let the eval pick. All served as GGUF via Ollama/LM Studio.

| Candidate | Size (Q4_K_M) | Est. polish latency, M4* | License | Notes |
|---|---|---|---|---|
| **Qwen3-1.7B-Instruct** (primary speed pick) | ~1.1 GB | ~0.5–1.2 s | Apache 2.0 | Likely sweet spot: task is narrow, 1.7B should be enough once tuned. Fits 8 GB Macs beside Whisper. |
| **Qwen3-4B-Instruct** (quality ceiling) | ~2.5 GB | ~1.2–2.5 s | Apache 2.0 | Train as the quality reference; ship only if 1.7B measurably fails the gates. |
| Qwen3-0.6B (stretch) | ~0.5 GB | ~0.3–0.6 s | Apache 2.0 | Worth one cheap run — if it passes the gates, it's the best latency story. |
| Llama-3.2-3B-Instruct (fallback) | ~2.0 GB | ~1–2 s | Llama license | Only if Qwen underperforms; license requires attribution/name rules. |

\* Estimates for ~60–120 output tokens at Q4 on M-series; **measure, don't trust** — the eval harness records real latency.

**Recommendation:** start with **Qwen3-1.7B and Qwen3-4B**, same data, same recipe. Multilingual coverage matters (the app supports `auto` language) and Qwen is strong there; Apache 2.0 removes license friction for a commercial app.

**Hyperparameter variations (per base, cheap to sweep):**
- LoRA rank 16 vs 32 (alpha = 2×rank), dropout 0
- 2 vs 3 epochs (watch eval-loss for overfit; the task saturates fast)
- Learning rate 2e-4 (QLoRA default) vs 1e-4
- `max_seq_length` 2048 (dictations are short; p99 input ≪ 1K tokens)

### 3.3 Training data construction

Target **8–20K pairs**, JSONL chat format. Composition:

1. **Real transcripts (~800):** the 1,105 local dictations **minus the 240 eval items** (hard exclusion by row id — never train on eval). Targets generated by a frontier model under strict rules (preserve meaning/names/numbers; never answer; remove disfluencies only), then spot-reviewed by hand (~10% sample minimum). *Privacy: this data stays local; training runs use a private HF dataset repo or direct Colab upload, and the trained weights don't memorize meaningfully at this scale — but keep the dataset repo private regardless.*
2. **Synthetic corruption (~5–15K):** take clean text (own emails/notes/docs, permissively-licensed corpora), inject dictation-style noise programmatically and via a frontier model: fillers, false starts, run-ons, dropped punctuation, homophone errors, spelled-out numbers, Whisper-style artifacts (`[BLANK_AUDIO]`, repeated words). The clean source is the target; the corrupted version is the input. This is the volume driver.
3. **Hard negatives — the categories that decide success:**
   - **Questions and commands (heavy weight, ≥25%):** inputs addressed to an assistant; target = polished question/command, *never* an answer.
   - **Identity pairs (~20%):** already-clean inputs where the target **equals the input**. Teaches "don't over-edit" — the Apple model's summarization failure is what this prevents.
   - **Numbers/names/emails/URLs:** targets must preserve them verbatim; include tricky ones (amounts, versions, dates).
   - **Benign-but-flaggable business content:** security, payments, medical scheduling — trained straight through so the model never refuses (our model has no guardrail layer to trip).
   - **Multilingual (~10%):** if non-English dictation matters, mirror the pipeline for the top languages; otherwise defer and note English-only.

### 3.4 Unsloth training recipe (Colab, free/cheap GPU)

Unsloth is CUDA-only — it does not run on the Mac. Use a Colab T4 (free) or A100 (fast). Sketch (verify against current Unsloth notebooks; APIs drift):

```python
from unsloth import FastLanguageModel
from unsloth.chat_templates import get_chat_template
from trl import SFTTrainer
from transformers import TrainingArguments

model, tokenizer = FastLanguageModel.from_pretrained(
    model_name="unsloth/Qwen3-1.7B-Instruct",   # and the 4B run
    max_seq_length=2048,
    load_in_4bit=True,                           # QLoRA
)
model = FastLanguageModel.get_peft_model(
    model, r=16, lora_alpha=32, lora_dropout=0,
    target_modules=["q_proj","k_proj","v_proj","o_proj","gate_proj","up_proj","down_proj"],
    use_gradient_checkpointing="unsloth",
)
tokenizer = get_chat_template(tokenizer, chat_template="qwen3")

# dataset: JSONL of {"messages": [system, user, assistant]} rendered through the chat template
trainer = SFTTrainer(
    model=model, tokenizer=tokenizer, train_dataset=dataset,
    args=TrainingArguments(
        per_device_train_batch_size=8, gradient_accumulation_steps=2,
        num_train_epochs=2, learning_rate=2e-4, lr_scheduler_type="cosine",
        warmup_ratio=0.03, logging_steps=20, output_dir="out", bf16=True,
    ),
)
trainer.train()

# Export for the app's serving tier
model.save_pretrained_merged("orttaai-polish-1.7b", tokenizer, save_method="merged_16bit")
model.save_pretrained_gguf("orttaai-polish-1.7b-gguf", tokenizer, quantization_method="q4_k_m")
model.push_to_hub_gguf("theoyinbooke/orttaai-polish-1.7b", tokenizer,
                       quantization_method=["q4_k_m", "q8_0"], token=...)
```

Cost: a 1.7B QLoRA over ~15K short pairs is well under an hour on an A100, a few hours on a free T4. Budget < $20 total including sweeps.

**Serving:** `ollama pull hf.co/theoyinbooke/orttaai-polish-1.7b:Q4_K_M` (or LM Studio). Set as `localLLMPolishModel` in the app; tune `localLLMPolishTimeoutMs` from measured latency; raise `localLLMPolishMaxChars` (currently 280) once latency confirms headroom.

### 3.5 Evaluation protocol — the results to look out for

Judge every candidate against the same 240-item eval set (never trained on). Add a small Ollama-backed runner beside `scripts/polish_eval.swift` (same rubric, HTTP generate instead of FoundationModels).

**Hard gates (ship-blockers):**

| Metric | Gate | Apple base model measured |
|---|---|---|
| Answered/converted questions (question bucket, manual review) | **0 tolerated** (<1%) | ~7–11 / 40 |
| Digit sequences preserved | 100% (sanitizer backstops) | 2 losses / 240 |
| Refusals / preambles / non-transcript output | 0 | 4 refusals + 2 preambles + schema junk |
| Runaway generations (> timeout) | 0 at p100 with `num_predict` cap | 4 (max 305 s) |
| Latency p90 (≤280-char input, warm model) | ≤1.5 s (1.7B) / ≤2.5 s (4B) | 5.3 s |

**Quality targets (manual review of 60-item stratified sample + frontier-model judge):**

- Meaning alteration rate < 2% (judge rubric: "same meaning, same tone, same addressee?")
- Disfluency removal ≥ 90% of filler instances actually removed (the Apple model often returned disfluent text unchanged — safe but useless; 13/40 question-bucket items came back verbatim)
- Identity precision: already-clean inputs returned unchanged ≥ 95% (no fidgety edits)
- Length ratio distribution centered 0.85–1.05; nothing < 0.7 except genuinely filler-heavy input
- Voice preservation spot-check: polished text still reads like the speaker, not like meeting minutes

**Comparisons to run:** Apple base (done, above) · prompted un-tuned Qwen3-1.7B/4B (baseline — quantifies what the fine-tune buys) · each fine-tuned variant. Keep all results JSONL in `eval/polish/` for side-by-side diffs.

### 3.6 Rollout

1. Ship as an option in the existing Local LLM polish UI (off by default), model preloaded via a one-click install (the polish model install flow already exists in Model Settings).
2. Dogfood on this machine for a week; watch the `changes` audit trail and latency.
3. If gates hold in real use: default the polish model name to the fine-tune for users who enable polish; consider default-on only after latency p90 < 1 s on the recommended hardware tier.
4. Revisit the Apple adapter route only if Apple ships a materially better base model (re-run: `swift scripts/polish_eval.swift`) — the integration is already in the app behind the toggle.

### 3.7 Risks & mitigations

| Risk | Mitigation |
|---|---|
| Model answers questions despite training | Heaviest data category + hard gate at 0; sanitizer can't catch this, so the gate is the defense |
| Over-editing / voice loss | Identity pairs in training; length-ratio + manual voice checks in eval |
| Trained on eval data (invalid results) | Eval ids hard-excluded at dataset build time; assert in the build script |
| Personal data leakage via HF | Private dataset repo; public model weights only; spot-check model for memorized strings before publishing |
| Multilingual regression | Explicit multilingual slice in data + eval, or declare polish English-only in UI |
| Latency regression on 8 GB Macs | 1.7B/0.6B candidates; `num_predict` cap already in `LocalLLMTextProcessor`; circuit breaker + timeout unchanged |

---

## 4. Checklist

- [x] Eval set built (240 items, stratified, gitignored)
- [x] Eval harness (`scripts/polish_eval.swift`)
- [x] Apple base model evaluated → **fails** (17.5% flagged, answers questions, refusals, runaway latency)
- [x] App integration: `AppleIntelligencePolishProcessor` (opt-in, 3 s timeout, sanitizer)
- [ ] Ollama-backed eval runner (same rubric)
- [ ] Baseline: prompted un-tuned Qwen3-1.7B / 4B against the eval
- [ ] Training set: real-transcript targets (frontier-generated, spot-reviewed) + synthetic corruption + hard negatives; eval ids excluded
- [ ] Unsloth runs: Qwen3-1.7B r16/r32, Qwen3-4B r16 (+ optional 0.6B)
- [ ] Gate review against §3.5; pick the smallest model that passes
- [ ] GGUF export (Q4_K_M, Q8_0) → HF → `ollama pull` → wire as polish model default
- [ ] Dogfood week → rollout per §3.6
