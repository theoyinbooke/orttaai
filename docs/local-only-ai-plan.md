# Local-only AI: remove cloud providers

Status: **done**, 2026-10-23, on `feat/express-engine`. See "Outcome" at the end for what shipped and where it differs from this plan.

## Goal

Every AI feature in Orttaai (chat, insights, Memory Graph, polish, tone of voice, semantic memory) runs on models on the user's own hardware, through **Ollama** or **LM Studio** (including LM Studio's **Bionic** app). No code path can send dictation text to a cloud model.

Done means:

- `LocalLLMProviderKind` has two cases, `ollama` and `lmStudio`, and nothing else can be selected.
- The Codex and Grok clients, their settings cards, sign-in flows, subprocess spawning and tests are gone.
- An LM Studio or Bionic server never hands Orttaai a cloud ("Secure Cloud") model, even when the user has one pinned.
- Existing installs on ChatGPT (Codex) or Grok move to a working local setup on first launch, with models that are actually installed.
- A guard test and a source check fail the build if a cloud provider comes back.
- All unit tests pass and the manual matrix below is green.

## What exists today

### Cloud AI to remove (about 3,250 lines)

| Area | Files | Notes |
|---|---|---|
| ChatGPT (Codex) client | `Core/Codex/CodexClient.swift`, `CodexAppServerConnection.swift`, `CodexAccountService.swift` | Spawns the `codex` app-server subprocess and signs in through ChatGPT. |
| Grok client | `Core/Grok/GrokClient.swift` | Spawns the `grok` CLI. |
| Settings UI | `UI/Settings/CodexSettingsCard.swift`, `GrokSettingsCard.swift`, provider rows and cloud model menus in `ModelSettingsView.swift` | Includes the cloud consent copy. |
| Provider enum | `Core/Transcription/LocalLLMProvider.swift` | `codex` and `grok` cases; the `isLocal`, `usesHTTPEndpoint` and `supportsEmbeddings` branches exist only because of them; `LocalLLM.codexClient` and `grokClient`. |
| Settings | `Data/AppSettings.swift` | `codexModel`, `codexReasoningEffort`, `codexConsentAcknowledged`, `grokModel`, `grokConsentAcknowledged`, `lastLocalLLMProvider`, `localFallbackLLMProvider`, the cloud branches of the insights and summary model getters, and the embedding and polish "fallback provider" indirection. |
| Call sites | `AppDelegate.swift` (Codex app-server shutdown, warm-up guard), `SemanticMemoryView.swift` (cloud notice), `WritingInsightsService.swift` (provider label, cloud context size), `SemanticMemoryService.swift` (comment), `ChatAIView.swift` (nothing cloud-specific; it follows the provider) | |
| Tests | `CodexClientTests`, `CodexIntegrationTests`, `GrokClientTests`, `GrokIntegrationTests` | The Grok integration test calls the live service and failed once on 2026-10-23 with "max turns reached". |
| Docs | `docs/codex-chatgpt-integration-plan.md`, `TESTING.md` (ChatGPT row), `docs/insights-engine-vision.md` | |

### Not cloud AI: stays

- **Codex as a target app.** `TextInjectionService.codexBundleID` and its tests handle pasting into the Codex desktop app. This concerns where text goes, not which AI runs.
- **"codex" as a keyword or app name** in `WorkActivity.swift` and `InsightPatternEngineTests`.
- **Apple Intelligence** (`AppleIntelligencePolishProcessor`, `MemoryLearningService`). The Foundation Models framework runs on-device. It stays as the fallback when no local server is running.
- **iCloud sync** (`Core/Sync`). This syncs the user's own data between their Macs, not AI.
- **Model downloads**: Whisper and Express from Hugging Face, `ollama pull`. These fetch weights, not inference.

### Your machine today (2026-10-23)

- The **installed app is on `localLLMProvider = codex`**, with insights on.
  - Its insights and summary model is `qwen3.5:0.8b`, which is in LM Studio but **not in Ollama**.
  - A naive switch to Ollama would therefore point insights at a missing model. The migration has to repair this.
