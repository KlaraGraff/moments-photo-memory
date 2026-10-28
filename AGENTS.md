# Moments · rules for coding agents

Moments is a private macOS app for two people to organize photos, places and shared memories. macOS only; no Windows support.

The app is a **native SwiftUI rewrite** in `macos/` (macOS 14+, SwiftData, MapKit, later PhotoKit and CloudKit sharing). The web prototype in `src/` is an interaction reference only: do not embed it in the app or extend it with new features. New work goes in `macos/`. Never hand-edit `dist/`; it is generated output.

## How work is split
- Plan a large request before writing code, then split it into work packages that do not overlap (different screens, files or modules). Each package gets its own thread and branch. Run 2 to 4 code threads at a time.
- A planning thread only plans; implementation happens in the package threads.
- After a thread's PR merges, it resets its branch to the latest `main` before starting the next PR on the same branch.

## Pull requests
- Every PR is based on `main`. Never base a PR on another PR's branch, and there is no integration or "assemble the preview" thread.
- Keep PRs small, one concern each. When two PRs touch the same file, whoever merges second merges `main` into their branch and resolves the conflict.
- Split a PR that mixes fixes with a product decision, so the fixes can merge while the decision waits.
- Open the PR as a **draft** while iterating: drafts get only the fast Linux checks. Mark it ready for review once the Linux checks are green and you have run your own checks; that starts the Mac checks the change needs, once per push (see CI below).
- After opening a PR, keep the coordinator responsible for checking its activity. Check CI after a reasonable delay (5, then 10, then 20 minutes) rather than polling rapidly; do not claim a check passed when it is skipped. Use the GitHub CLI or the connected GitHub tools; there is no Claude-only subscription step.
- Tell the owner about a PR at most twice: when it is up, and when it needs them.

## Merging
- The author thread squash-merges its own PR as soon as every check is green on the head commit and its self-test passed, then reports. Pass the PR title with its number as the commit title.
- "Skipped" is not green. Nothing on GitHub blocks an early merge, so before merging confirm that the `macOS` run, and the `macOS UI tests` run when the PR touches the app, finished successfully on the head commit after the PR was marked ready. Docs-only PRs need only the Linux checks.
- Only product decisions wait for the owner: new feature shape, UI style, user-visible text, defaults, data handling (anything they would notice and might disagree with). Never ask "can I merge?" for anything else.
- Red CI: first check whether `main` is red too. If it is, fix `main` in its own small PR (or port that fix) instead of working around it. Otherwise the author fixes and pushes again until green.
- A job that died before any test ran (checkout, install, runner loss) may be re-run once from GitHub Actions ("Re-run failed jobs"). A second failure is real. Never skip, disable or quarantine a test, push an empty commit, or close and reopen a PR to re-run CI. Never rewrite history on someone else's branch.
- Tagging and releases always need the owner's go-ahead (see Releases).

## Review
- Default quality comes from the author's self-test plus CI.
- An extra independent review by Opus 5.5 at high effort only for schema or migration changes, cross-module changes, performance work and CI or workflow changes. There is no other review tier.

## CI
| Workflow | Runs on | When | What |
|---|---|---|---|
| `linux.yml` | ubuntu | every push to a PR (drafts included) and to `main` | `swift test` for the `MomentsCore` package; prototype build, Node checks, privacy check, whitespace check |
| `macos.yml` | hosted Mac | ready (non-draft) PRs and `main`; not for docs-only changes | app build + `MomentsTests`, UI test compile, `MomentsCore` tests, Apple Photos bridge checks, translation check |
| `ui-tests.yml` | hosted Mac | ready PRs touching the app and `main` | the whole UI suite with synthetic data |

- A new push cancels the older run of the same PR, so each PR head is checked once. On `main` only the newest commit is checked.
- For a quick UI probe, dispatch `ui-tests.yml` by hand with `only_testing` (for example `MomentsUITests/MomentsUITests/testDoubleClickRenamesATripInPlace`). Manual runs are never cancelled.
- Logic that needs no AppKit, SwiftUI, SwiftData, CoreGraphics or ImageIO belongs in the `MomentsCore` package (`macos/MomentsCore`) with its tests there, so it is checked on Linux in minutes. Guard any Apple-only API in the package with `#if canImport(...)`.
- Hosted Macs are scarce: no extra macOS jobs or workflows without a reason; prefer adding steps to `macos.yml`.

## Verification before handing over
- A build or static check alone is not verification. Run at least one test that exercises the change (`swift test`, XCTest, or a UI test on the GitHub macOS runner) and name it in the PR. Docs-only changes are exempt; run the privacy check instead.
- State plainly what you did not run, why, and what could break. "Should be fine" is not verified.
- Verify in the cloud or on the GitHub macOS runner whatever can be verified there; tests never take over the owner's screen. Ask for an on-Mac check only for what needs the real Mac (real Photos library, real user data, signing); list what was already verified and the exact items left.
- When fixing a UI bug, check every screen the change touches, not only the one reported. When the same kind of bug shows up a second time, fix the shared mechanism and sweep all screens.
- Tests never read or write the real store, settings or `~/Library/Application Support/Moments/`; use in-memory stores or temporary directories.

