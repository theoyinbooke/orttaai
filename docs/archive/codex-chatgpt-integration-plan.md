# ChatGPT Subscription (Codex) Provider — Implementation Plan

**Goal:** Users who have a ChatGPT subscription (Plus / Pro / Business / etc.) and the Codex CLI installed can toggle on "ChatGPT (Codex)" as an intelligence source in Settings → Model. When enabled, OpenAI frontier models (GPT-5.5 / 5.4 / 5.4-mini) power Chat AI, the Insight Engine (writing insights + semantic-graph deep interpretation), and tone analysis — billed against the user's own subscription, with zero API keys and zero server cost to Orttaai.

**Status:** Phase 1 implemented (2026-07-03). Protocol validated empirically against `codex-cli 0.142.5` (see §8).

Implementation map:
- `Orttaai/Core/Codex/CodexAppServerConnection.swift` — binary discovery, process spawn, JSON-RPC transport, idle shutdown, crash recovery
- `Orttaai/Core/Codex/CodexClient.swift` — `LocalLLMServing` over ephemeral read-only turns; `outputSchema` structured output
- `Orttaai/Core/Codex/CodexAccountService.swift` — sign-in/out, plan gating, rate limits
- `Orttaai/UI/Settings/CodexSettingsCard.swift` — account card, model/effort pickers, usage meter, consent
- Hybrid routing in `AppSettings` (`embeddingLLMClient` / `polishLLMClient`); provider case in `LocalLLMProvider.swift`
- Tests: `OrttaaiTests/Core/CodexClientTests.swift` (fake transport), `CodexIntegrationTests.swift` (real CLI, auto-skips)

---

## 1. How it works (concept)

The Codex CLI ships an **app-server**: a JSON-RPC 2.0 server over stdio (newline-delimited JSON) designed exactly for embedding Codex in third-party products. Orttaai spawns `codex app-server` as a child process and speaks JSONL to it:

```
Orttaai (Swift) ──spawn──▶ codex app-server (child process, stdio JSONL)
                              │
                              ├─ owns ChatGPT OAuth + token storage (~/.codex/auth.json)
                              ├─ account/read → { type: "chatgpt", email, planType }   ← subscription gate
                              ├─ model/list   → gpt-5.5, gpt-5.4, gpt-5.4-mini (+ reasoning efforts)
                              └─ thread/start (ephemeral) + turn/start (outputSchema) → inference
```

Key properties that make this the right approach:

- **Codex owns all credentials.** Login is `account/login/start` → browser OAuth → `account/login/completed` notification. Tokens live in `~/.codex/auth.json`, refreshed by Codex. Orttaai never stores a secret — **no Keychain work needed**.
- **Subscription gating is built in.** `account/read` returns `planType` (observed: `"prolite"`; also `plus`, `pro`, `business`). We enable the feature only when `account.type == "chatgpt"`.
- **Ephemeral threads** (`ephemeral: true` on `thread/start`) keep Orttaai inference out of the user's Codex session history.
- **`outputSchema` on `turn/start`** gives strict JSON — a drop-in for the `formatJSONSchema` structured output the Insight Engine already uses.
- **Streaming** via `item/agentMessage/delta` notifications (validated: 62 deltas on a single turn) — enables streaming chat later.
- **Rate limits are queryable** (`account/rateLimits/read` → used %, window, reset time) so we can show a usage meter and degrade gracefully.

**Why not bundle the binary:** the codex binary is **238 MB** (aarch64). Bundling would ~10x the DMG. v1 detects a user-installed CLI and guides installation (`brew install --cask codex`). The app is unsandboxed (hardened runtime only), so spawning `/opt/homebrew/bin/codex` needs no new entitlements.

**Why not the OpenAI HTTP API:** requires an API key + per-token billing — the whole point is to let subscribers use what they already pay for.

---

## 2. Where it plugs in (existing architecture)

Everything routes through one seam — `LocalLLMServing` (`Orttaai/Core/Transcription/LocalLLMProvider.swift`):

| Feature | Call site | Method used |
|---|---|---|
| Chat AI | `UI/ChatAI/ChatAIView.swift:717` | `chat` |
| Writing insights | `Core/Analytics/WritingInsightsService.swift:510` | `generate` (JSON) |
| Semantic-graph insight cards | `Core/SemanticMemory/SemanticMemoryService.swift:1077` | `generate` (json_schema) |
| Tone of voice | `Core/Analytics/ToneOfVoiceService.swift:34` | `generate` (JSON) |
| Dictation polish | `Core/Transcription/LocalLLMTextProcessor.swift:94` | `generate` |
| Embeddings | `Core/SemanticMemory/SemanticMemoryService.swift:71` | `embed` |

