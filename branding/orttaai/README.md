# Orttaai Signal Cursor

The approved mark uses three rising voice bars and a text insertion cursor. All assets are generated from `Orttaai/Design/SignalCursorGlyph.swift`, which also draws the in-app and menu bar marks.

Run `scripts/generate_brand_assets.sh` from the repository to regenerate the kit and the app's asset catalogs. The generator needs macOS and the Xcode command-line tools.

- `marks/`: transparent amber, white, and charcoal PNGs at 16, 32, 64, 128, 256, 512, 1024, and 2048 pixels.
- `icons/`: dark, light, and white-on-dark app icon treatments at those same sizes. Pixels outside the rounded tile are transparent; the tile has a solid background.
- `wordmarks/`: transparent logo and name lockups at 320, 640, 1280, and 2560 pixels wide.
- `vectors/`: scalable SVG masters and transparent PDF symbol masters.
- `menu-bar/`: white transparent PNGs from 16 to 64 pixels and a scalable 18-point template PDF. The normal macOS status item uses native template rendering: white on dark menu bars, dark on light menu bars, and readable when selected.
- `presentations/`: logo and name on intentionally opaque light and dark backgrounds.
- `Orttaai.icns` and `Orttaai.iconset/`: the macOS app icon.
- `manifest.json`: export dimensions and transparency information.
- `preview.png`: overview of the light, dark, transparent, and small-size treatments.

The main Dock/Finder/notification icon uses the approved amber-on-charcoal treatment. The About and setup cards can use the matching light or dark asset. Sidebar and menu bar marks use the vector geometry directly. Recording keeps its existing pulse; download progress and error badges remain distinct.

The installer background uses a text-only title and drag arrow. The draggable app icon carries the logo, without repeating it in the backdrop. Generate light or dark backgrounds with `scripts/generate_dmg_background.swift`.
