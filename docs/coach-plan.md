# Coach, phase 1: see how you talk, and prove a habit stuck

Status: **built** on `feat/coach`, 2026-10-28, not yet released. Design: the
"Reimagined" page of the Orttaai Coach canvas
(https://claude.ai/artifact/RKkTB8p6yovmjjzh5EciMC). Phase 1 has no models:
everything is counted. Checked by rendering Today, Proof and the weekly card
from a copy of a real 3,361-dictation history: counting it all took 1.2 s
off the main thread, and each snapshot about 35 ms. First run and Settings ›
Coach were built but not rendered.

## Goal

Orttaai reads the dictations it already keeps, works out how the person talks
to AI, to people and when writing, and shows it as a voice shape. They can
start a habit on any counted measure, and Coach checks it on their real
dictations, with a fair comparison, until it can say whether it worked.

Done means:

- A **Coach** page in the sidebar. Opening it hides the main sidebar, shows
  Coach's slim rail and a floating glass tab bar with **Today** and **Proof**.
  Path, Studio, Scene and Cast arrive in phase 2.
- **Today**: the voice shape for Talking to AI, Talking to people and Thinking
  and writing, drawn over the shape from 4 weeks before, with one line on what
  moved most. Also this week's focus (the measure with most room, with Start
  this habit), the days you dictated this week, and "Caught in the wild" (the
  best recent dictation for your current habit).
- **Proof**: every habit as an experiment, with 20 dictations before against
  20 since as dots, the before and after numbers, a status (Watching, Working,
  Not moving) and, in the header, how much the skills you didn't practise
  moved.
- **Empty states**: Today draws the shape in as dictations arrive (it needs
  30), and Proof shows three habits picked from the person's own data.
- **First run**, three of the five designed steps: what Coach found, which apps
  it may read, and your first shape. The coach and model steps come in phase 2.
- **Weekly card**: the portrait card from the canvas, shared through the
  existing Milestones share sheet. It shows numbers only.

## Privacy rule

- Coach reads transcripts on this Mac only and stores no text of its own. Its
  tables hold numbers keyed by the dictation's id.
- Quotes ("Caught in the wild", the best example) are read live from the
  `transcription` table. Deleting a dictation deletes its metrics and its
  quote.
- Share cards never show dictated text, as for Milestones.
- Coach data is local and not synced in phase 1.
- Apps switched off in first run or Settings are never read.

## Counting the same way as Orttakey

Orttakey's Coach counts are pure Foundation code in its app target
(`orttakey/App/Coach/CoachStats.swift:59-198`, `CoachLessons.swift:67-126`),
and nothing tests them. Phase 1 moves them into a new package both apps can
use. Orttakey switches to it later, as a separate task in its own repo.

Rules ported exactly, with tests pinning each one:

- Every count reads the raw transcript (`rawText ?? text`), since Polish and
  the disfluency cleaner remove fillers. Rows from before `v18_raw_transcript`
  have only `text`, so their filler counts are marked lower-bound and left out
  of filler baselines.
- Words are whitespace-separated tokens. Edit commands don't count.
- um and uh: `\b(?:u+m+|u+h+m*|e+r+m+|h+m+)\b`, case-insensitive. The rate is
  per 100 words, and the goal is 1.0.
- Phrase fillers: "you know" (unless followed by what, how, that, why, when,
  where, who or if), "I mean", "like" next to a comma, "basically", "actually".
- Pace: words per minute of recording, only for at least 10 words and 5
  seconds. The typical pace is the median (`sorted[count/2]`) and the fast
  pace is the 75th percentile, which needs 4 or more paced dictations.
- Sentences: Orttakey's `Paragrapher.sentences` splitter, copied into the
  package. A sentence ends at `.`, `?` or `!` followed by a space or the end of
  the text, and the next character must be uppercase, a digit, a quote or `(`.
  The measures are the median and the longest sentence.
- Repeats: `\b(\w+)[\s,]+\1\b`, case-insensitive.
- Focus scores, used to pick this week's focus:
  - fillers: rate / 1.0, when the rate is above 1.0;
  - sentences: 0.9 × max(median / 14, longest / 40), when the median is above
    14. Orttakey also fires on one 40-word sentence; over 28 days of heavy
    dictation that almost always happens, so the Mac needs the typical
    sentence to run long too;
  - pace: 0.8 × fast pace / 160.

New on the Mac, where Orttakey has no equivalent:

- **Polish fixes**: the share of dictations where Polish or the dictionary
  changed more than 15% of the words (a word-level edit distance between
  `rawText` and `text`). This is a hint that the speaker restructures out loud.

## Ways of talking

`CoachMode` is `ai`, `people`, `writing` or `elsewhere`. It comes from
`targetAppBundleID` through a built-in table:

- **ai**: Claude, Codex, ChatGPT, Cursor, Windsurf, VS Code, T3 Code, cmux,
  Orttaai's own Chat AI, and terminals, because Claude Code and Codex CLI run
  there.
- **people**: Slack, Mail, Messages, WhatsApp, Telegram, Discord, Teams,
  Outlook.
- **writing**: Notes, Pages, Obsidian, Word, Notion, Bear.
- **elsewhere**: browsers, unknown apps, and dictations from Orttakey, which
  never knows the app.

The person can move any app between modes or switch it off, in first run step
2 and in Settings › Coach. "Elsewhere" is counted in the all-modes totals but
gets no shape of its own.