All call sites resolve the client per-call via `AppSettings.activeLocalLLMClient` → `LocalLLM.client(for:)`. **Adding a provider case + client + factory arm lights up every feature automatically.** Catalog/download UI is already gated by `supportsModelInstall` and hides itself for non-Ollama providers.

Two carve-outs:

1. **Embeddings**: app-server has no embedding endpoint. `CodexClient.embed` throws "unsupported"; `SemanticMemoryService` keeps using the local embedding provider (Ollama/LM Studio) or its existing `LexicalSemanticEmbeddingProvider` fallback. Embeddings stay local by design (also better for privacy + cost).
2. **Dictation polish**: cloud round-trip (~9 s observed for gpt-5.4-mini analysis) is too slow for the dictation hot path. Polish stays on the local provider; the settings UI says so when Codex is selected.

This implies a small but important design change: **Codex is a "generation" provider, not a full replacement.** See §3.4 (hybrid routing).

---

## 3. Implementation

### 3.1 New: `CodexAppServerConnection` (actor) — process + protocol layer

`Orttaai/Core/Codex/CodexAppServerConnection.swift`

- Spawns `codex app-server` via `Process` with `Pipe`s; reads stdout line-by-line, decodes JSON-RPC frames.
- Request/response correlation by `id` (monotonic Int, `CheckedContinuation` map); notification fan-out via `AsyncStream` per subscriber.
- Handshake on connect: `initialize` (clientInfo `{name: "orttaai", title: "Orttaai", version: <app version>}`) → `initialized`. The `clientInfo.name` is what OpenAI's compliance logs see — keep it stable.
- **Binary discovery**: check in order `~/.orttaai/codex-path` override → `/opt/homebrew/bin/codex` → `/usr/local/bin/codex` → `which codex` via login shell. Run `codex --version`; require ≥ the version we validated (0.142.x) and surface a "please update Codex" state below it.
- **Lifecycle**: lazy-start on first use; idle-shutdown after 5 min of no requests; terminate on app quit (`applicationWillTerminate`). Restart with backoff (max 3) on crash; in-flight requests fail with a typed error.
- **Defensive decoding**: app-server is marked experimental — every decode tolerates unknown fields/enum values (decode to optionals, never `fatalError`).

Transport is factored behind a tiny `CodexTransport` protocol so tests inject a fake (same pattern as `LMStudioClientTests`).

### 3.2 New: `CodexAccountService` — auth + gating

`Orttaai/Core/Codex/CodexAccountService.swift` (`@MainActor ObservableObject`)

