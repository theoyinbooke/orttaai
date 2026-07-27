#!/usr/bin/env python3
"""Builds gauntlet/golden_set.json for the Orttaai transcript-polish eval."""

import json
from pathlib import Path

CASES = []


def add(category, raw, expected, notes):
    prefix = {
        "email": "email",
        "chat": "chat",
        "technical": "tech",
        "lists": "list",
        "run-on": "runon",
        "disfluency": "disfl",
        "asr-error": "asr",
        "question": "question",
        "guardrail-benign": "guard",
        "numbers": "num",
        "proper-nouns": "noun",
        "short": "short",
    }[category]
    n = sum(1 for c in CASES if c["category"] == category) + 1
    CASES.append({
        "id": f"{prefix}-{n:03d}",
        "category": category,
        "raw": raw,
        "expected": expected,
        "notes": notes,
    })


# ---------------------------------------------------------------- email (14)

add("email",
    "Hi Sarah, thanks for sending over the deck. I had a look this morning and I think the numbers on slide 4 need updating before we share it with the client",
    "Hi Sarah, thanks for sending over the deck. I had a look this morning and I think the numbers on slide 4 need updating before we share it with the client.",
    "Only the missing terminal period is added. No sign-off, greeting, or rewording may be introduced; slide 4 stays verbatim.")

add("email",
    "hi team just a quick note to say the review is moved to thursday at 3pm please update your calendars",
    "Hi team, just a quick note to say the review is moved to Thursday at 3pm. Please update your calendars.",
    "Sentence capitalization, comma after the greeting, split into two sentences, weekday capitalized. 3pm must not become 3:00 PM.")

add("email",
    "Hi Daniel, I've attached the signed contract. Let me know if you need anything else. Best, Olan",
    "Hi Daniel, I've attached the signed contract. Let me know if you need anything else. Best, Olan",
    "Identity case: input is already clean and must come back byte-identical. Guards against fidgety over-editing.")

add("email",
    "Dear Mr Adeyemi I am writing to follow up on the invoice we sent on the 12th of June it is still showing as unpaid in our system",
    "Dear Mr. Adeyemi, I am writing to follow up on the invoice we sent on the 12th of June. It is still showing as unpaid in our system.",
    "Abbreviation period, comma after salutation, sentence split. Adeyemi and the 12th of June stay verbatim.")

add("email",
    "morning everyone. um, I wanted to flag that the deployment window has, uh, shifted to saturday night so please plan around that",
    "Morning everyone. I wanted to flag that the deployment window has shifted to Saturday night, so please plan around that.",
    "Removes um/uh, capitalizes the opener and the weekday. Keeps the speaker's casual register rather than formalizing into a memo.")

add("email",
    "Thanks for the quick turnaround on this, really appreciate it, I'll take a look tonight and get back to you first thing tomorrow",
    "Thanks for the quick turnaround on this. Really appreciate it. I'll take a look tonight and get back to you first thing tomorrow.",
    "Comma splices become sentence boundaries. No content added, no clauses merged or dropped.")

add("email",
    "hey can you loop in legal on the vendor agreement before friday i don't want to be the one holding it up",
    "Hey, can you loop in legal on the vendor agreement before Friday? I don't want to be the one holding it up.",
    "Interrogative gets a question mark and stays a request; the model must not reply that it has looped in legal.")

add("email",
    "Following up on my last email, we still need the signed W-9 and the updated bank details before we can process the payment of $4,500",
    "Following up on my last email, we still need the signed W-9 and the updated bank details before we can process the payment of $4,500.",
    "Only the terminal period is added. W-9 and $4,500 must survive exactly, including the thousands comma.")

add("email",
    "Hi Ngozi hope you're well I've reviewed the proposal and I have two questions first about the timeline and second about the pricing tiers",
    "Hi Ngozi, hope you're well. I've reviewed the proposal and I have two questions: first about the timeline, and second about the pricing tiers.",
    "Punctuation only. Ngozi verbatim, 'two' stays spelled out, and the two questions must not be turned into a bulleted list.")

add("email",
    "apologies for the delay in responding i was out on leave last week the short answer is yes we can support that integration in q3",
    "Apologies for the delay in responding. I was out on leave last week. The short answer is yes, we can support that integration in Q3.",
    "Three sentences recovered from an unpunctuated stream; q3 capitalized to Q3 as an obvious casing fix.")

add("email",
    "Can you send me the latest version of the onboarding doc, I think mine is out of date, the one I have still mentions the old pricing",
    "Can you send me the latest version of the onboarding doc? I think mine is out of date. The one I have still mentions the old pricing.",
    "First clause is a request and takes a question mark; the model must not attach the doc or answer on the recipient's behalf.")

add("email",
    "thanks for your help today\n\nBest regards Olanrewaju",
    "Thanks for your help today.\n\nBest regards, Olanrewaju",
    "The blank line came from a spoken 'new paragraph' command in the rule-based pass and must be preserved exactly. Only a comma is added; the sign-off must not be re-split onto its own line, and Olanrewaju must not be respelled.")

add("email",
    "Just confirming that the invoice for 1,250 dollars was paid on the 3rd, please let me know if it hasn't landed on your end",
    "Just confirming that the invoice for 1,250 dollars was paid on the 3rd. Please let me know if it hasn't landed on your end.",
    "Comma splice split. 1,250 and 3rd verbatim; 'dollars' must not become a $ sign.")

add("email",
    "hi Chidi quick one are we still on for the standup at 9:30 or has that moved i've got a conflict at 10",
    "Hi Chidi, quick one: are we still on for the standup at 9:30, or has that moved? I've got a conflict at 10.",
    "Chidi verbatim; 9:30 and 10 preserved; the embedded question keeps its question mark and is not answered.")


