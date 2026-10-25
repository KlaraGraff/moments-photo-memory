# Moments · rules for coding agents

Moments is a private macOS app for two people to organize photos, places and shared memories. macOS only; no Windows support.

The app is a **native SwiftUI rewrite** in `macos/` (macOS 14+, SwiftData, MapKit, later PhotoKit and CloudKit sharing). The web prototype in `src/` is an interaction reference only: do not embed it in the app or extend it with new features.

## Workflow
- Work from a GitHub issue. Branch from `main`, open a PR that links the issue. Commit your work; never leave changes only on the local disk.
- New work goes in `macos/`. Never hand-edit `dist/`; it is generated output.
- Swift code must build and pass XCTest on a Mac (`xcodebuild ... build test`); a Linux sandbox cannot verify it.
- Keep PRs to one issue. Say in the PR what you verified by actually running the app or a browser, and what you only checked offline.

## Privacy (hard rules)
- Never commit photos, videos, previews, EXIF, real GPS, real place history, real paths (`/Users/...`), Apple Photos data, pairing tokens or personal memories.
- Personal data lives only in gitignored `private-data/`, `dist/` or `~/Library/Application Support/Moments/`.
- `demo/sample-data.json` stays synthetic (`kind: synthetic-demo-only`, coordinates near 0,0).
- When adding a new file type or folder, extend the allowlist in `scripts/check_privacy.py` narrowly.

## Before opening a PR
```sh
python3 -m unittest discover -s tests   # builds dist/ first
for f in tests/check-*.mjs; do node "$f" || exit 1; done
python3 tests/check-apple-host.py
python3 tests/check-apple-bridge.py     # macOS only (needs xcrun)
python3 scripts/check_privacy.py
git diff --check
```

## UI
Follow `docs/ui-quality-principles.md`, adapted to native macOS conventions. Localize zh-Hans, en, de via String Catalog. Respect `prefers-reduced-motion`. Never lose user input, memories, tags or filter state on view switches.