- `state`: `.codexNotInstalled | .codexOutdated(String) | .signedOut | .signedIn(email:planType:) | .apiKeyOnly` — drives all UI.
- `refresh()` → `account/read` (`refreshToken: false`).
- `signIn()` → `account/login/start {type: "chatgpt"}` → open `authUrl` with `NSWorkspace.shared.open` → await `account/login/completed` notification (with timeout + `account/login/cancel`). Fallback: device-code flow (`chatgptDeviceCode`) for browserless setups (phase 3).
- `signOut()` → `account/logout`.
- **Gate rule**: feature is usable only when `account.type == "chatgpt"`. Any `planType` string is accepted (values drift: `prolite` observed; don't hardcode a whitelist). `apiKey`-only auth shows "requires ChatGPT sign-in".
- `rateLimits()` → `account/rateLimits/read`; also subscribe to `account/rateLimits/updated` to keep the meter live.

### 3.3 New: `CodexClient: LocalLLMServing` (actor)

`Orttaai/Core/Codex/CodexClient.swift` — modeled on `LMStudioClient`. Mapping:

| `LocalLLMServing` | app-server call |
|---|---|
| `checkHealth` | binary found + version ok + `initialize` + `account/read` is chatgpt → `.healthy`; else typed unhealthy reasons |
| `fetchModelNames` | `model/list` → `data[].id` (visible models only), 30 s cache |
| `generate(prompt:formatJSONSchema:...)` | `thread/start {model, cwd: <app support tmp dir>, approvalPolicy: "never", sandbox: "read-only", ephemeral: true}` → `turn/start {input: [text], outputSchema: <schema if provided>}` → await final `agentMessage` `item/completed` → text |
| `chat(messages:)` | same as generate, with the message history flattened into one prompt (system + role-tagged turns), matching how the rest of the app treats chat as stateless. Thread-per-conversation is a phase-2 upgrade. |
| `embed` | `throw OllamaClientError.requestFailed("Embeddings are not available via ChatGPT (Codex); local provider is used instead")` |
| `warmModel` | no-op returning 0 (cloud model; nothing to warm) |

Notes:
- `sandbox` on `thread/start` is **kebab-case** (`"read-only"`) — validated; the docs' camelCase (`readOnly`) is rejected with `-32600`.
- One ephemeral thread per request (stateless, matches the protocol semantics of the existing clients). Turn timeout from the caller's `timeoutMs`, then `turn/interrupt` + fail.
- Map `turn.error.codexErrorInfo` to friendly errors: `UsageLimitExceeded` → "You've hit your ChatGPT usage limit; resets at {time}" (from rateLimits), `Unauthorized` → flip account state to signed-out, `ContextWindowExceeded` → truncate-and-retry once.
- `temperature`/`numPredict`/`numContext`/`keepAlive`/`think` have no app-server equivalents → ignored (document in code). Reasoning effort is a per-provider setting instead (`effort` on `turn/start`).

### 3.4 Modified: provider registry + hybrid routing

`Orttaai/Core/Transcription/LocalLLMProvider.swift`

- Add `case codex` to `LocalLLMProviderKind` (`displayName: "ChatGPT (Codex)"`, `defaultEndpoint: ""`, `supportsModelInstall: false`, `supportsThinkFlag: false`).
- Add `supportsEmbeddings: Bool` (false for `.codex`) and `supportsLocalPolish: Bool`-style capability flags rather than call-site `if kind == .codex` checks.
- `LocalLLM`: add `static let codexClient = CodexClient()` + factory arm.

`Orttaai/Data/AppSettings.swift`

- New keys: `codexModel` (default `"gpt-5.4-mini"`), `codexReasoningEffort` (default `"medium"`), `codexEnabledForChat` / `codexEnabledForInsights` (defaults true — these matter only when provider == codex).
- `activeLocalLLMEndpoint`: return `""` for `.codex` (no HTTP endpoint).
- **Hybrid routing helpers** (the real change): `embeddingLLMClient` / `embeddingLLMEndpoint` (always resolve to the last-used *local* provider when active provider is `.codex`) and `polishLLMClient` (same). `SemanticMemoryService`'s embedding provider and `LocalLLMTextProcessor` switch to these; everything else keeps using `activeLocalLLMClient`.
- `sanitizeLocalLLMModel` must not apply its "llama" filter or local defaults to codex models — branch on provider.

### 3.5 Modified: Settings UI

`Orttaai/UI/Settings/ModelSettingsView.swift`

Provider dropdown (line ~862) gains "ChatGPT (Codex)". When selected, the endpoint field is replaced by a **Codex status card** driven by `CodexAccountService.state`:

1. **Not installed** → "Codex CLI not found" + install instructions (`brew install --cask codex`) + "Locate manually…" + re-check button.
2. **Signed out** → "Sign in with ChatGPT" button (opens browser, spinner until `login/completed`).
3. **Signed in** → email + plan badge (e.g. "Pro"), model picker (from `model/list`, with `displayName`/`description`), reasoning-effort picker (from `supportedReasoningEfforts`), live usage meter (primary window `usedPercent` + reset time), Sign out.
4. **Consent line (required)**: "When enabled, transcripts and insight data are sent to OpenAI under your ChatGPT account." shown with the toggle the first time; persists as a caption.
5. Inline note: "Dictation polish and semantic embeddings continue to use your local model."

`UI/ChatAI/ChatAIView.swift`: model menu already calls `fetchModelNames` through the active client — works as-is; fix the Ollama-flavored strings ("Refresh Ollama models") to be provider-neutral; hide the thinking toggle for codex (effort picker covers it).

### 3.6 Insight Engine hookup (mostly free)

- `OllamaWritingInsightAnalyzer` (`WritingInsightsService.swift:349`) and `SemanticMemoryService.reportWithModelInsightsIfAvailable` (line 1040) both go through `generate` → they light up automatically. Rename/alias `Ollama*` types to provider-neutral names opportunistically.
- `SemanticMemoryService` line ~1065 checks that the insight model is installed via `fetchModelNames` — for codex this returns cloud models, so validate against `codexModel` instead of `localLLMInsightsModel` (small branch).
- **Deep-interpretation upgrade (the payoff)**: when provider == codex, raise the analysis budget — feed more transcripts/findings per insight run (local models are capped for context; GPT-5.x is not, and `reasoningEffort: high` is available). Add a `deepAnalysis` prompt variant in both seams that (a) passes the full deterministic finding set + evidence excerpts, (b) requests cross-finding narrative synthesis via `outputSchema`. Deterministic engine still originates findings; the cloud model only interprets — preserving the "LLM rephrases, never originates" invariant in `InsightPatternEngine`.

### 3.7 Testing

- `OrttaaiTests/Core/CodexClientTests.swift`: fake `CodexTransport` replaying captured frames (initialize, account/read, model/list, thread/start kebab-case regression, turn lifecycle with deltas, error turns for `UsageLimitExceeded`/`Unauthorized`, malformed/unknown-field frames).
- `CodexAppServerConnectionTests`: id correlation, notification routing, crash → restart → in-flight failure, idle shutdown.
- One optional integration test gated on `codex` being installed + signed in (skipped in CI).

---

## 4. Phasing

**Phase 1 — provider + gating (ship first):** §3.1–3.5. Chat AI, writing insights, semantic insight cards, and tone all work on GPT-5.x with sign-in, plan gating, consent, and rate-limit errors. Non-streaming (matches current UX for all providers).

**Phase 2 — experience:** streaming chat (subscribe to `item/agentMessage/delta`; add an optional `chatStream` method on `LocalLLMServing` with a default non-streaming implementation), thread-per-conversation chat memory, live usage meter in ChatAI footer, deep-analysis insight prompts (§3.6), device-code sign-in fallback.

**Phase 3 — hardening:** contact OpenAI to register `orttaai` on the known-clients list (enterprise compliance logs), auto-detect Codex updates/`codex update` prompt, telemetry on turn latency/error rates, optional per-feature routing UI (e.g. "chat local, insights cloud").

---

## 5. Risks & mitigations

| Risk | Mitigation |
|---|---|
| `app-server` is experimental; schema drift between CLI versions | Min-version check; defensive decoding; regenerate types per release (`codex app-server generate-json-schema`); integration probe script kept in `scripts/` |
| Docs vs reality mismatches (already found one: `sandbox` kebab-case) | Everything in this plan that matters was validated live (§8); keep the probe scripts |
| User hits ChatGPT usage limits mid-feature | Typed `UsageLimitExceeded` error with reset time; insight scheduler skips cloud runs while limited and falls back to the local/heuristic analyzer chain (already exists) |
| Privacy: transcripts leave the device | Explicit consent copy on enable; embeddings/polish stay local; ephemeral threads |
| Codex not installed / signed out mid-session | Health check before each feature use (cheap: `account/read` on cached connection); graceful fallback to existing analyzer chain |
| ToS: is this allowed? | app-server is OpenAI's documented surface for exactly this ("deep integration inside your own product"); usage counts against the user's own subscription limits; `clientInfo.name` identifies us honestly |

---

## 6. Explicitly out of scope (v1)

- Bundling the codex binary (238 MB), sandboxed-app support, Windows/Linux port parity (separate repo), embeddings via cloud, agentic/tool-use turns (we run pure-inference, `sandbox: "read-only"`, `approvalPolicy: "never"` — Codex never executes anything on the user's machine on our behalf).

---

## 7. Estimated effort

| Work item | Size |
|---|---|
| Connection + transport + tests | ~2–3 days |
| CodexClient + account service + tests | ~2 days |
| Provider enum / settings / hybrid routing | ~1 day |
| Settings UI (status card, sign-in, model/effort pickers, meter) | ~2 days |
| Insight/chat integration + copy fixes | ~1 day |
| QA on real subscription (limits, sign-out, crash paths) | ~1 day |

**Total: roughly 1.5–2 weeks** for Phase 1.

---

## 8. Empirical validation log (2026-07-03, codex-cli 0.142.5, macOS arm64)

- `initialize` → `userAgent: "orttaai_probe/0.142.5 …"`, `codexHome: ~/.codex`.
- `account/read` → `{type: "chatgpt", email: …, planType: "prolite"}`, `requiresOpenaiAuth: true`.
- `model/list` → `gpt-5.5` (default; efforts low/med/high/xhigh; text+image), `gpt-5.4`, `gpt-5.4-mini`.
- `account/rateLimits/read` → primary 5 h window + secondary 7-day window, `usedPercent`, `resetsAt`, per-limit buckets, `planType`.
- `thread/start` with `ephemeral: true`, `sandbox: "read-only"` (kebab-case required; camelCase rejected `-32600`), `approvalPolicy: "never"` → ok, thread marked `ephemeral: true`.
- `turn/start` with `outputSchema` → 62 `item/agentMessage/delta` events, final `agentMessage` was strict schema-valid JSON, `turn/completed` in 9.1 s (gpt-5.4-mini, transcript-analysis prompt).
- Notifications observed: `thread/tokenUsage/updated`, `account/rateLimits/updated`, `mcpServer/startupStatus/updated`, `warning`.
- Probe scripts: `probe_appserver.py`, `probe_turn.py` (session scratchpad; worth committing under `scripts/codex-probe/`).