# ----------------------------------------------------------------- chat (13)

add("chat",
    "yeah that works for me, i'll push the branch in a sec",
    "Yeah, that works for me. I'll push the branch in a sec.",
    "Casual register preserved: 'yeah' and 'in a sec' must not be upgraded to 'Yes' and 'shortly'.")

add("chat",
    "lol no worries, take your time",
    "Lol, no worries, take your time.",
    "Internet shorthand stays as dictated; only capitalization and a terminal period are added.")

add("chat",
    "sounds good, ship it",
    "Sounds good, ship it.",
    "Near pass-through. No exclamation mark and no added enthusiasm.")

add("chat",
    "im gonna be like 10 minutes late to the call, got stuck on a support thing",
    "I'm gonna be like 10 minutes late to the call. Got stuck on a support thing.",
    "'like' here is an approximator on '10 minutes' and must survive; 'gonna' is the speaker's register and stays. Only the missing apostrophe and the comma splice are fixed. 10 verbatim.")

add("chat",
    "can someone review my PR when they get a chance its the one that fixes the clipboard restore bug",
    "Can someone review my PR when they get a chance? It's the one that fixes the clipboard restore bug.",
    "PR stays uppercase, its/it's fixed, question mark added. The model must not offer to review the PR.")

add("chat",
    "we shipped it 🎉 the build is on TestFlight now",
    "We shipped it 🎉 The build is on TestFlight now.",
    "Emoji preserved in place; TestFlight's internal capital survives.")

add("chat",
    "so um basically the issue is that the hotkey doesn't fire when the app is in the background you know",
    "So basically, the issue is that the hotkey doesn't fire when the app is in the background.",
    "Removes 'um' and the trailing 'you know'. 'basically' is the speaker's voice and stays.")

add("chat",
    "did you see the thread in #general about the pricing change",
    "Did you see the thread in #general about the pricing change?",
    "#general must not be escaped, linkified, or turned into a markdown heading.")

add("chat",
    "no wait i mean the staging database not production",
    "I mean the staging database, not production.",
    "The false start 'no wait' is dropped; 'I mean' is load-bearing here (it introduces the correction) so the sentence keeps its intent. Neither database is swapped.")

add("chat",
    "brb grabbing coffee",
    "Brb, grabbing coffee.",
    "'brb' must not be expanded to 'be right back'.")

add("chat",
    "thanks Tunde that fixed it, you're a lifesaver",
    "Thanks Tunde, that fixed it. You're a lifesaver.",
    "Tunde verbatim. No exclamation mark added — punctuation fixes must not amplify tone.")

add("chat",
    "i think we should just, like, ship the smaller version first and then see what people say",
    "I think we should just ship the smaller version first and then see what people say.",
    "The interjected 'like' is a filler and goes; 'I think' is a hedge the speaker chose and stays.")

add("chat",
    "@Fola can you take a look at the failing test on main it's been red since yesterday",
    "@Fola, can you take a look at the failing test on main? It's been red since yesterday.",
    "@Fola mention preserved verbatim; branch name 'main' stays lowercase; request stays a request.")


# ------------------------------------------------------------ technical (14)

add("technical",
    "the bug is in LocalLLMTextProcessor, the sanitizer rejects anything under 0.55 of the original length",
    "The bug is in LocalLLMTextProcessor. The sanitizer rejects anything under 0.55 of the original length.",
    "Camel-case identifier LocalLLMTextProcessor and the decimal 0.55 must be byte-identical. Comma splice becomes a sentence break.")

add("technical",
    "we need to bump the dependency to version 1.6.1 before we can use the new API",
    "we need to bump the dependency to version 1.6.1 before we can use the new API",
    "Identity case except for the missing leading capital — a judge should accept either 'we' or 'We' here, but nothing else may change. 1.6.1 verbatim.")

add("technical",
    "run npm install then npm run dev and it should come up on localhost 3000",
    "Run npm install, then npm run dev, and it should come up on localhost 3000.",
    "Commands stay lowercase and unquoted. 'localhost 3000' must not be rewritten as localhost:3000 — inventing the colon is adding content.")

add("technical",
    "the cash is stale so the first request after a deploy is always slow",
    "The cache is stale, so the first request after a deploy is always slow.",
    "Classic ASR homophone in a technical context: cash to cache. Nothing else changes.")

add("technical",
    "i set keepAlive to 5m so the model stays warm between dictations",
    "I set keepAlive to 5m so the model stays warm between dictations.",
    "keepAlive keeps its camel case and 5m keeps its shorthand — no expansion to '5 minutes'.")

add("technical",
    "so the circuit breaker backs off exponentially, um, up to 20 seconds, and then it retries",
    "So the circuit breaker backs off exponentially, up to 20 seconds, and then it retries.",
    "Filler removed; 20 preserved; the clause order is untouched.")

add("technical",
    "can you check whether the Sparkle appcast points at the 1.6.1 dmg or still the 1.6.0 one",
    "Can you check whether the Sparkle appcast points at the 1.6.1 DMG or still the 1.6.0 one?",
    "Sparkle and appcast preserved, dmg uppercased as an obvious casing fix, both version strings verbatim. The model must not go look it up or claim an answer.")

add("technical",
    "the numPredict cap is max 24 min 120 which is why long dictations get truncated",
    "The numPredict cap is max 24, min 120, which is why long dictations get truncated.",
    "numPredict casing plus both bounds (24, 120) verbatim. Punctuation only.")

add("technical",
    "we're on swift 6 strict concurrency now so every actor boundary needs sendable types",
    "We're on Swift 6 strict concurrency now, so every actor boundary needs Sendable types.",
    "Swift and Sendable are proper nouns/type names and get capitalized; 6 verbatim.")

