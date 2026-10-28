# Coach voices

Scene partners can speak in natural voices of their own. They're made on the
Mac by Pocket TTS (Kyutai, CC BY 4.0, Core ML conversion by FluidInference),
which Orttaai runs through FluidAudio with its `TTS` trait on. The voice model
(about 520 MB) downloads into the model folder from Cast › Models; until then,
and whenever it can't speak, Coach uses the Mac's own voice.

A voice is a Pocket TTS voice file (`.pocketvoice`, about 450 KB) in
`Orttaai/Resources/CoachVoices/`, listed in `CoachNaturalVoice.voices`.

## Consent

Every voice that ships is cloned from a recording of someone who agreed to it.
Never add a voice cloned from anyone who hasn't, and never from a public
figure. Phonon's and Kyutai's terms both require this.

| Voice | Speaker | Recorded | Consent | Source |
|---|---|---|---|---|
| Ola | Olanrewaju Oyinbooke, the developer | 2026-10-28, Hollyland wireless mic, 48 kHz | Spoken consent recorded the same day, kept privately with the takes (not in the repo) | Take 1 of 3: "Good morning! Thanks for making time today…", 8.7 s |

## Making a voice

1. Record 8–10 seconds of clean speech; the cloner uses at most 10 s.
2. Clone it with FluidAudio:
   `fluidaudiocli tts "A test line." --backend pocket --clone-voice take.wav --save-voice voice.bin`
3. Listen, then copy the file into `Orttaai/Resources/CoachVoices/<name>.pocketvoice`
   and add the speaker to `CoachNaturalVoice.voices`.

Phonon 31M (Apache-2.0) sounds better and is far smaller, but it can't clone
on the Mac: its speaker encoder isn't released, and a voice made in Gradium's
studio may not be shipped in an app under Gradium's terms. Never ship any
Phonon 40M model; they're non-commercial.
