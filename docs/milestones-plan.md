# Milestones: badges, celebrations and share cards

Status: **in progress** on `feat/milestones`, from the approved design canvas
(Orttaai Milestones, 2026-10-24).

## Goal

Orttaai notices when someone reaches a milestone, celebrates it once, keeps a
wall of badges, and turns any badge or their stats so far into a branded card
they can save, copy or share. Cards make the numbers mean something (heights,
books, speed, hands-free time) and carry the tagline "Giving you back both
hands."

Done means:

- A **Milestones** page in the sidebar: next goal with progress, three summary
  tiles, filters (All, Unlocked, In progress, Locked) and a grid of 22 badges.
- Badges unlock from numbers Orttaai already keeps, stay unlocked once earned,
  and record the date of the dictation that earned them.
- A **corner toast** right after the dictation that unlocks something, and a
  **celebration** the next time the Orttaai window opens, paging through
  everything new. Both respect Reduce Motion and a "Celebrate milestones"
  switch in Settings › General.
- A **share sheet** with eight templates behind arrow buttons, three sizes
  (Portrait 4:5, Square, Story 9:16), Save image, Copy and Share… (the macOS
  share picker).
- Cards and badges never show anything the person dictated: numbers only.

## Privacy rule

The engine reads word counts, durations, dates, app names and the dictionary
entry count. It never stores or renders transcript text. App names are counted,
never printed on a card.

## Pieces

| Piece | File(s) | Notes |
|---|---|---|
| Catalog | `Core/Milestones/MilestoneCatalog.swift` | 22 badges in five families (Words, Streaks, Speed & time, Dictations, Special), bronze/silver/gold tiers, SF Symbol icons, thresholds. |
| Stats | `Core/Milestones/MilestoneStats.swift` | Pure: replays dictations oldest first, totals, streaks (local days), best WPM, time saved, apps, longest dictation, night owl. Records when each threshold was first crossed. |
| Comparisons | `Core/Milestones/MilestoneComparisons.swift` | Height at 1.2 cm a printed word, pages at 250 words, key presses at 5.7 a word, typing at 40 WPM, handwriting at 13 WPM, landmarks and books. |
| Store | `Data/DatabaseManager.swift` migration `v16_milestones` | `milestone_unlock(badgeID PK, unlockedAt, celebratedAt)`. Durable: deleting history never takes a badge back. Local only (not synced). |
| Center | `Core/Milestones/MilestoneCenter.swift` | Main-actor state the UI reads. Watches transcriptions, re-evaluates off the main thread, writes new unlocks, decides toast versus celebration. |
| Page | `UI/Milestones/MilestonesView.swift`, `MilestoneBadgeView.swift` | Badge drawn natively: ring, dotted tier ring, progress arc, SF Symbol. |
| Celebration | `UI/Milestones/MilestoneCelebrationView.swift` | Overlay in the home window; rays, pulse, rising brand bars, scattered pieces. |
| Toast | `UI/Milestones/MilestoneToastController.swift` | Non-activating panel at the top right for 6 s. Never in the recording pill. |
| Cards | `UI/Milestones/ShareCards/*.swift` | Mountain, Books, Speedometer, Hands Free, Receipt, Signal, Editorial, Medal; one data model, three sizes. |
| Share | `UI/Milestones/MilestoneShareSheet.swift`, `ShareCardRenderer.swift` | `ImageRenderer` at 1× to exact pixel sizes; PNG save, pasteboard copy, `NSSharingServicePicker`. |

## Rules worth pinning in tests

- Words are whitespace-separated tokens, as on the dashboard. Edit commands
  do not count as dictations.
- Best WPM only counts dictations of at least 10 words and 3 seconds, so a
  clipped two-word note cannot unlock Lightning.
- A streak counts local calendar days with at least one dictation; the badge
  uses the best streak ever, so a broken streak keeps its badge.
- Time saved = typing time at 40 WPM minus time spent speaking, never below 0.
- On first launch of this version, everything already earned unlocks with its
  historical date and is offered in one celebration ("1 of N new"); the toast
  only appears for a badge earned by a dictation in the last two minutes.

## Order

1. Catalog, stats, comparisons and their tests.
2. Migration, store and center, with tests.
3. Milestones page and badge drawing; sidebar entry.
4. Celebration overlay and corner toast; Settings switch.
5. Eight cards, renderer and share sheet.
6. Headless renders of each card and size checked by eye, full suite, commit.