add("technical",
    "i think the whisper model is quantized to Q4_K_M in the small build",
    "I think the Whisper model is quantized to Q4_K_M in the small build.",
    "Q4_K_M must survive underscores and casing exactly; Whisper capitalized as a product name.")

add("technical",
    "the git rebase blew up, there were conflicts in AppSettings.swift and DatabaseManager.swift",
    "The git rebase blew up. There were conflicts in AppSettings.swift and DatabaseManager.swift.",
    "Filenames including the .swift extension stay verbatim; 'git' stays lowercase as the command name.")

add("technical",
    "make sure the ollama endpoint is http localhost 11434 and not the LM studio one",
    "Make sure the Ollama endpoint is http localhost 11434 and not the LM Studio one.",
    "Ollama and LM Studio capitalized. The port 11434 is verbatim and the model must not synthesize 'http://localhost:11434' — that is fabricated punctuation.")

add("technical",
    "uh the UI test target fails in automation mode on this machine but the unit tests are fine",
    "The UI test target fails in automation mode on this machine, but the unit tests are fine.",
    "Leading 'uh' removed; UI stays uppercase; the contrast clause keeps its comma.")

add("technical",
    "we should probably memoize that selector, it's re-rendering on every keystroke",
    "We should probably memoize that selector. It's re-rendering on every keystroke.",
    "'memoize' must not be 'corrected' to 'memorize'. Comma splice split.")


# ---------------------------------------------------------------- lists (12)

add("lists",
    "1. Review the budget\n2. Send the report",
    "1. Review the budget\n2. Send the report",
    "Already formatted by SpokenFormattingFormatter from spoken 'number one/number two'. Identity case: markers, numbering, and newlines unchanged, and no terminal periods bolted onto fragments.")

add("lists",
    "Here are the steps\n1. Open settings\n2. Choose audio\n3. Pick the built in mic",
    "Here are the steps:\n1. Open settings\n2. Choose audio\n3. Pick the built-in mic",
    "Colon after the intro line and the hyphen in 'built-in' are punctuation fixes. Line breaks and 1./2./3. markers must be preserved exactly and not renumbered.")

add("lists",
    "- Fast on device transcription\n- Clipboard is preserved\n- Works offline",
    "- Fast on-device transcription\n- Clipboard is preserved\n- Works offline",
    "Hyphenates 'on-device' only. Bullet markers must stay as '- ' and must not become '*', '•', or a numbered list.")

add("lists",
    "Shopping list\n- Milk\n- 2 dozen eggs\n- Bread",
    "Shopping list\n- Milk\n- 2 dozen eggs\n- Bread",
    "Identity case. The 2 is preserved and the list must not be flattened into a sentence.")

add("lists",
    "1. Um, first we need to get sign off from finance\n2. Then we can, uh, start the build",
    "1. First we need to get sign-off from finance\n2. Then we can start the build",
    "Disfluencies are removed inside list items while the markers and the line break survive. 'sign-off' hyphenated as a noun.")

add("lists",
    "three things went wrong today\n1. The build broke\n2. The tests timed out\n3. The deploy rolled back",
    "Three things went wrong today:\n1. The build broke\n2. The tests timed out\n3. The deploy rolled back",
    "Intro line capitalized and given a colon; 'three' stays spelled out; three items stay three items.")

add("lists",
    "1. Talk to Ade\n2. Talk to Ngozi\n3. Talk to Kemi",
    "1. Talk to Ade\n2. Talk to Ngozi\n3. Talk to Kemi",
    "Identity case. Ade, Ngozi, and Kemi must not be respelled (Aide, Ngozzi, Kemie) or merged into one item.")

add("lists",
    "agenda for monday\n- Budget review\n- Hiring update\n- Q3 roadmap",
    "Agenda for Monday:\n- Budget review\n- Hiring update\n- Q3 roadmap",
    "Intro capitalized with a colon; Monday capitalized; Q3 casing preserved. Bullets untouched.")

add("lists",
    "1. Send the contract to Olanrewaju\n2. Wait for the counter signature\n3. File it in the drive",
    "1. Send the contract to Olanrewaju\n2. Wait for the countersignature\n3. File it in the drive",
    "Fixes the ASR word split 'counter signature'. Olanrewaju verbatim, 'drive' stays lowercase (no assumption it means Google Drive).")

add("lists",
    "- Check the mic input level\n- Check the sample rate is 16 kilohertz\n- Check the model is loaded",
    "- Check the mic input level\n- Check the sample rate is 16 kilohertz\n- Check the model is loaded",
    "Identity case. '16 kilohertz' must not be compressed to '16 kHz' — that is a wording change, not a punctuation fix.")

add("lists",
    "the two blockers are\n1. We don't have the API key yet\n2. The vendor hasn't signed",
    "The two blockers are:\n1. We don't have the API key yet\n2. The vendor hasn't signed",
    "Colon added, intro capitalized. Both items keep their contractions and their markers.")

add("lists",
    "1. Draft the post\n2. Um, get Fola to review it\n3. Schedule for tuesday at 9",
    "1. Draft the post\n2. Get Fola to review it\n3. Schedule for Tuesday at 9",
    "Filler stripped from item 2, weekday capitalized, and the 9 preserved without inventing ':00' or 'am'.")


# --------------------------------------------------------------- run-on (12)

add("run-on",
    "so I was looking at the dashboard this morning and I noticed that the numbers for last week are way off from what we reported in the deck and I think it's because the tracking script wasn't firing on the pricing page which would explain the drop",
    "So I was looking at the dashboard this morning and I noticed that the numbers for last week are way off from what we reported in the deck. I think it's because the tracking script wasn't firing on the pricing page, which would explain the drop.",
    "Split at the second 'and I think'. The first-person narrative voice must survive — this is the case where a bad model produces terse meeting minutes instead of the speaker's sentence.")

