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
  - a list of everyday modern words and developer/product terms the 1934
    dictionary predates is added (MODERN_WORDS below).

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

# Everyday words the 1934 dictionary predates: general modern vocabulary,
# followed by developer, product and business terms and the tool and service
# names developers type all day. Listed so the fuzzy pass treats them as
# ordinary words: a stray "codec" or "postgres" must not be "corrected" into
# a similar dictionary target. Base forms only; the loader strips regular
# inflections, so codecs, websockets and deployed need no entry. Names of
# people are never listed.
MODERN_WORDS = """
app backend blog chatbot config database email emoji frontend gonna hashtag
inbox internet laptop livestream logout meetup metadata okay offline
onboarding online plugin podcast roadmap screenshot smartphone spreadsheet
standup startup timeline username videos webinar webpage website wifi wanna
workflow bluetooth download codec transcode transcoding bitrate framerate mpeg
jpeg png svg pdf docx xlsx pptx csv tsv json yaml toml xml html css markdown
regex ffmpeg gzip tarball webm flac github gitlab bitbucket git repo monorepo
codebase commit rebase changelog hotfix rollout rollback refactor debug
debugger deploy redeploy deployment lint linter eslint prettier webpack vite
babel rollup npm yarn pnpm cargo gradle maven cocoapods homebrew react redux
nextjs nodejs vuejs angular svelte django flask fastapi rails laravel express
jquery tailwind bootstrap sass storybook jest mocha cypress playwright
selenium javascript typescript python golang rust kotlin scala haskell elixir
clojure perl php ruby bash zsh powershell swiftui uikit appkit xcode
kubernetes kubectl docker dockerfile helm terraform ansible jenkins nginx
serverless microservice microservices middleware runtime namespace localhost
devops fullstack dotenv postgres postgresql mysql sqlite mongodb redis
memcached dynamodb elasticsearch kafka rabbitmq nosql sql prisma graphql grpc
protobuf openapi swagger webhook websocket api sdk cli url oauth jwt saml tcp
udp dns cdn vpn ssh ssl tls http https aws azure firebase netlify heroku
cloudflare digitalocean stripe twilio sendgrid mailchimp shopify wordpress
squarespace salesforce hubspot zendesk intercom slack zoom figma sketch canva
airtable asana trello jira confluence notion linear copilot chatgpt openai llm
llms gpu gpus cpu ssd usb hdmi tensorflow pytorch numpy jupyter colab
huggingface tokenizer embedding embeddings inference finetune dataset
dataframe tensor iphone ipad macbook airpods android macos linux ubuntu debian
chromium firefox smartwatch async callback boolean enum struct tuple iterator
hashmap dataclass timestamp uuid analytics dashboard stakeholder backlog
sprint retro latency throughput uptime downtime scalability monetization
freemium saas paas fintech edtech crm erp ecommerce checkout paywall signup
signin login passcode autofill autocomplete dropdown sidebar navbar toolbar
popup tooltip modal favicon thumbnail influencer unfollow retweet selfie meme
gif blockchain cryptocurrency bitcoin ethereum nft vlog streamer bandwidth
pixel
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