## The voice shape

The shape has six axes, the same in every mode so the shapes compare. Each
axis is scaled 0–1 by a fixed, documented function, where 1 is best:

| Axis | From | Full marks |
|---|---|---|
| Fewer fillers | um and uh per 100 words | 0 |
| Clean phrases | phrase fillers per 100 words | 0 |
| Pace | typical wpm | 130–160 |
| Short sentences | median sentence length | 14 words or fewer |
| No repeats | repeats per 100 words | 0 |
| Said it clearly | 1 − share needing Polish fixes | 1 |

"Now" is the last 28 days and the ghost outline is the 28 days before that,
for each mode. An axis needs at least 8 dictations in the window, otherwise it
shows as not yet known (the empty Today design). Phase 2 adds the judged axes
from the design (task first, context, finish line, ask first) once the judge
model is in.

## Habits and proof

- A habit is a measure plus a mode (or all modes).
- **Baseline**: the 20 dictations in that mode before the habit started.
- **Since**: the next 20, after which it settles. A habit can run longer, with
  rolling windows of 20.
- **Status**:
  - **Watching** while there are fewer than 20 dictations since it started.
  - **Working** when a seeded bootstrap of the median change (1,000 resamples)
    has a 90% interval that excludes zero in the good direction, and the change
    beats the control drift.
  - **Not moving** otherwise.
- **Control drift**: for the same windows, the median change of the measures
  not under any habit, shown as "Skills you didn't practise moved +2%".
- **Caught in the wild**: the most recent dictation since the start that meets
  the habit, with at least 12 words, quoted from `transcription`.

## Pieces

| Piece | File(s) | Notes |
|---|---|---|
| Package | `LocalPackages/CoachCore` | macOS 14 / iOS 17, Foundation only. `CoachMeasures`, `CoachSentences` (the Paragrapher copy), `CoachMode` plus the app table, `VoiceShape`, `HabitVerdict`. Tests for every rule above. |
| Store | `Data/DatabaseManager.swift` migration `v22_coach` | `coach_metric(transcriptionId PK → transcription ON DELETE CASCADE, metricsVersion, mode, words, umUh, phraseFillers, wpm, sentences, medianSentence, longestSentence, repeats, polishChangeRatio, rawKnown)`, `coach_habit(id, measure, mode, startedAt, status, closedAt)`. |
| Backfill | `Core/Coach/CoachIndexer.swift` | Off the main thread, in batches of 500. It recomputes rows whose `metricsVersion` is old, writes new rows as dictations land, and catches up after `cloudSyncDidComplete`. |
| Center | `Core/Coach/CoachCenter.swift` | Main-actor state the UI reads. It follows the `MilestoneCenter` pattern: watch transcriptions, evaluate off the main thread, publish the profile, shapes and habit verdicts. |
| Settings | `Data/AppSettings.swift` | `coachEnabled`, `coachAppOverrides` (bundle id → mode or off), `coachFirstRunDone`. |
| Navigation | `UI/Home/HomeNavigation.swift`, `HomeShellView.swift` | `HomeSection.coach`. While it's selected, the split view goes `.detailOnly` and Coach draws its own rail. |
| Shell | `UI/Coach/CoachShellView.swift`, `CoachRail.swift`, `CoachTabBar.swift` | Glass tab bar (`.glassEffect` on macOS 26, a thin material before it), with Today and Proof. |
| Today | `UI/Coach/CoachTodayView.swift`, `VoiceShapeView.swift` | The shape is a SwiftUI `Shape` with a ghost outline, a lens picker and axis labels. Plus the focus card, the week strip and Caught in the wild. |
| Proof | `UI/Coach/CoachProofView.swift` | Featured habit with dot strips, habit cards, the control-drift header with an ⓘ, and the empty state. |
| First run | `UI/Coach/CoachWelcomeView.swift` | Steps 1, 2 and 5. Skip goes straight to Today. |
| Weekly card | `UI/Milestones/ShareCards/CoachWeekCard.swift` | A new share subject, `.coachWeek`, in the existing sheet. |
| Settings page | `UI/Settings/CoachSettingsView.swift` | Coach on or off, and apps by mode. ⓘ instead of descriptions. |

## Order of work

1. **CoachCore** with tests. Port the rules and add golden fixtures (about 40
   real-looking transcripts with expected counts). No app changes yet.
2. **Modes** and the app table, with tests, plus the override setting.
3. **Store and backfill**: migration `v22_coach`, the indexer and its tests.
   This includes cascade on delete, a `metricsVersion` bump to recompute, sync
   catch-up, and a bootstrap test against a database with 500,000 words so the
   backfill stays off the main thread and quick.
4. **Center**: profile, shapes, focus and habit verdicts, with tests for the
   windows, the 8-dictation minimum, the bootstrap (seeded) and control drift.
5. **UI**: the shell, Today, Proof, the empty states, first run and the weekly
   card. Each screen is rendered headlessly to PNG with `ImageRenderer` in a
   throwaway test and compared with the canvas.
6. **Settings › Coach**, then a Debug build on the real history, checked by
   eye.
7. **Release**: up to three What's New highlights in `WhatsNewCatalog.swift`,
   then the usual notarized release.

## Not in phase 1

Models, Studio, Reveal, Scene, Path, Cast, the Models page, judged axes,
personalities, voice, iCloud sync of Coach data, and Orttakey adopting
CoachCore.