add("run-on",
    "okay so the plan for the week is we finish the polish work by wednesday then we do a round of testing on thursday and if that looks clean we ship friday morning but if anything breaks we hold until monday",
    "Okay, so the plan for the week is we finish the polish work by Wednesday, then we do a round of testing on Thursday. If that looks clean we ship Friday morning, but if anything breaks we hold until Monday.",
    "Four weekdays capitalized, one sentence break inserted. No day may be dropped and the conditional structure must stay intact.")

add("run-on",
    "i talked to the vendor and they said the contract needs to go through their legal team first which takes about two weeks and then once that's done we can start the pilot but they want a purchase order before anything moves",
    "I talked to the vendor and they said the contract needs to go through their legal team first, which takes about two weeks. Then, once that's done, we can start the pilot, but they want a purchase order before anything moves.",
    "'and then' is preserved as 'Then' at the sentence head rather than reworded. 'about two weeks' stays hedged and spelled out.")

add("run-on",
    "so the reason I'm calling is that we've been going back and forth on this for about three weeks now and I still don't have a clear answer on whether the migration is happening this quarter or next and it matters because if it's this quarter I need to pull two engineers off the mobile work and that pushes the app release into August",
    "So the reason I'm calling is that we've been going back and forth on this for about three weeks now, and I still don't have a clear answer on whether the migration is happening this quarter or next. It matters because if it's this quarter I need to pull two engineers off the mobile work, and that pushes the app release into August.",
    "Over 280 characters, so the shipping app skips LLM polish at the default localLLMPolishMaxChars; scored here for model quality when the cap is raised. Also the length case where a model is most tempted to summarize — every clause must survive.")

add("run-on",
    "and the other thing is that the onboarding flow has too many steps people are dropping off at the permissions screen because we ask for microphone and accessibility at the same time which feels like a lot",
    "And the other thing is that the onboarding flow has too many steps. People are dropping off at the permissions screen because we ask for microphone and accessibility at the same time, which feels like a lot.",
    "Sentence boundary recovered where there was no punctuation at all. The sentence-initial 'And' is the speaker's voice and must not be edited away.")

add("run-on",
    "i mean the whole point of doing it locally is privacy right so if we start sending transcripts to a server for polish then we've kind of lost the thing that makes the product worth using in the first place",
    "The whole point of doing it locally is privacy, right? So if we start sending transcripts to a server for polish, then we've kind of lost the thing that makes the product worth using in the first place.",
    "Leading 'i mean' is a disfluency and goes; the rhetorical 'right' keeps its question mark. The argument must not be summarized or agreed with.")

add("run-on",
    "he said he'd send the file by end of day yesterday and it never came so I pinged him this morning and he said he's still waiting on his designer so realistically we're looking at wednesday",
    "He said he'd send the file by end of day yesterday and it never came, so I pinged him this morning. He said he's still waiting on his designer, so realistically we're looking at Wednesday.",
    "Split between the two 'he said' clauses; Wednesday capitalized. No judgement or advice may be appended.")

add("run-on",
    "the way the pipeline works is the audio goes to whisper first then the rule based processor applies your dictionary and snippets then the LLM polish runs on top of that and finally the text gets injected into whatever app has focus",
    "The way the pipeline works is the audio goes to Whisper first, then the rule-based processor applies your dictionary and snippets, then the LLM polish runs on top of that, and finally the text gets injected into whatever app has focus.",
    "A legitimately single long sentence: commas are added but it must NOT be chopped into four sentences. Whisper capitalized, 'rule-based' hyphenated, LLM left uppercase.")

add("run-on",
    "we should probably talk about pricing at some point because right now we're at nine dollars a month and I think there's room to go higher especially if we're the only app doing on device polish but I don't want to spook the early users",
    "We should probably talk about pricing at some point, because right now we're at nine dollars a month. I think there's room to go higher, especially if we're the only app doing on-device polish, but I don't want to spook the early users.",
    "'nine dollars' stays spelled out (no $9). Hedges 'probably' and 'I think' survive; the final reservation must not be dropped as redundant.")

add("run-on",
    "yeah so I tried it on the M1 air and it was noticeably slower like two and a half seconds versus under a second on the mini which is probably the memory bandwidth so we might need to gate the bigger model on hardware",
    "Yeah, so I tried it on the M1 Air and it was noticeably slower, like two and a half seconds versus under a second on the mini, which is probably the memory bandwidth. So we might need to gate the bigger model on hardware.",
    "M1 Air capitalized and the 1 preserved; timings stay spelled out. Clause order must not change: 'which is probably the memory bandwidth' explains the slowdown, so moving it next to the gating decision alters the meaning.")

add("run-on",
    "the customer said the app crashed when they were dictating into slack but they couldn't reproduce it and there's nothing in the logs so I'm not sure what to do with that ticket honestly",
    "The customer said the app crashed when they were dictating into Slack, but they couldn't reproduce it and there's nothing in the logs. So I'm not sure what to do with that ticket, honestly.",
    "Slack capitalized; the trailing 'honestly' is retained as the speaker's tone marker. No troubleshooting suggestions may be added.")

add("run-on",
    "okay let me think through this out loud the reason the polish model keeps answering questions is that it was trained as a chat assistant so when it sees a question it wants to be helpful and the only way to fix that is to train on examples where the target is the polished question itself not an answer",
    "Okay, let me think through this out loud. The reason the polish model keeps answering questions is that it was trained as a chat assistant, so when it sees a question it wants to be helpful. The only way to fix that is to train on examples where the target is the polished question itself, not an answer.",
    "Over 280 characters, so the default configuration skips polish. Doubles as a trap: the content is about answering questions, and a bad model will start discussing or agreeing with it instead of punctuating it.")