- **Ollama** is running on 11434 with these chat models: `gemma4:e2b`, `qwen3:1.7b`, `qwen3:0.6b`, `smollm2`, `gemma4:26b`, `clef-flash`, `nimble`.
- **LM Studio** and **Bionic 1.1.7** are installed, with 24 local models (`qwen3.5-0.8b`, `qwen3.5-2b`, `qwen3-8b`, `gemma-4-26b-a4b`, `gpt-oss-120b` and more). Their server is off.
- **Bionic's server is LM Studio's server.** Its logs show it listening on **port 1234** with the same endpoints:
  - OpenAI-compatible: `/v1/models`, `/v1/chat/completions`, `/v1/embeddings`, `/v1/responses`.
  - Native: `/api/v1/models`, `/api/v1/models/load`, `/api/v1/models/download`.

  Orttaai's existing LM Studio provider already reaches Bionic's local models. There is no separate API to integrate.
- **Bionic also has cloud models.** Seven LM Studio Secure Cloud models are listed in `~/.lmstudio/apps/bionic/.internal/ng-cloud-models.json`: GLM-5.2, GLM-5.3, GLM-5.3-Flash, Kimi K3, DeepSeek V4 Pro, DeepSeek V4 Flash and DeepSeek V4.1 Flash. They are billed to an LM Studio account. If the server lists them, Orttaai must not offer them.
- **LM Link** lets LM Studio serve models running on another of the user's machines.

## Decisions

| # | Decision | Default in this plan |
|---|---|---|
| D1 | LM Studio and Bionic: one provider or two? | **One provider**, "LM Studio", whose health line says "LM Studio (Bionic)" when Bionic is the one serving. They share one server and one model library. |
| D2 | LM Link models (your other machines) | **Allowed**, labelled "on <device>". They are your hardware, not a cloud. Change to "excluded" if you want this Mac only. |
| D3 | Secure Cloud models in LM Studio or Bionic | **Never listed, never used.** |
| D4 | Where Codex and Grok users land | Ollama if it's running and has a chat model, else LM Studio if it's running, else Ollama with a "start Ollama" prompt. |
| D5 | Recommended local models | **Ollama**: chat, insights and summary use `gemma4:e2b`; polish uses `gemma4:e2b`; embeddings use `all-minilm` or `nomic-embed-text`. **LM Studio**: the closest installed equivalent. |

## Phases

### Phase 0: prepare and verify (no behaviour change)

- **P0.1** Commit the current uncommitted UI work as its own commits. It touches `ChatAIView`, `WritingInsightsService` and `CodexClient.onThinking`, so the removal then lands as clean, separate commits.
- **P0.2 Verify what the LM Studio server lists.** Start the server from LM Studio and then from Bionic (`lms server start`, or the Developer tab). Save the `/v1/models` and `/api/v1/models` responses as test fixtures, with:
  - (a) local models only;
  - (b) a Secure Cloud model pinned in Bionic;
  - (c) an LM Link device, if available.

  Record which field marks a cloud or remote entry. This sets how P3.2 filters. If cloud models never appear in the server's lists, P3.2 becomes a guard plus a test.
- **P0.3** Write down your current provider settings as the migration test case. The values are in "Your machine today" above.

**Exit:** fixtures saved; filter rule chosen.

### Phase 1: remove the cloud providers

- **P1.1 Delete files.**
  - `Core/Codex/` (3 files) and `Core/Grok/GrokClient.swift`.
  - `UI/Settings/CodexSettingsCard.swift` and `GrokSettingsCard.swift`.
  - The four Codex and Grok test files.
- **P1.2 Narrow `LocalLLMProviderKind`** to `ollama` and `lmStudio`. Remove `isLocal`, `usesHTTPEndpoint` and `supportsEmbeddings`, which become always true, and every branch on them. `LocalLLM` keeps two clients.
- **P1.3 Simplify `AppSettings`.**
  - Remove the Codex and Grok keys and getters, `lastLocalLLMProvider` and `localFallbackLLMProvider`.
  - `embeddingLLM*` and `polishLLM*` collapse to the active provider: keep them as plain aliases, or inline them at the call sites.
  - `normalizedLocalLLMInsightsModel` and `normalizedSemanticInsightSummaryModel` lose their cloud branches.
  - `localSemanticInsightModel` merges into the summary model.
- **P1.4 Update the call sites.**
  - `ModelSettingsView`: two-option provider picker, no cloud rows or menus, new copy: "AI runs on this Mac through Ollama or LM Studio (including Bionic)".
  - `SemanticMemoryView`: drop the cloud notice and its stored-provider fallback.
  - `WritingInsightsService`: one label, the local context size only.
  - `AppDelegate`: drop the Codex app-server shutdown; the warm-up guard always applies.
  - `SemanticMemoryService`: update the comment.
