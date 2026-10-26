# Moments · rules for coding agents

Moments is a private macOS app for two people to organize photos, places and shared memories. macOS only; no Windows support.

The app is a **native SwiftUI rewrite** in `macos/` (macOS 14+, SwiftData, MapKit, later PhotoKit and CloudKit sharing). The web prototype in `src/` is an interaction reference only: do not embed it in the app or extend it with new features.

## Workflow
- Work from a GitHub issue. Branch from `main`, open a PR that links the issue. Commit your work; never leave changes only on the local disk.
- New work goes in `macos/`. Never hand-edit `dist/`; it is generated output.
- Swift code must build and pass XCTest on a Mac (`xcodebuild ... build test`); a Linux sandbox cannot verify it.
- Keep PRs to one issue. Say in the PR what you verified by actually running the app or a browser, and what you only checked offline.
- Split a PR that mixes fixes with a product decision (anything the owner would notice and might disagree with: new feature shape, UI style, user-visible text, defaults, data handling), so the fixes can merge while the decision waits.

- Bug reports: the owner's description is a hint for locating the bug, not a diagnosis. If what or where is unclear (which screen, which control, when), ask the owner briefly. If the bug is hard to describe (flashes, jitter, timing, visual glitches), reproduce it yourself on the GitHub macOS runner and confirm the cause with evidence (test output, logged values, recorded frames) before fixing; then show the same check passing after the fix. Do not fix on a guess or ask the owner to diagnose.

## Verification before handing over
- A build or static check alone is not verification. Run at least one test that exercises the change (XCTest, `swift test`, or a UI test on the GitHub macOS runner) and name it in the PR. Docs-only changes are exempt; run the privacy check instead.
- State plainly what you did not run, why, and what could break. "Should be fine" is not verified.
- Verify in the cloud or on the GitHub macOS runner whatever can be verified there. Ask for an on-Mac check only for what needs the real Mac (real Photos library, real user data, signing); list what was already verified and the exact items left.
- When fixing a UI bug, check every screen the change touches, not only the one reported. When the same kind of bug shows up a second time, fix the shared mechanism and sweep all screens.
- Tests never read or write the real store, settings or `~/Library/Application Support/Moments/`; use in-memory stores or temporary directories.

## Data compatibility
- Every schema change ships a migration and a test that opens a store from the previous schema with data in it.
- A store that cannot be opened is never deleted or overwritten. Prefer copying it to a timestamped backup path and starting a usable store, and tell the user where the backup is, over a dead end.
- Before a release, upgrade a copy of the previous version's real store on the Mac (never the original).

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

## Releases
- Tagging and publishing need the repository owner's explicit go-ahead for each step.
- Version: bug-fix releases bump the third number, features the second, a change in what the app fundamentally is the first.
- Release notes are written for the app's two users (the owner and their partner) in plain language, Chinese first. Leave out problems introduced and fixed within the same cycle. State signing and notarization from the actual build, never copied from the previous release.

## UI
Follow `docs/ui-quality-principles.md`, adapted to native macOS conventions. Localize zh-Hans, en, de via String Catalog. Respect `prefers-reduced-motion`. Never lose user input, memories, tags or filter state on view switches.