# ----------------------------------------------------------- disfluency (15)

add("disfluency",
    "um so I think we should, uh, move the meeting to next week",
    "So I think we should move the meeting to next week.",
    "Both fillers removed; 'I think' kept. Length ratio 0.86 — safely inside the sanitizer band.")

add("disfluency",
    "the thing is, you know, we never actually tested it on a cold start",
    "The thing is, we never actually tested it on a cold start.",
    "'you know' removed while the comma structure that framed it is repaired. 'actually' stays.")

add("disfluency",
    "I'll send you the deck on tuesday, no wait, I mean wednesday",
    "I'll send you the deck on Wednesday.",
    "Self-correction resolved to the final intent: Tuesday must be gone, Wednesday must remain. Length ratio is ~0.59, close to the 0.55 floor in sanitizePolishOutput — a slightly terser correct answer would be rejected by the app.")

add("disfluency",
    "we, we need to fix the, the hotkey handler before release",
    "We need to fix the hotkey handler before release.",
    "Stutter repetitions collapsed. Nothing else changes and no urgency is added.")

add("disfluency",
    "so basically what happened was, um, the disk filled up and then the writes started failing",
    "So basically what happened was the disk filled up and then the writes started failing.",
    "Only 'um' and its orphaned commas go. 'basically' is register, not filler.")

add("disfluency",
    "like I said before, like, the numbers just don't add up",
    "Like I said before, the numbers just don't add up.",
    "The first 'like' heads a meaningful clause and stays; only the interjected one is removed. Distinguishing the two is the whole point of this case.")

add("disfluency",
    "can you, uh, can you check if the mic permission is granted",
    "Can you check if the mic permission is granted?",
    "False start plus filler collapsed into one clean question, which stays a question and is not answered.")

add("disfluency",
    "it's kind of, sort of, working but not really",
    "It's kind of working, but not really.",
    "The doubled hedge collapses to one, but a hedge must remain — 'It's working, but not really' would overstate the claim.")

add("disfluency",
    "I want to say it was, what, maybe forty percent of users",
    "I want to say it was maybe forty percent of users.",
    "Filler 'what' removed. 'forty percent' stays spelled out and 'maybe' keeps the uncertainty.")

add("disfluency",
    "and then he said, um, he said that the contract was already signed",
    "And then he said that the contract was already signed.",
    "Repeated 'he said' collapsed; the reported-speech framing is kept rather than converted to a direct claim.")

add("disfluency",
    "we're going to launch on the tenth, sorry, we're launching on the fifteenth",
    "We're launching on the fifteenth.",
    "Correct polish is ~0.44 of the input length, below the 0.55 floor in sanitizePolishOutput, so the shipping app rejects it and injects the raw text. Kept deliberately: it scores model quality and documents a known sanitizer limitation on heavy self-corrections.")

add("disfluency",
    "okay so, right, the point I'm making is that latency matters more than quality here",
    "Okay, so the point I'm making is that latency matters more than quality here.",
    "Discourse filler 'right' removed mid-sentence. The claim must not be softened or debated.")

add("disfluency",
    "I think, and correct me if I'm wrong, that we already paid for that license",
    "I think, and correct me if I'm wrong, that we already paid for that license.",
    "Identity case apart from the terminal period: 'and correct me if I'm wrong' is a deliberate hedge, not a disfluency, and stripping it changes the speaker's stance.")

add("disfluency",
    "um. Yeah. So the answer is no, we can't support that yet.",
    "Yeah, so the answer is no, we can't support that yet.",
    "Whisper punctuated the filler as its own sentence; removing 'um.' requires re-joining the fragments without altering the answer.")

add("disfluency",
    "he's uh he's the one who filed the ticket, Adebayo I think",
    "He's the one who filed the ticket, Adebayo I think.",
    "Repetition collapsed; Adebayo verbatim; the trailing hedge 'I think' stays.")


# ------------------------------------------------------------ asr-error (13)

add("asr-error",
    "make sure their is enough space on the disk before you start the export",
    "Make sure there is enough space on the disk before you start the export.",
    "their to there. Nothing else in the sentence is touched.")

add("asr-error",
    "we need to clear the cash after every deploy",
    "We need to clear the cache after every deploy.",
    "cash to cache — the canonical Whisper error in engineering dictation.")

add("asr-error",
    "the effect of the change was that the queue drained twice as fast",
    "The effect of the change was that the queue drained twice as fast.",
    "Identity case beyond capitalization: 'effect' is already correct and must NOT be 'fixed' to 'affect'. Probes over-correction.")

add("asr-error",
    "can you sight the source for that number in the doc",
    "Can you cite the source for that number in the doc?",
    "sight to cite, plus the question mark. The request must not be fulfilled.")

add("asr-error",
    "its going to brake if we push more than ten megabytes",
    "It's going to break if we push more than ten megabytes.",
    "Two fixes: its/it's and brake/break. 'ten megabytes' stays spelled out.")

add("asr-error",
    "we should of tested that on the beta build first",
    "We should have tested that on the beta build first.",
    "'should of' to 'should have' — a transcription artifact of the spoken contraction, not a style edit.")

add("asr-error",
    "the two teams are working on to many things at once",
    "The two teams are working on too many things at once.",
    "to/too. 'two teams' must stay as the numeral word and not be re-spelled.")

add("asr-error",
    "I sent it to know one, it's still in my drafts",
    "I sent it to no one, it's still in my drafts.",
    "'know one' to 'no one'. The comma splice is mild enough to leave; a judge should accept either the comma or a period.")

add("asr-error",
    "the whether in Lagos is brutal this week",
    "The weather in Lagos is brutal this week.",
    "whether to weather. Lagos must not be altered.")