- **P1.5** Keep the Codex target-app paste handling and its tests unchanged.

**Exit:** builds; tests pass, minus the deleted ones; no symbol contains `Codex` or `Grok` outside text insertion.

### Phase 2: migrate existing installs

- **P2.1 One-time migration** at launch, behind `aiProviderMigrationVersion = 1`. If the stored provider is `codex`, `grok` or unrecognised, choose per D4. Then delete the obsolete keys:
  - `codexModel`, `codexReasoningEffort`, `codexConsentAcknowledged`;
  - `grokModel`, `grokConsentAcknowledged`;
  - `lastLocalLLMProvider`.
- **P2.2 Repair models.** For insights, summary, polish and embeddings, if the configured model isn't installed on the chosen provider, fall back in this order:
  - (a) the configured polish model, if installed;
  - (b) the recommended model per D5, if installed;
  - (c) the smallest installed chat model.

  This fixes the installed app's `qwen3.5:0.8b` on Ollama.
- **P2.3 Tell the user once.** Model settings shows a dismissible note: "ChatGPT and Grok are no longer supported. Orttaai now uses <provider> on this Mac."
- **P2.4** Old insight reports and history labelled "ChatGPT (Codex)" still load and display. They are plain strings; add a test.
- **P2.5** Leave the Codex CLI's own `~/.codex` sign-in alone. Orttaai never owned it.

**Exit:** a copy of the installed app's defaults migrates to Ollama with `gemma4:e2b` for insights, verified by test and by hand.

### Phase 3: LM Studio and Bionic, done properly

- **P3.1 List models through LM Studio's native `/api/v1/models`** when it answers, falling back to `/v1/models` for other OpenAI-compatible servers (llama.cpp, mlx_lm.server). The native list gives:
  - model type (LLM vs embedding), so the embedding picker only shows embedding models;
  - loaded state, for a "loaded" badge and faster first replies;
  - origin (local, LM Link, cloud) for P3.2.
- **P3.2 Local-only guard.**
  - Drop any model the server marks as cloud, using the field found in P0.2.
  - Before every request, the client already checks the model id against the cached list. Extend that check to refuse ids that aren't local, with a clear error.
  - Add unit tests using the P0.2 fixtures.
- **P3.3 Recognise Bionic.**
  - When LM Studio's server answers and Bionic (`ai.elementlabs.bionic`) is running, the health line reads "LM Studio (Bionic) · N local models".
  - The "not reachable" hint mentions all three ways to start the server: LM Studio's Developer tab, Bionic, and `lms server start`.
- **P3.4 LM Link** per D2: remote models get an "on <device>" label in the model menus.
- **P3.5 Endpoint.** The default stays `http://127.0.0.1:1234`, and the endpoint field still accepts another host (a Mac on the LAN or an LM Link setup).

**Exit:** with Bionic serving and a Secure Cloud model pinned, Orttaai lists and uses only local (and LM Link) models.

### Phase 4: local models doing all the work

- **P4.1 Defaults** per D5 for new installs. In AI settings, offer an Ollama download for the recommended model when it's missing (pull already exists). For LM Studio, link to its download page instead.
- **P4.2 Re-check the heavier jobs on local models,** with fixed timeouts and token caps:
  - Insights: measured at 2.6 s on `gemma4:e2b`.
  - Activity reading, Graph summary, and chat with memory context.
  - `WritingInsightsService`'s context size, now always local.
- **P4.3 No provider running.** Each AI feature shows one consistent "Start Ollama or LM Studio" state. The heuristic and Apple Intelligence fallbacks keep insights and polish usable.
- **P4.4 Setup.** The AI step in first-run setup detects which provider is running and preselects it. No cloud option.

**Exit:** each feature works on Ollama alone, on LM Studio alone, and on Bionic alone.

### Phase 5: guard, docs, release

