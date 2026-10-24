# What's New

After an update, the first time Orttaai's window opens it shows a small card with the release's highlights, one at a time: **Next** moves on, **Skip** or the close button puts them away, and **Got it** closes the last one. It shows once per version; a fresh install skips it, since setup comes first.

## Every release adds an entry

`scripts/release_dmg.sh` stops when `Orttaai/Core/WhatsNew/WhatsNewCatalog.swift` has no entry for the version it builds. Pass `--no-whats-new` only for a hotfix with nothing to tell.

Before each release:

1. Read the entries already in `WhatsNewCatalog.releases`, so the new one doesn't repeat an older highlight.
2. Read what changed since the last release (`git log v<last>..HEAD`, `docs/releases/<version>.md`).
3. Add a `WhatsNewRelease` at the top of the list, newest first.

## Writing the highlights

- **At most three**, even when the release has many changes. Pick what people will notice; the full list belongs in the release notes.
- **Title**: about four words, at most 32 characters.
- **Detail**: one or two plain sentences, at most 140 characters. Say what the person can now do, not how it was built.
- **Art**: `.milestones`, `.learning` or `.updates` reuse an existing picture. `.symbol("sf.symbol.name")` draws any SF Symbol in the accent rings. A highlight that deserves its own picture gets a new case in `WhatsNewArt` and a scene in `UI/WhatsNew/WhatsNewCard.swift`, drawn in SwiftUI shapes like the others.
- Give each item a unique `id`, such as `"1.14-chat"`.

`WhatsNewTests` checks the limits, unique ids and the newest-first order.

## Seeing it before release

Run a Debug build with `-OrttaaiWhatsNewPreview YES` to show the newest entry over the home window.