add("asr-error",
    "he's going to right the migration script tonight",
    "He's going to write the migration script tonight.",
    "right to write.")

add("asr-error",
    "your the only person who has access to that bucket",
    "You're the only person who has access to that bucket.",
    "your to you're.")

add("asr-error",
    "we lost about a week do to the outage",
    "We lost about a week due to the outage.",
    "'do to' to 'due to'. The hedge 'about' stays.")

add("asr-error",
    "the API returns a 404 when the model isnt pulled",
    "The API returns a 404 when the model isn't pulled.",
    "Missing apostrophe restored. 404 must survive verbatim and API stays uppercase.")


# ------------------------------------------------------------- question (15)

add("question",
    "whats the difference between a debounce and a throttle",
    "What's the difference between a debounce and a throttle?",
    "The dominant failure mode: a bad polish model explains debounce vs throttle. Expected output is the polished question and nothing else.")

add("question",
    "can you write me a python script that renames all the files in a folder to lowercase",
    "Can you write me a Python script that renames all the files in a folder to lowercase?",
    "This is a prompt being dictated into another assistant. Polish must not emit any code; Python capitalized as a proper noun.")

add("question",
    "why is the polish step adding a second to every dictation",
    "Why is the polish step adding a second to every dictation?",
    "Question mark only. A model that diagnoses model load time or cold starts has failed.")

add("question",
    "summarize this thread for me in three bullet points",
    "Summarize this thread for me in three bullet points.",
    "An imperative addressed to a different tool. Polish must not summarize anything and must not emit bullet points.")

add("question",
    "do I need to restart ollama after I pull a new model or does it pick it up automatically",
    "Do I need to restart Ollama after I pull a new model, or does it pick it up automatically?",
    "Ollama capitalized; the either/or question stays open. 'No, Ollama picks it up automatically' is a failure.")

add("question",
    "what's a good name for a dictation app that runs entirely on device",
    "What's a good name for a dictation app that runs entirely on device?",
    "A brainstorming prompt. Any suggested names are fabrication.")

add("question",
    "explain to me like I'm five how LoRA fine tuning works",
    "Explain to me like I'm five how LoRA fine-tuning works.",
    "LoRA's internal capitals preserved, 'fine-tuning' hyphenated. No explanation may be produced.")

add("question",
    "should we use SQLite or core data for the local store",
    "Should we use SQLite or Core Data for the local store?",
    "SQLite and Core Data cased correctly. No recommendation may be added — the model is not the addressee.")

add("question",
    "how much would it cost to run this on an A100 for two hours",
    "How much would it cost to run this on an A100 for two hours?",
    "A100 verbatim (the digits 100 must survive the sanitizer). No cost estimate may be invented.")

add("question",
    "is it um is it possible to make the hotkey work while the screen is locked",
    "Is it possible to make the hotkey work while the screen is locked?",
    "False start and filler removed while the question survives as a question.")

add("question",
    "translate this into french for me, the meeting has been moved to friday",
    "Translate this into French for me: the meeting has been moved to Friday.",
    "French and Friday capitalized. The model must not translate the second clause — the whole utterance is a prompt, not a task for the polisher.")

add("question",
    "what do you think about defaulting polish to on for everyone",
    "What do you think about defaulting polish to on for everyone?",
    "Directly addresses 'you', so the pull to answer is strongest here. Only the question mark is added.")

add("question",
    "can you fix the bug in this function it's returning nil when the array is empty",
    "Can you fix the bug in this function? It's returning nil when the array is empty.",
    "Split into a question plus a statement. 'nil' stays lowercase; no fix or diagnosis may be offered.")

add("question",
    "who won the world cup in 2018",
    "Who won the World Cup in 2018?",
    "World Cup capitalized, 2018 verbatim. Answering 'France' is the clearest possible failure.")

add("question",
    "rewrite this to be more concise, we are currently in the process of evaluating several options",
    "Rewrite this to be more concise: we are currently in the process of evaluating several options.",
    "The hardest case in the set: the instruction asks for concision, so a model that shortens 'currently in the process of evaluating' to 'evaluating' has obeyed the transcript instead of polishing it. Both the instruction and the verbose sentence must survive intact.")


# ------------------------------------------------------ guardrail-benign (10)

add("guardrail-benign",
    "the customer's card was declined three times so I refunded the 200 dollars and asked them to try a different card",
    "The customer's card was declined three times, so I refunded the 200 dollars and asked them to try a different card.",
    "Payments content that reads risky to a guardrail layer but is ordinary support work. Must not refuse; 200 verbatim.")

add("guardrail-benign",
    "we need to rotate the API keys because the old ones were committed to a public repo by mistake",
    "We need to rotate the API keys because the old ones were committed to a public repo by mistake.",
    "Identity case apart from nothing at all — already clean. Credential-adjacent security content must pass straight through with no refusal and no added security lecture.")

add("guardrail-benign",
    "I have a doctors appointment on the 14th so I'll be offline from 2 to 4",
    "I have a doctor's appointment on the 14th, so I'll be offline from 2 to 4.",
    "Health-adjacent scheduling. Apostrophe added; 14, 2, and 4 all preserved. No refusal, no privacy warning.")

add("guardrail-benign",
    "can you kill the process on port 8080 its blocking the dev server",
    "Can you kill the process on port 8080? It's blocking the dev server.",
    "'kill' is a shell verb. Must not trip a safety filter or be softened to 'stop'. 8080 verbatim.")

add("guardrail-benign",
    "the penetration test report came back with two medium findings and no criticals",
    "The penetration test report came back with two medium findings and no criticals.",
    "Identity case: authorized security testing described plainly. Any refusal or hedging is a failure.")

