# Sound anchors on the Mac

Branch `feat/sound-anchors`, 2026-11-24. Ported from Orttakey for iPhone, with the same rules and numbers. The full design and how it was measured are in Orttakey's `Docs/SoundAnchors.md`.

## The problem

The owner's product is Eimailar, said like "emailer". Express writes "email".

- Fixing it by hand made an "email → Eimailar" dictionary suggestion. Once accepted, every "email" the owner said became Eimailar.
- Fixing it back made the reverse rule, and everything flipped again.

Only the sound can tell the two words apart.

## How it works now

**1. At transcription (ExpressTranscriber).** After Word Boost, every place Express wrote an anchor's heard word ("email") is scored against the recording:
- Word Boost's CTC frames give the score: the phrase as written against the same phrase with your word in it, with context on both sides.
- The heard word becomes your word only above a line.
- Where the check kept the word, the words around it are heard again slowed to 60% and 70%, with pitch kept. A fast Eimailar whose ending was swallowed is often heard then.
- Spellings of your word's sound that aren't English words ("emailer", "Emila", "Emaila") count as your word.
- Word Boost leaves any word with an anchor to the sound. Its guard gained the iPhone's rules: one everyday word is never swapped, and "email or" needs clearly better sound.

**2. Learning (SoundAnchorLearning).** The edit watcher already compared the field before and after. When a watch ends, the learner now sees every change to the dictation:

| What you did | What it learns |
|---|---|
| Changed an everyday word to a dictionary word, or to the heard word plus a lost ending ("email" → Eimailar, "email" → emailer) | Learned from that recording's sound. The last 3 recordings are kept in memory for 10 minutes, never on disk. No rule is suggested; a new word is suggested as itself. |
| Changed your word back where the sound wrote it | The line moves up. A spelling put back is never used again. No reverse rule. |
| Left an "email" the sound kept as it was | One of your own "email"s. With three, the line sits 1.5 above your highest one. |

**3. Dictionary pairs.** A pair from one everyday word to another word ("email → Eimailar") is decided by the sound while Express with Word Boost is loaded. Pairs from a non-word ("Tematope → Temitope") stay text rules. Without the sound model, pairs work as before.

**4. Starting guesses.** A dictionary word spelled like an everyday word plus an ending (Eimailar = "email" + "ar") gets an anchor before any fix.

**5. Storage.** Anchors are kept in `sound-anchors.json` next to the database, in Application Support/Orttaai or Orttaai Debug. They are never synced and hold no audio. Deleting a dictionary word forgets what it taught.

## Measured on the owner's own voice

The test is `SoundAnchorOwnVoiceTests` (opt-in `ORTTAAI_SOUND_OWN=1`). It uses the owner's 16 recordings and the real Express models from the external drive.

| Stage | Eimailar written right | Plain "email" changed |
|---|---|---|
| Before any fix | 8/10 | 0/6 |
| After one fix | 8/9 | 0/6 |
| After one fix + 3 kept emails | 9/9 | 0/3 |

The owner's 50 real-voice recordings (gauntlet `corpus_real`) with the learned line: **0 of 50 changed**.

Two things this run found and fixed:
- **The line was too close.** At 0.25 above the highest kept "email", "no email until the evening" (−4.89) was changed. It is now 1.5 above.
- **The line could fall far below a weak fix.** Found by the Windows and Linux port, on a voice whose kept "email"s scored near −11 against a fix at −3: the line went to −7.2 and an "email" at −5.7 was changed. The line now stays within 1.5 of your weakest fix (never above 0 for it). The owner's numbers above are unchanged.
- **No anchor reached the transcriber.** From async code, Swift picked the protocol's async do-nothing defaults over the transcriber's plain methods. Those methods are now `async`.

## Testing

`xcodebuild test` hangs on the external drive. Use the direct-launch recipe in `docs/coach-plan.md`, "Testing note". 1173 tests pass (with the voice-edit fixes merged from `fix/voice-edit`).
