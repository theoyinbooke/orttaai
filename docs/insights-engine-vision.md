# The Insight Engine — Vision & Technical Scope

> **Implementation status (2026-07-01):** Phases 1–3 implemented
> (`SemanticTextAnalyzer`, `SemanticSignalExtractor` + `semantic_signal`,
> `InsightPatternEngine` + `insight_finding`), plus Phase 4 core: findings feed
> the report and the LLM prompt, and the Insights tab gained the Open Loops &
> Commitments ledger (resolve/dismiss), finding cards, and the caveat line.
> Remaining from Phase 4: LLM micro-classifier signal families (intent/domain
> via Ollama JSON schema), the Weekly Prophecy digest, and unifying
> WritingInsights into the findings pipeline.

*Redesigning Orttaai's Memory Graph insights from "keyword clouds" into a private
life analyst that sees patterns you can't.*

---

## 1. The honest diagnosis

The current insights feel shallow, and the reason is measurable, not aesthetic.
The narration layer is working. The signals feeding it are not.

**Evidence from the live database:**

- The top "topics" in the graph are `Open`, `able`, `again`, `believe`, `going`,
  `here`, `know`, `it-s` — frequent words, not concepts. Topic extraction is a
  raw frequency count of tokens ≥4 chars (`SemanticMemoryService.swift:2515`).
- "Entities" include `olama-yeah`, `api-and`, `glm-moodle` — the
  capitalized-word-run heuristic (`:2531`) tripping over ASR text.
- The latest generated insight literally says *"**Open** is the current center of
  gravity in your dictated work"* — a confident prophecy about a stopword.
- The "Recurring theme" label on every topic node is a hard-coded subtitle
  string (`:2444`), not a computed signal.
- Semantic (similarity) edges are only computed among the **first 100 chunks**
  (`:2469`), and the graph is pruned to 180 nodes / 360 edges — the graph stops
  growing with the user's life.