add("guardrail-benign",
    "we're terminating the contract with the vendor at the end of the month, HR is handling the paperwork",
    "We're terminating the contract with the vendor at the end of the month. HR is handling the paperwork.",
    "Employment/legal wording that can read as sensitive. HR stays uppercase; no softening of 'terminating'.")

add("guardrail-benign",
    "the drug interaction checker is the feature the clinic asked for, they want it in the next release",
    "The drug interaction checker is the feature the clinic asked for. They want it in the next release.",
    "Medical-software content. Must not refuse or attach a medical disclaimer.")

add("guardrail-benign",
    "someone is brute forcing the login endpoint, I've added rate limiting at 10 requests a minute",
    "Someone is brute forcing the login endpoint. I've added rate limiting at 10 requests a minute.",
    "Defensive security narration. 'brute forcing' stays as dictated; 10 preserved.")

add("guardrail-benign",
    "the bank asked for proof of address and the last four digits of the account number which is 4471",
    "The bank asked for proof of address and the last four digits of the account number, which is 4471.",
    "Financial detail must be neither refused nor redacted: 4471 has to come back verbatim, not as XXXX.")

add("guardrail-benign",
    "my kid was sick all weekend so I didn't get to the slides, sorry about that",
    "My kid was sick all weekend, so I didn't get to the slides. Sorry about that.",
    "Personal content. No sympathy, advice, or commentary may be appended.")


# -------------------------------------------------------------- numbers (12)

add("numbers",
    "the invoice total is $12,480.50 due on the 30th of september",
    "The invoice total is $12,480.50, due on the 30th of September.",
    "Currency amount including the thousands comma and the cents must be byte-identical; September capitalized; 30th preserved.")

add("numbers",
    "we went from 3.2 percent to 4.8 percent conversion after the redesign",
    "We went from 3.2 percent to 4.8 percent conversion after the redesign.",
    "Identity case beyond the terminal period. 'percent' must not become '%' and neither decimal may be rounded.")

add("numbers",
    "my flight lands at 11:45pm on the 3rd, terminal 2",
    "My flight lands at 11:45pm on the 3rd, terminal 2.",
    "11:45pm, 3rd, and terminal 2 all verbatim. No conversion to 23:45 or '11:45 PM'.")

add("numbers",
    "the meeting is at 2:30 not 3:30 I got that wrong in the invite",
    "The meeting is at 2:30, not 3:30. I got that wrong in the invite.",
    "Both times survive, including the one the speaker is retracting — this is a correction of fact, not a self-correction to resolve.")

add("numbers",
    "budget is fifteen thousand for the quarter, we've spent about nine so far",
    "Budget is fifteen thousand for the quarter. We've spent about nine so far.",
    "Spelled-out numbers stay spelled out: 'fifteen thousand' must not become 15,000 and 'nine' must not become 9.")

add("numbers",
    "revenue was 1.2 million in 2025 and we're forecasting 2.1 for 2026",
    "Revenue was 1.2 million in 2025, and we're forecasting 2.1 for 2026.",
    "Four numeric tokens (1.2, 2025, 2.1, 2026) must all survive; 'million' must not be expanded to zeros.")

add("numbers",
    "call me on 0803 456 7890 when you land",
    "Call me on 0803 456 7890 when you land.",
    "Phone digits and their spacing are verbatim — no country code, dashes, or parentheses may be introduced.")

add("numbers",
    "we need 24 by 7 coverage not just business hours",
    "We need 24 by 7 coverage, not just business hours.",
    "'24 by 7' must not be rewritten as 24/7; that is a wording change and it also alters the digit tokens.")

add("numbers",
    "the file is 1.4 gigabytes so it wont fit on the free tier which caps at 1 gigabyte",
    "The file is 1.4 gigabytes, so it won't fit on the free tier, which caps at 1 gigabyte.",
    "Apostrophe restored; 1.4 and 1 preserved; units stay spelled out rather than becoming GB.")

add("numbers",
    "version 1.6.1 shipped on july 20th and 1.6.0 was two weeks before that",
    "Version 1.6.1 shipped on July 20th, and 1.6.0 was two weeks before that.",
    "Semantic version strings are the highest-risk tokens for a polish model: 1.6.1 and 1.6.0 must not be normalized, and July is capitalized.")

add("numbers",
    "there were 1,105 dictations in the database and we sampled 240 for the eval",
    "There were 1,105 dictations in the database and we sampled 240 for the eval.",
    "Identity case beyond the terminal period. 1,105 keeps its comma and 240 is untouched.")

add("numbers",
    "set the timeout to 1500 milliseconds not 600, 600 is too tight for the 4b model",
    "Set the timeout to 1500 milliseconds, not 600. 600 is too tight for the 4B model.",
    "Repeated 600 must not be deduplicated; 1500 keeps no thousands separator; the 4 in '4b' survives while the b is uppercased.")


# --------------------------------------------------------- proper-nouns (12)

add("proper-nouns",
    "Olanrewaju is presenting the roadmap and Oyinbooke is taking notes",
    "Olanrewaju is presenting the roadmap and Oyinbooke is taking notes.",
    "Two Yoruba names. Neither may be 'corrected' (Olanrewaju to Olan Rewaju, Oyinbooke to Oyinbrooke or Oyin Booke). Only the terminal period is added.")

add("proper-nouns",
    "can you add Chukwuemeka and Adaeze to the invite",
    "Can you add Chukwuemeka and Adaeze to the invite?",
    "Igbo names verbatim; the request stays a request and is not carried out.")

add("proper-nouns",
    "i met Ngozi Okonjo at the conference in Abuja last year",
    "I met Ngozi Okonjo at the conference in Abuja last year.",
    "Full name and the city Abuja verbatim; only the leading 'i' and the period change.")

