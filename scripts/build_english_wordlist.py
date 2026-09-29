#!/usr/bin/env python3
"""Builds Orttaai/Resources/english-words.txt, the real-word lexicon behind the
fuzzy dictionary pass (Orttaai/Core/Transcription/FuzzyDictionaryMatcher.swift).

The pass must never "correct" an ordinary English word into a dictionary
target (verse -> Vercel, arena -> Arsenal), so it needs a fast answer to "is
this a real word?".

Provenance: /usr/share/dict/words is a symlink to web2, Webster's Second
International (1934). Its README states the 1934 copyright has lapsed, so the
list is public domain and safe to redistribute. Filtered to lowercase
alphabetic words of 3-14 letters, then trimmed to keep the bundle small:

  - words of 3-9 letters are kept whole (108k words);
  - words of 10-14 letters are kept only when they also occur in modern
    prose/documentation (--evidence directories), which drops the archaic
    long tail (the 1934 list is ~200k words, 2 MB, and mostly obscure);
  - a short list of everyday modern words the 1934 dictionary predates is
    added.

Inflections (verses, codes, running) are NOT listed: the Swift loader strips
common suffixes at lookup time.

Usage:
  python3 scripts/build_english_wordlist.py \
      --evidence /usr/share/man /opt/homebrew/share \
      --out Orttaai/Resources/english-words.txt
"""

import argparse
import os
import re
import sys
from collections import Counter

MODERN_WORDS = """
app backend blog chatbot config database email emoji frontend gonna hashtag
inbox internet laptop livestream logout meetup metadata okay offline onboarding
online plugin podcast roadmap screenshot smartphone spreadsheet standup startup
timeline username videos webinar webpage website wifi wanna workflow bluetooth
download
""".split()

TOKEN = re.compile(r"(?<![A-Za-z0-9_])[a-z]{10,14}(?![A-Za-z0-9_])")
EVIDENCE_EXTENSIONS = (".md", ".rst", ".txt", ".html", ".py")


def load_dictionary(path):
    words = set()
    with open(path, errors="ignore") as handle:
        for line in handle:
            word = line.strip()
            if word.isascii() and word.isalpha() and word.islower() and 3 <= len(word) <= 14:
                words.add(word)
    return words


def evidence_counts(roots):
    counts = Counter()
    for root in roots:
        for directory, _, files in os.walk(root):
            for name in files:
                if not (name.endswith(EVIDENCE_EXTENSIONS) or re.search(r"\.\d[a-z]*$", name)):
                    continue
                path = os.path.join(directory, name)
                try:
                    if os.path.getsize(path) > 3_000_000:
                        continue
                    with open(path, errors="ignore") as handle:
                        counts.update(TOKEN.findall(handle.read()))
                except OSError:
                    continue
    return counts


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dictionary", default="/usr/share/dict/words")
    parser.add_argument("--evidence", nargs="*", default=[])
    parser.add_argument("--out", default="Orttaai/Resources/english-words.txt")
    args = parser.parse_args()

    dictionary = load_dictionary(args.dictionary)
    seen = evidence_counts(args.evidence)
    kept = {w for w in dictionary if len(w) <= 9 or seen[w] >= 1}
    kept.update(MODERN_WORDS)

    with open(args.out, "w") as out:
        out.write("\n".join(sorted(kept)) + "\n")
    print(f"{len(kept)} words -> {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