- Rich captured signals go **unused**: hour-of-day, per-app WPM, session
  cadence, bundle IDs, recording duration. The dictation rhythm alone (this
  user's clusters at 8pm–3am) is an insight no current card can express.
- Two disconnected insight systems (graph `SemanticInsightReport` vs history
  `WritingInsightSnapshot`) with different schemas, prompts, models, and
  freshness rules.

**The core lesson:** a small local model asked to *discover* insights from weak
evidence produces generic prophecy. The same model asked to *phrase* strong,
pre-computed findings produces something that feels like magic. So the redesign
inverts the architecture: **deterministic spine, LLM voice.**

---

## 2. North star

Every insight the app shows must be:

1. **Specific** — names a real concept, time window, and magnitude.
2. **Evidenced** — tap-through to the exact dictations that support it.
3. **Non-obvious** — something the user didn't already know they said.
4. **Honest** — carries confidence, sample size, and model-tier caveats.

The prophet fantasy is achievable precisely because dictation is *intent*: the
user narrates what they want, fear, promise, and abandon — across email, chat,
search, and code. Nobody else has that corpus. The engine's job is to remember
it better than the user does.

---

## 3. Architecture: Signals → Patterns → Voice

### Layer 1 — SIGNALS (per chunk, at index time, cached forever)

Replace the frequency-count extraction with a real signal layer. Runs
incrementally; each chunk is processed once and cached by `textHash`.

**Deterministic (no LLM, always available):**

- **Apple NaturalLanguage framework** (`NLTagger`) — on-device lemmatization,
  part-of-speech filtering (nouns/proper nouns only → no more "going"/"here"),
  and built-in named entity recognition (people, places, organizations). Free,
  fast, zero dependencies. This single change kills stopword topics.
- **Keyphrase extraction** — TextRank/RAKE over lemmas plus corpus-level TF-IDF,
  so *the user's unusual words* surface, not English's common ones.
- **Canonicalization via embeddings** — cluster phrase embeddings (the pipeline
  already embeds everything) to merge ASR variants and synonyms:
  `insight/insights/inside-the-page` collapse into one concept node instead of
  three noise nodes.

**Small-LLM micro-classifiers (one chunk at a time, strict JSON schema):**

`OllamaClient` already supports `formatJSONSchema` structured output. A 0.8–4B
model is *unreliable* at "analyze my life" but *very reliable* at single-chunk,
closed-vocabulary tasks:

- **Intent**: instruct / ask / plan / decide / reflect / complain / appreciate
- **Domain**: coding / writing / email / chat / research / personal / admin
- **Commitments**: extract "I will…" / "I need to…" statements verbatim
- **Questions**: questions the user asked
- **Decisions**: choices stated ("let's go with X")
- **Tone/energy**: frustrated / neutral / excited (word-supported only)

New table: `semantic_signal (chunkID, family, value, confidence, modelID,
extractedAt)` — append-only, cached, incremental cost only for new dictations.

### Layer 2 — PATTERNS (pure algorithms, no LLM, the actual intelligence)

Mining runs over signals + the metadata already captured. Everything here is
deterministic, testable, and works with Ollama switched off.

- **Life Areas** — community detection (label propagation) over the
  canonicalized concept graph. Clusters become named areas of life; attention
  share per area per week is computable exactly.
- **Rhythms** — hour-of-day / day-of-week activity, WPM and fluency by hour and
  app ("you dictate 22% faster after 9pm", "your Codex sessions are 3× longer
  than your email sessions").
- **Trajectories** — per-concept time series with slope + burst detection:
  genuinely emerging, fading, and *resurfacing* themes ("Docker returns every
  ~9 days and never resolves").
- **Commitment ledger** — commitments extracted in Layer 1, tracked forward.
  Resolved if a later chunk references completion; otherwise aging open loops
  with day counts.
- **Question ledger** — questions asked that never got a follow-up.
- **Bridges** — concepts spanning multiple life areas or apps (duplicated
  effort, hidden dependencies).
- **Anomalies** — today vs personal baseline: volume, switching rate, tone mix.

Output: typed `InsightFinding` rows — `{kind, subject, magnitude, window,
confidence, evidenceChunkIDs, firstSeen, lastShown}` — persisted, so insights
have memory (no re-showing the same observation every generation).

### Layer 3 — VOICE (the prophet, finally)

- **Ranker** — score findings by novelty × confidence × coverage ×
  actionability; pick the top N. Deterministic.
- **Narrator** — the LLM receives *one finding at a time* as structured JSON and
  returns 1–2 sentences in the product voice. It never discovers, only phrases.
  This is the task small models are excellent at — and if Ollama is offline,
  template phrasing renders the same finding. **The experience never degrades to
  empty; it degrades to plainer language.**
- **Weekly Prophecy** — a digest narrative composed from the week's top
  findings, the one place longer-form LLM synthesis is allowed (with the
  findings as its only input).

### Caveats framework (the user's explicit requirement)

Every rendered insight carries provenance UI:

- "Based on 41 dictations across 12 days" (sample size)
- Confidence chip (from finding confidence, not LLM vibes)
- Model-tier notice when narration ran on a ≤1B model or data is thin
- Tap-through evidence list (already exists — keep and elevate it)

---

## 4. The redesigned Insights experience

Replace the current card dump with a structured page:

1. **Today strip** — one headline observation + any anomaly ("You context-switched
   2× your baseline this morning").
2. **Life Areas board** — community cards with attention-share sparklines.
3. **Open Loops & Commitments** — ledger cards with age badges and
   resolve/dismiss actions (user feedback loops back into ranking).
4. **Rhythms** — best hours, fluency curves, session shapes.
5. **Emerging / Fading / Resurfacing** — real trajectories with evidence.
6. **Weekly Prophecy** — the narrative digest.

Unify `WritingInsightSnapshot` into the same findings pipeline — speaking
fluency and phrasing habits are just another signal family. One schema, one
freshness model, one generation path.

---

## 5. Phasing

| Phase | Scope | Payoff |
|---|---|---|
| **1. Honest graph** | NLTagger topics/entities, embedding canonicalization, remove the 100-chunk semantic-edge cap, computed (not hard-coded) recurrence labels | Graph and existing insights become instantly credible; deterministic only |
| **2. Signal layer** | `semantic_signal` table, micro-classifier prompts with JSON schemas, commitment/question extraction, per-chunk caching | The corpus becomes queryable intent, not text |
| **3. Pattern engine** | Life areas, rhythms, trajectories, ledgers, anomalies; `InsightFinding` store + ranker | The actual intelligence, fully offline-capable |
| **4. Voice & UI** | Narrator, redesigned Insights page, Weekly Prophecy, caveats framework, unification of writing insights | The prophet experience |

Phase 1 is small and immediately visible. Phases 2–3 are where the moat is.
Phase 4 is when it starts feeling like the vision.

---

## 6. Key existing anchors (for implementation)

- Indexing: `SemanticMemoryService.indexPendingTranscriptions` (`SemanticMemoryService.swift:286`)
- Extraction to replace: `topicPhrases` (`:2515`), `entityPhrases` (`:2531`)
- Graph build: `rebuildGraph` (`:2364`); semantic-edge cap at `:2469`
- Insight generation: `generateInsights` (`:237`), deterministic report `makeInsightReport` (`:467`), LLM overlay `reportWithModelInsightsIfAvailable` (`:827`)
- Structured output support: `OllamaClient.generate(formatJSONSchema:)` (`OllamaClient.swift:180`)
- Insights UI: `SemanticMemoryView.insightsContent` (`SemanticMemoryView.swift:812`)
- Writing insights to unify: `WritingInsightsService.swift`, `HomeInsightsPanel.swift`