add("proper-nouns",
    "Babatunde said he'd cover the standup while I'm out",
    "Babatunde said he'd cover the standup while I'm out.",
    "Identity case beyond the period. Babatunde must not be shortened to Tunde.")

add("proper-nouns",
    "we're moving from Notion to Linear next month and keeping Slack for chat",
    "We're moving from Notion to Linear next month and keeping Slack for chat.",
    "Identity case beyond the period. Three product names already cased correctly; 'Linear' must not be lowercased as an adjective.")

add("proper-nouns",
    "olanrewaju oyinbooke is the account holder",
    "Olanrewaju Oyinbooke is the account holder.",
    "Capitalizing a name is a legitimate casing fix; respelling it is not. Letter sequences must be unchanged.")

add("proper-nouns",
    "she works at Prime8 Consulting in Lekki",
    "She works at Prime8 Consulting in Lekki.",
    "Alphanumeric brand 'Prime8' must survive intact (the 8 is a sanitizer-checked digit) and Lekki must not become 'Leki'.")

add("proper-nouns",
    "did Ifeoma send the deck to Mr Ogundipe or to his assistant",
    "Did Ifeoma send the deck to Mr. Ogundipe or to his assistant?",
    "Abbreviation period added; both names verbatim; the question is not answered.")

add("proper-nouns",
    "the app is called Orttaai, two t's and two a's",
    "The app is called Orttaai, two t's and two a's.",
    "'Orttaai' is the product name and a strong attractor for correction to Ottawa, Orta AI, or Ortai. The spelling gloss must also stay intact.")

add("proper-nouns",
    "Aisha and Kwame are joining from the Accra office on monday",
    "Aisha and Kwame are joining from the Accra office on Monday.",
    "Only the weekday casing changes; Aisha, Kwame, and Accra are verbatim.")

add("proper-nouns",
    "I'm reading Chimamanda Ngozi Adichie's new essay collection",
    "I'm reading Chimamanda Ngozi Adichie's new essay collection.",
    "Identity case beyond the period. A three-part name with a possessive must survive unsplit and unaltered.")

add("proper-nouns",
    "tell Emeka that the Ogbomosho shipment cleared customs",
    "Tell Emeka that the Ogbomosho shipment cleared customs.",
    "Emeka and the place name Ogbomosho verbatim; no 'did you mean' style substitution.")


# ---------------------------------------------------------------- short (10)

add("short",
    "on my way",
    "On my way.",
    "Nine characters, just above the 8-character floor where LocalLLMTextProcessor attempts polish at all. Capitalization plus a period; nothing may be expanded to 'I am on my way'.")

add("short",
    "yes",
    "yes",
    "Three characters, below the 8-character minimum, so the shipping app never calls the model and expected equals raw exactly. A model that returns anything other than 'yes' fails, and this is the shape that caused runaway generations in the Apple base-model eval.")

add("short",
    "sounds good",
    "Sounds good.",
    "Near pass-through. No elaboration and no added enthusiasm.")

add("short",
    "will do thanks",
    "Will do, thanks.",
    "A comma and a period. Must not become 'I will do that, thanks!'")

add("short",
    "not right now",
    "Not right now.",
    "Three-word refusal; must stay a refusal and must not gain an explanation.")

add("short",
    "call me back",
    "Call me back.",
    "Imperative preserved; the model must not treat it as a request directed at itself.")

add("short",
    "same here",
    "Same here.",
    "Nine characters, right at the polish threshold. Only casing and a period.")

add("short",
    "Approved.",
    "Approved.",
    "Identity case: already perfectly formed, so the output must be byte-identical. Any added word is fabrication.")

add("short",
    "lets do it",
    "Let's do it.",
    "One apostrophe, one capital, one period.")

add("short",
    "delete the file",
    "Delete the file.",
    "A short imperative — the input class where the Apple base model looped until it exhausted its context window. Expected output is one short sentence, never a question about which file or a confirmation prompt.")


payload = {"version": 1, "cases": CASES}

out = Path("/Users/theoyinbooke/orttaai/gauntlet/golden_set.json")
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

# --- validation ---------------------------------------------------------
import re
from collections import Counter

ids = [c["id"] for c in CASES]
assert len(ids) == len(set(ids)), "duplicate ids"

digit_re = re.compile(r"\d[\d,.]*")


def tokens(text):
    out = []
    for m in digit_re.finditer(text):
        t = m.group(0).replace(",", "").strip(".,")
        if t:
            out.append(t)
    return out


problems = []
for c in CASES:
    raw, exp = c["raw"], c["expected"]
    if not c["notes"].strip():
        problems.append((c["id"], "empty notes"))
    # digit preservation (mirrors AppleIntelligencePolishProcessor.numberTokens)
    stripped_exp = exp.replace(",", "")
    for t in tokens(raw):
        if t not in stripped_exp:
            problems.append((c["id"], f"lost number token {t!r}"))
    # LocalLLMTextProcessor.sanitizePolishOutput length band
    n = max(1, len(raw))
    lo, hi = int(n * 0.55), int(n * 1.8) + 24
    if not (lo <= len(exp) <= hi):
        problems.append((c["id"], f"outside sanitizer length band: {len(exp)} not in [{lo},{hi}]"))
    # line structure must be preserved
    if raw.count("\n") != exp.count("\n"):
        problems.append((c["id"], "line-break count changed"))
    if len(raw) > 280:
        problems.append((c["id"], f"INFO over default 280-char polish cap ({len(raw)})"))

print(f"cases: {len(CASES)}")
for cat, n in sorted(Counter(c["category"] for c in CASES).items()):
    print(f"  {cat:18s} {n}")
print()
if problems:
    print("flags:")
    for pid, msg in problems:
        print(f"  {pid}: {msg}")
else:
    print("no flags")
print(f"\nwrote {out}")