## Bug reports
The owner's description is a hint for locating the bug, not a diagnosis. If what or where is unclear (which screen, which control, when), ask the owner briefly. If the bug is hard to describe (flashes, jitter, timing, visual glitches), reproduce it yourself on the GitHub macOS runner and confirm the cause with evidence (test output, logged values, recorded frames) before fixing; then show the same check passing after the fix. Do not fix on a guess or ask the owner to diagnose.

## Preview for the owner
The on-Mac preview thread updates the owner's preview build to the latest `main` in batches after several merges, not after every merge. Other threads do not build on the owner's Mac.

## Coordination
- The coordinator talks with the owner and starts threads with a brief: the owner's words, the done criteria, background and hard limits. Threads message each other only when their work depends on each other.
- No scheduled patrols: progress comes from thread reports and PR events. Do not state why something is slow until the cause is checked.

## Data compatibility
- Every schema change ships a migration and a test that opens a store from the previous schema with data in it.
- A store that cannot be opened is never deleted or overwritten. Prefer copying it to a timestamped backup path and starting a usable store, and tell the user where the backup is, over a dead end.
- Before a release, upgrade a copy of the previous version's real store on the Mac (never the original).

## Privacy (hard rules)
- Never commit photos, videos, previews, EXIF, real GPS, real place history, real paths (`/Users/...`), Apple Photos data, pairing tokens or personal memories.
- Personal data lives only in gitignored `private-data/`, `dist/` or `~/Library/Application Support/Moments/`.
- `demo/sample-data.json` stays synthetic (`kind: synthetic-demo-only`, coordinates near 0,0).
- When adding a new file type or folder, extend the allowlist in `scripts/check_privacy.py` narrowly.

## UI
- Follow `docs/ui-quality-principles.md`, adapted to native macOS conventions. New screens and sheets use the shared Paper design layer in `macos/Sources/Moments/Design/Paper.swift` (tones, text field style, sheets, form labels, motion).
- Check every UI change at a small window (about 900×600) as well as a large one. When space is tight show icons only, otherwise icon and label.
- Every user-visible string needs German and Chinese (Simplified) as well as English. Add them with `scripts/add_translations.py`; the translation check in `macos.yml` fails on any string missing de or zh-Hans.
- Respect reduced motion. Never lose user input, memories, tags or filter state on view switches.

## Before marking a PR ready
```sh
swift test --package-path macos/MomentsCore   # if you have a Swift toolchain
python3 -m unittest discover -s tests          # builds dist/ first
for f in tests/check-*.mjs; do node "$f" || exit 1; done
python3 scripts/check_privacy.py
git diff --check
```
On a Mac, also `python3 tests/check-apple-host.py` and `python3 tests/check-apple-bridge.py`. Swift app code is verified by `macos.yml` and `ui-tests.yml`; a Linux sandbox cannot build it.

## Releases
- Tagging and publishing need the repository owner's explicit go-ahead for each step.
- Version: bug-fix releases bump the third number, features the second, a change in what the app fundamentally is the first.
- Release notes are written for the app's two users (the owner and their partner) in plain language, Chinese first. Leave out problems introduced and fixed within the same cycle. State signing and notarization from the actual build, never copied from the previous release.

## Codex coordination

The main thread is the coordinator. It owns product decisions, task boundaries, integration, final verification, and the user report. Start a child task only when the work is genuinely independent; short work stays in the coordinator. Every package brief names its goal, inputs, output, allowed files, and acceptance test. A package that can edit uses an isolated branch or worktree and may not edit another package's files. Research and review packages are read-only. Child reports must include facts and evidence, changes, tests and results, and remaining risks. Child tasks never run `git add`, `git commit`, `git push`, merge, release, or external messaging.

The repository's reusable role briefs live in `.codex/agents/`. `GOALS.md` records acceptance criteria; `PLANS.md` is the current board and decision log. Keep them factual and free of personal data.

## User-visible decisions

The owner decides whether to add or remove features, visible UI behavior or wording, defaults, and what data leaves the device. Technical fixes, tests, refactors, CI, and workflow repairs may proceed after evidence and passing checks. When a requested change is ambiguous, make the safest reversible technical progress and ask one focused product question only when the answer changes the product.

## Owner preferences

- Reply in concise Chinese and lead with the outcome.
- Preserve originals and unrelated work; start file organization read-only.
- Use synthetic data for tests and keep real photos, EXIF, GPS, paths, Apple Photos records, credentials, and memories outside git, CI, PRs, and artifacts.
- Keep the native app in `macos/`; `src/` is reference-only and `dist/` is generated.
- New screens or large UI changes need a single-file static sample covering empty, loading, expanded, and dangerous-confirmation states before implementation. Follow `docs/ui-quality-principles.md` and check roughly 900x600 and a large window.
- Every user-visible string has English, German, and Simplified Chinese.
- Release tags, publishing, and any external write require explicit owner approval.