- **P5.1 Guard test.**
  - Assert that `LocalLLMProviderKind.allCases == [.ollama, .lmStudio]`.
  - Assert that no source file under `Orttaai/Core` spawns a `Process` other than the permission helper.
  - A small script, `scripts/check-local-only-ai.sh`, fails on cloud AI hosts or CLI names outside the allow-list (text insertion's Codex bundle id, keyword lists). It's listed in `TESTING.md`.
- **P5.2 Docs.**
  - Move `docs/codex-chatgpt-integration-plan.md` to `docs/archive/`.
  - Update `insights-engine-vision.md`.
  - Replace the ChatGPT row in `TESTING.md` with Ollama, LM Studio and Bionic rows.
  - The release notes say cloud AI was removed and that everything runs locally.
- **P5.3 Manual matrix:**
  - (1) Ollama only;
  - (2) LM Studio only;
  - (3) Bionic serving, with a Secure Cloud model pinned;
  - (4) nothing running;
  - (5) migrating from a copy of the installed app's Codex settings.

  Cover chat, chat with memory, insights, Activity reading, Graph insights, polish and tone of voice.
- **P5.4** Full unit suite, a Release build, and a check that the app size drops as expected.

**Exit:** all green; release notes ready.

## Order and size

Phases run in order, each as its own commit or commits:

| Phase | Commit(s) | Size |
|---|---|---|
| P0 | No code. | Under an hour. |
| P1 | One commit. | Mostly deletions, about 3,250 lines out. |
| P2 | One commit. | Migration and tests. |
| P3 | One or two commits. | Native listing, guard and Bionic label. |
| P4 | One commit. | Defaults and empty states. |
| P5 | One commit. | Guard, docs, matrix. |

## Risks

- **The installed app loses insights quietly** if migration picks a model that isn't installed. P2.2 and its test cover this.
- **LM Studio's native API shape changes between versions.** Keep `/v1/models` as the fallback and parse the native list leniently.
- **Secure Cloud models appear under ordinary ids.** P0.2 decides the filter. If the server gives no marker, filter against the server's own cloud list or require `/api/v1/models` to report the model as local.
- **Small local models give weaker chat answers than ChatGPT did.** Mitigate with D5 defaults, the memory-answer rules already in chat, and letting users pick larger models (`gemma4:26b` and `gpt-oss-120b` are already on this Mac).

## Outcome (2026-10-23)

All phases done. Unit tests and the guard pass.

What P0.2 found:
- **LM Studio 0.4's server lists only models on disk.** `/v1/models` and the native `/api/v1/models` both returned the same 24 local models. None of Bionic's seven Secure Cloud models appeared.
- **What the native list gives:** `type` (llm or embedding), `size_bytes`, `format` and `loaded_instances`. Its keys match the request IDs exactly.

The guard therefore keeps an LM Studio model only when the native list reports files on disk (`LocalModelPolicy.isLocalLMStudioEntry`). A hosted model is refused before any request, even if a later LM Studio starts listing hosted models.

Ollama got the same treatment, which the plan had missed:
- Its `-cloud` models (named `…-cloud` or `:cloud`, with `remote_host` set) run on ollama.com.
- They are dropped from the list, and every Ollama request path refuses them before sending: generate, chat, stream, embed, pull and warm.

Where the result differs from the plan:
- **The P5.1 guard is a unit test, not a shell script.** `LocalOnlyAIGuardTests` scans `Orttaai/` for cloud AI hosts, the removed providers' names and spawned processes. It runs with every test pass, so a separate script would only duplicate it.
- **Endpoints are guarded too.** `LocalModelPolicy.isAllowedEndpoint` lets both clients reach only this Mac or a private network: loopback, LAN, `.local`, Tailscale and IPv6 local. A cloud API URL typed into the endpoint field is refused.
- **P4.4 has no new setup screen.** The migration's second step also covers a fresh install that never chose a provider: it settles on whichever server is running and an installed model.
- **The migration repairs the embedding model too.** An LM Studio user moves from Ollama's `all-minilm` to an installed embedding model, such as `text-embedding-nomic-embed-text-v1.5`.
- **New defaults.** Insights and the graph summary now default to `gemma4:e2b`, the same model as polish, so a single model stays loaded.
- **P5.2 kept two docs.** The "ChatGPT" row in `TESTING.md` is the ChatGPT website as a paste target, and `insights-engine-vision.md` only uses "Codex" as an example app name. Neither is cloud AI.
- **P3.4 is not verified.** No LM Link device was set up on the development Mac, so LM Link entries couldn't be observed. If they report `size_bytes`, they are listed like any other local model. They get no device label yet.

### Release note

> Orttaai's AI now runs only on your own hardware. ChatGPT (Codex) and Grok are no longer supported. Chat, insights, Memory Graph, polish and tone of voice use Ollama or LM Studio, including LM Studio's Bionic app. Cloud models those apps can offer, such as Ollama's cloud models and LM Studio Secure Cloud, are never listed or used. If you used ChatGPT or Grok, Orttaai switches to the local server it finds running and picks installed models for each feature, then tells you once in Settings › Model › AI Features.
