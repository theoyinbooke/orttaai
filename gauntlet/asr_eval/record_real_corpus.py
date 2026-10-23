#!/usr/bin/env python3
"""Records the real-voice ASR eval corpus (tracker task P0.4): 50 sentences read
in the user's own voice, saved as 16 kHz mono Float32 WAV in corpus_real/ with
manifest_real.json in the same schema as manifest.json, so run_eval.sh,
fluidbench and score.py read it like the synthetic corpora.

corpus_real/ holds the user's voice: it is git-ignored. Never commit it.

Groups (id prefix == category):
  real-pn     names, mostly Yoruba and Igbo, in ordinary sentences
  real-tech   product names and code identifiers
  real-num    amounts, times, dates, phone and version numbers
  real-ev     everyday dictation and prompts to AI assistants
  real-long   20-35 s multi-sentence passages
  real-bg     another voice in the room: play talk radio, a podcast or a video
              from speakers at conversation volume, or have someone talk nearby
  real-soft   the last word or two trail off quietly, but are still said

hard_terms are drawn from the same 36-term bias_vocabulary as the synthetic
corpus, so the dictionary pass and Word Boost results stay comparable.

Usage:
  python3 gauntlet/asr_eval/record_real_corpus.py list            # print the script
  python3 gauntlet/asr_eval/record_real_corpus.py record [--only ID]
  python3 gauntlet/asr_eval/record_real_corpus.py status

`record` walks through every sentence not yet recorded (resume any time; --only
re-records one item). For each: press Enter to start, read the sentence, press
Enter to stop. Then Enter keeps it, p plays it back, r records it again, q quits.

Takes come from the Mac's current input device (System Settings > Sound >
Input) through record_take.swift, compiled once into corpus_real/.bin/. It uses
AVAudioEngine rather than ffmpeg's avfoundation input, which breaks when a
wireless microphone changes format mid-session. Needs the Xcode command line
tools, ffmpeg (for level checks) and microphone access for the terminal app.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT_DIR = HERE / "corpus_real"
MANIFEST = OUT_DIR / "manifest_real.json"
SAMPLE_RATE = 16_000
SILENT_PEAK_DB = -40.0

GROUP_NOTES = {
    "real-pn": "Names. Say them the way you normally would.",
    "real-tech": "Product names and code identifiers. Say identifiers as you would to a colleague.",
    "real-num": "Numbers. Read digits naturally: \"two thousand four hundred fifty dollars\", \"six forty-five a m\".",
    "real-ev": "Everyday dictation. Your normal pace.",
    "real-long": "Long passages. Keep going through small pauses, as in real dictation.",
    "real-bg": "BACKGROUND VOICE: start a podcast, talk radio or video from your speakers at "
               "conversation volume (or have someone talk nearby) before you press Enter.",
    "real-soft": "QUIET ENDING: let the last word or two trail off quietly, but still say them.",
}

# (id, reference, hard_terms)
SENTENCES: list[tuple[str, str, list[str]]] = [
    ("real-pn-01", "Olanrewaju will review the onboarding flow before Friday's release.", ["Olanrewaju"]),
    ("real-pn-02", "Please send the signed contract to Oyinbooke and copy the finance team.", ["Oyinbooke"]),
    ("real-pn-03", "Adebayo and Temitope are leading the community meetup in Lagos next month.", ["Adebayo", "Temitope"]),
    ("real-pn-04", "Folasade asked whether we can move the design review to Thursday afternoon.", ["Folasade"]),
    ("real-pn-05", "Babatunde confirmed the venue, and Yemisi is handling the guest list.", ["Babatunde", "Yemisi"]),
    ("real-pn-06", "Chimamanda shared her notes on the first chapter this morning.", ["Chimamanda"]),
    ("real-pn-07", "Ngozi wants a short summary of the survey results by Monday.", ["Ngozi"]),
    ("real-pn-08", "Oluwaseun is presenting the quarterly numbers at the all hands.", ["Oluwaseun"]),
    ("real-pn-09", "Remind me to call Temitope after the standup about the hiring plan.", ["Temitope"]),
    ("real-pn-10", "Orttaai turned my voice note into a clean email for Olanrewaju in seconds.", ["Orttaai", "Olanrewaju"]),

    ("real-tech-01", "The WhisperKit decoder reads promptTokens from the DecodingOptions struct.", ["WhisperKit", "promptTokens", "DecodingOptions"]),
    ("real-tech-02", "Persistence goes through GRDB, and every migration has a test.", ["GRDB"]),
    ("real-tech-03", "Run the Qwen model locally with Ollama or LM Studio before you ship.", ["Qwen", "Ollama", "LM Studio"]),
    ("real-tech-04", "The settings screen is written in SwiftUI and builds cleanly in Xcode.", ["SwiftUI", "Xcode"]),
    ("real-tech-05", "Sparkle reads the appcast after every release goes out.", ["Sparkle", "appcast"]),
    ("real-tech-06", "Use kubectl to check the pods before you restart the Kubernetes cluster.", ["kubectl", "Kubernetes"]),
    ("real-tech-07", "The useEffectCallback hook reconnects the WebSocket when the token changes.", ["useEffectCallback", "WebSocket"]),
    ("real-tech-08", "Move the PostgreSQL queries into the TypeScript service and run npm test.", ["PostgreSQL", "TypeScript", "npm"]),
    ("real-tech-09", "Lower the noSpeechThreshold and set the chunkingStrategy to use EnergyVAD.", ["noSpeechThreshold", "chunkingStrategy", "EnergyVAD"]),
    ("real-tech-10", "finalizeLiveTranscription waits until committedSampleCount catches up with the buffer.", ["finalizeLiveTranscription", "committedSampleCount"]),

    ("real-num-01", "The invoice is $2,450 and it is due on March 15th.", []),
    ("real-num-02", "Our flight leaves at 6:45 am on Tuesday, October 28th.", []),
    ("real-num-03", "Call me back at 555-0143 after 3 pm.", []),
    ("real-num-04", "Version 1.11.1 fixed 14 bugs and cut startup time by 30%.", []),
    ("real-num-05", "We need 250 chairs, 40 tables and 12 microphones for the event.", []),
    ("real-num-06", "The meeting moved from April 3rd to April 17th at 10:30 am.", []),

    ("real-ev-01", "Can you rewrite this paragraph so it sounds friendlier but keep it short?", []),
    ("real-ev-02", "Summarize the three main risks in this proposal and suggest one fix for each.", []),
    ("real-ev-03", "I'm running a little late, start without me and I'll join in ten minutes.", []),
    ("real-ev-04", "Thanks for the update, let's pick this up again tomorrow morning.", []),

    ("real-long-01", "Here is the plan for this week. Olanrewaju wants the beta ready by Thursday, so the "
                     "remaining bugs need owners today. The crash when the app resumes from sleep is the top "
                     "priority. After that, Folasade will look at the memory growth in the history view. Please "
                     "run the profiler before and after every change, and flag anything risky in the channel first.",
     ["Olanrewaju", "Folasade"]),
    ("real-long-02", "Quick update on the speech work. Orttaai Express decodes a whole dictation in a few "
                     "milliseconds, then Word Boost checks dictionary words against the audio. On our test set it "
                     "fixed most of the names that Whisper missed. The next step is a guard, so ordinary words like "
                     "code and release are never swapped for product names.",
     ["Orttaai"]),
    ("real-long-03", "Notes from the call with Adebayo. The Kubernetes migration is on track, but the PostgreSQL "
                     "backups still run on the old cluster. He wants a written plan by Monday, with a rollback step "
                     "for every change. Temitope offered to review it, and we agreed to test everything on staging "
                     "first.",
     ["Adebayo", "Kubernetes", "PostgreSQL", "Temitope"]),
    ("real-long-04", "Personal reminder for the weekend. Pick up groceries on Saturday morning, call my mum in the "
                     "afternoon, and finish the slides for the community meetup. On Sunday I want a slow start, a "
                     "long walk, and no email until the evening.",
     []),
    ("real-long-05", "Feedback for the desktop app. The Tauri build feels fast, but the settings page still shows "
                     "camelCase labels like noSpeechThreshold that users will not understand. Rename them in plain "
                     "English, keep the old keys in the config, and ship it behind a flag.",
     ["Tauri", "camelCase", "noSpeechThreshold"]),

    ("real-bg-01", "Please ask Oluwaseun to send the final budget before lunch.", ["Oluwaseun"]),
    ("real-bg-02", "Add a note that the Ollama server must be running before the demo.", ["Ollama"]),
    ("real-bg-03", "Book a table for 6 people at 7:30 pm on Friday.", []),
    ("real-bg-04", "Ngozi said the survey link is broken on mobile, can you check it today?", ["Ngozi"]),
    ("real-bg-05", "Merge the SwiftUI branch after the tests pass in Xcode.", ["SwiftUI", "Xcode"]),
    ("real-bg-06", "I think we should push the launch by one week and tell the beta testers today.", []),
    ("real-bg-07", "Send Yemisi the WebSocket logs from last night's outage.", ["Yemisi", "WebSocket"]),
    ("real-bg-08", "Let's keep the meeting short and focus on the hiring plan.", []),
    ("real-bg-09", "Babatunde wants the appcast updated before the release goes out.", ["Babatunde", "appcast"]),
    ("real-bg-10", "Write down that Chimamanda prefers the earlier deadline.", ["Chimamanda"]),

    ("real-soft-01", "Let's talk about this again after the conference.", []),
    ("real-soft-02", "I'll send you the draft later this evening.", []),
    ("real-soft-03", "Don't forget to water the plants before you leave the house.", []),
    ("real-soft-04", "We should grab dinner sometime next week.", []),
    ("real-soft-05", "Please remind me to call Folasade tomorrow.", ["Folasade"]),
]


def group_of(item_id: str) -> str:
    return re.sub(r"-\d+$", "", item_id)


def bias_vocabulary() -> list[str]:
    return json.loads((HERE / "corpus" / "manifest.json").read_text())["bias_vocabulary"]


def load_manifest() -> dict:
    if MANIFEST.exists():
        return json.loads(MANIFEST.read_text())
    return {"sample_rate": SAMPLE_RATE, "bias_vocabulary": bias_vocabulary(), "items": []}


def save_manifest(manifest: dict) -> None:
    order = {item_id: n for n, (item_id, _, _) in enumerate(SENTENCES)}
    manifest["items"].sort(key=lambda item: order.get(item["id"], len(order)))
    MANIFEST.write_text(json.dumps(manifest, indent=1) + "\n")


def probe(path: Path) -> tuple[float, float]:
    """Duration in seconds and peak level in dBFS."""
    out = subprocess.run(
        ["ffmpeg", "-hide_banner", "-nostats", "-i", str(path), "-af", "volumedetect", "-f", "null", "-"],
        capture_output=True, text=True,
    ).stderr
    duration = re.search(r"Duration: (\d+):(\d+):([\d.]+)", out)
    peak = re.search(r"max_volume: (-?[\d.]+|-inf) dB", out)
    seconds = int(duration[1]) * 3600 + int(duration[2]) * 60 + float(duration[3]) if duration else 0.0
    peak_db = float(peak[1]) if peak and peak[1] != "-inf" else -200.0
    return seconds, peak_db


def recorder_binary() -> Path:
    """record_take.swift compiled into the git-ignored corpus folder, rebuilt when the source changes."""
    source = HERE / "record_take.swift"
    binary = OUT_DIR / ".bin" / "record_take"
    if not binary.exists() or binary.stat().st_mtime < source.stat().st_mtime:
        binary.parent.mkdir(parents=True, exist_ok=True)
        print("  Building the recorder (once)…")
        subprocess.run(["swiftc", "-O", str(source), "-o", str(binary)], check=True)
    return binary


def record_one(path: Path) -> None:
    proc = subprocess.Popen(
        [str(recorder_binary()), str(path)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
    )
    if proc.stdout.readline().strip() != "READY":
        proc.wait()
        sys.exit("The microphone did not start. Check System Settings > Privacy & Security > Microphone.")
    input("  ● Recording… press Enter when you finish speaking. ")
    proc.communicate("\n")


def cmd_list(_: argparse.Namespace) -> None:
    current = None
    for item_id, reference, _ in SENTENCES:
        if group_of(item_id) != current:
            current = group_of(item_id)
            print(f"\n## {current}\n{GROUP_NOTES[current]}\n")
        print(f"{item_id}  {reference}")


def cmd_status(_: argparse.Namespace) -> None:
    done = {item["id"] for item in load_manifest()["items"]}
    missing = [item_id for item_id, _, _ in SENTENCES if item_id not in done]
    print(f"{len(done)} of {len(SENTENCES)} recorded in {OUT_DIR}")
    if missing:
        print("Still to record: " + ", ".join(missing))


def cmd_record(args: argparse.Namespace) -> None:
    OUT_DIR.mkdir(exist_ok=True)
    manifest = load_manifest()
    recorded = {item["id"] for item in manifest["items"]}
    todo = [s for s in SENTENCES if (s[0] == args.only if args.only else s[0] not in recorded)]
    if args.only and not todo:
        sys.exit(f"Unknown id {args.only}. Run `list` to see the ids.")
    if not todo:
        print("Everything is recorded. Use --only ID to redo one item.")
        return

    print(f"{len(todo)} to record. Read each sentence exactly as written; if you stumble, press r to redo.")
    current_group = None
    for index, (item_id, reference, hard_terms) in enumerate(todo, 1):
        if group_of(item_id) != current_group:
            current_group = group_of(item_id)
            print(f"\n=== {current_group}: {GROUP_NOTES[current_group]}")
        path = OUT_DIR / f"{item_id}.wav"
        while True:
            print(f"\n[{index}/{len(todo)}] {item_id}\n\n    {reference}\n")
            if input("  Press Enter to start (q to quit). ").strip().lower() == "q":
                save_manifest(manifest)
                print("Saved. Run `record` again to continue where you left off.")
                return
            record_one(path)
            seconds, peak_db = probe(path)
            warning = "  (very quiet: is the right microphone selected?)" if peak_db < SILENT_PEAK_DB else ""
            print(f"  Saved {seconds:.1f} s, peak {peak_db:.0f} dB.{warning}")
            choice = input("  Enter keeps it · p plays it · r records again · q quits: ").strip().lower()
            while choice == "p":
                subprocess.run(["afplay", str(path)])
                choice = input("  Enter keeps it · r records again · q quits: ").strip().lower()
            if choice == "r":
                continue
            manifest["items"] = [item for item in manifest["items"] if item["id"] != item_id]
            manifest["items"].append({
                "id": item_id,
                "category": group_of(item_id),
                "adversarial": None,
                "hard_terms": hard_terms,
                "reference": reference,
                "wav": path.name,
                "voice": "user",
                "duration_seconds": round(seconds, 2),
            })
            save_manifest(manifest)
            if choice == "q":
                print("Saved. Run `record` again to continue where you left off.")
                return
            break
    print(f"\nDone: {len(manifest['items'])} of {len(SENTENCES)} recorded. Manifest: {MANIFEST}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("list").set_defaults(func=cmd_list)
    sub.add_parser("status").set_defaults(func=cmd_status)
    rec = sub.add_parser("record")
    rec.add_argument("--only", help="record just this id again")
    rec.set_defaults(func=cmd_record)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
