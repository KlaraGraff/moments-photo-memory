# Moments · rules for coding agents

This file is the **only** place repository rules live. Change a rule by redesigning the section it belongs to and updating this file in the same change; do not add patches elsewhere (no second rules file, no progress board). Progress, plans and status belong to the project threads and their checklists, not to the repository.

## Project

Moments is a private macOS app for two people to organize photos, places and shared memories. macOS only; no Windows support.

- The app is a **native SwiftUI app** in `macos/` (macOS 14+, SwiftData, Vision and a bundled SFace model for faces, MapKit, PhotoKit; CloudKit sharing is designed in `docs/sharing-design.md` but not built).
- The web prototype in `src/` is an interaction reference only: do not embed it in the app or extend it. Never hand-edit `dist/`; it is generated.
- A cloud sandbox can run Python, Node, the privacy check and the `MomentsCore` package tests (Linux). It cannot build the Swift app; the GitHub macOS runner does that.
- The owner's Mac runs a newer macOS than the GitHub runner and has no Apple Intelligence, so some problems appear only there. Reproduce on the runner first; if that is impossible, say the fix is a guess and ask for a check on the Mac.

## Who decides

- **The owner decides product questions**: adding or removing features, visible UI style and interaction trade-offs, any user-visible text (even one word), defaults, and what data leaves the device (for example what an AI feature sends). Test: would the owner notice it and possibly disagree? If so, ask. Ask once, with a recommendation.
- **Everything else is technical** (bug fixes, optimizations, refactors, tests, CI and workflow changes) and goes ahead once evidence and checks pass. Never ask "can I merge?" for these.
- Never invent a product-level acceptance threshold (for example a performance target). Propose one with evidence and let the owner confirm it.
- If a request can be read two ways, start on the most likely reading and say which one you chose.

## Threads and work split

- The project coordinator talks with the owner and starts threads with a brief: the owner's words, done criteria, background and hard limits. Threads message each other only when their work depends on each other.
- A large request gets a planning thread first. The planning thread only plans. The plan is split into work packages that do not overlap (different screens, files or modules); each package gets its own thread and branch. Run 2 to 4 code threads at a time, and never give one module to two threads at once.
- Model and effort when starting a thread: lookups, checks and setup guidance: Sonnet 5.5 medium; documentation and copy: Sonnet 5.5 high; ordinary bug fixes and small features: Opus 5.5 medium; cross-module work, performance, algorithms and planning: Opus 5.5 xhigh. A mixed task takes the highest tier it needs. The independent review (see Review) is a separate job at Opus 5.5 high. Do not use Fable unless the owner names it.
- After a thread's PR merges, reset its branch to the latest `main` before the next PR on that branch.
- Helper services outside the project (for example a delegated coding agent on a third-party relay) may only receive content that is already in this public repository. Never send them photos, EXIF, GPS, real paths, Apple Photos data, personal memories or credentials, and strip gitignored files such as `macos/Config/Local.xcconfig` from anything handed over.

## Pull requests

- Every PR is based on `main`. Never base a PR on another PR's branch, and there is no integration or "assemble the preview" thread.
- Keep PRs small, one concern each. When two PRs touch the same file, whoever merges second merges `main` into the branch and resolves the conflict.
- Split a PR that mixes fixes with a product decision, so the fixes can merge while the decision waits.
- Open the PR as a **draft** while iterating: drafts get only the fast Linux checks. Mark it ready once Linux is green and your own checks have run; that starts the Mac checks, once per push (see CI).
- **Right after opening a PR, subscribe to its activity (`subscribe_pr_activity`) and end the turn.** CI results, reviews and merge conflicts wake the thread. Never sleep, poll, or schedule a "check CI every few minutes" routine. A scheduled check-in is only for something time-based that no event announces; space such check-ins further apart each time and stop after a few with no change.
- Tell the owner about a PR at most twice: when it is up, and when it needs them. Fixes in between go on the checklist.
- A PR that has no checks yet, or whose checks are skipped, is not green. Never claim a check passed when it was skipped.

## Merging

- The author thread squash-merges its own PR once every check is green on the head commit and its self-test passed, then tells the owner. Use the PR title with its number as the commit title.
- Before merging confirm that the `macOS` run, and the `macOS UI tests` run when the PR touches the app, finished successfully on the head commit **after** the PR was marked ready. Docs-only PRs need only the Linux checks.
- PRs that wait for the owner: anything that is a product decision (see Who decides) and any release step.
- **Docs-only small edits** (this file, comments, notes): run the privacy and whitespace checks locally, then push straight to `main`; no PR.
- Red CI: first check whether `main` is red too. If so, fix `main` in its own small PR instead of working around it. Otherwise the author reads the log, fixes and pushes until green.
- A job that died before any test ran (checkout, install, runner loss) may be re-run once ("Re-run failed jobs"). A second failure is real.
- Never skip, disable or quarantine a test to get green; never push an empty commit or close and reopen a PR to re-run CI; never rewrite history on someone else's branch.
- Tagging and releases always need the owner's go-ahead (see Releases).

## Review

Default quality comes from the author's self-test plus CI. An extra independent review by Opus 5.5 at high effort is required before merging only for schema or migration changes, cross-module changes, performance work, and CI or workflow changes; there is no other review tier. The reviewer is read-only: it checks the diff against `main`, the acceptance criteria, the privacy rules and the named tests, reports findings with file and line references (most severe first), lists missing tests and risks, and ends with exactly one verdict: `APPROVED` or `CHANGES_REQUESTED`.

## CI

| Workflow | Runs on | When | What |
|---|---|---|---|
| `linux.yml` | ubuntu | every push to a PR (drafts included) and to `main` | `swift test` for the `MomentsCore` package; prototype build, Node checks, privacy check, whitespace check |
| `macos.yml` | hosted Mac | ready (non-draft) PRs and `main`; not for docs-only changes | app build + `MomentsTests`, UI test compile, `MomentsCore` tests, Apple Photos bridge checks, translation check |
| `ui-tests.yml` | hosted Mac | ready PRs touching the app and `main` | the whole UI suite with synthetic data |

- A new push cancels the older run of the same PR, so each PR head is checked once. On `main` only the newest commit is checked.
- For a quick UI probe, dispatch `ui-tests.yml` by hand with `only_testing` (for example `MomentsUITests/MomentsUITests/testDoubleClickRenamesATripInPlace`). Manual runs are never cancelled.
- The log API returns only about the last 5,000 lines: look for the `FAILURES-BEGIN`/`FAILURES-END` block, and rerun a single test with `only_testing`. Artifact zips may fail to download.
- Logic that needs no AppKit, SwiftUI, SwiftData, CoreGraphics or ImageIO belongs in the `MomentsCore` package (`macos/MomentsCore`) with its tests there, so Linux checks it in minutes. Guard any Apple-only API in the package with `#if canImport(...)`.
- Hosted Macs are scarce: no extra macOS jobs or workflows without a reason; prefer adding steps to `macos.yml`. A temporary switch to another runner image to reproduce a problem is fine; switch back afterwards.
- CI builds without signing. Signing and packaging happen locally on the Mac.

## Verification before handing over

- A build or static check alone is not verification. Run at least one test that exercises the change (`swift test`, XCTest, or a UI test on the runner) and name it in the PR. Docs-only changes are exempt; run the privacy check instead.
- State plainly what you did not run, why, and what could break. "Should be fine" is not verified. Never say something got faster without a before/after measurement.
- Verify in the cloud or on the runner whatever can be verified there, using synthetic data. UI display, settings persistence, search and logic checks do not need the owner's Mac. Ask for a check on the Mac only for what truly needs it: the real Photos library, real user data, signing, real Apple Photos behavior, or a problem seen only on the newer macOS. Hand over a short list: what is already verified, and the exact items left.
- Tests never take over the owner's screen (UI tests run on the runner; unit-test hosts open no windows) and never read or write the real store, settings or the app's Application Support folder; use in-memory stores or temporary directories.
- When fixing a UI bug, check every screen the change touches, not only the one reported. When the same kind of bug shows up a second time, fix the shared mechanism and sweep all screens.
- Design and test for a first import of 20,000 to 50,000 photos, not only a few thousand.

## Bug reports

The owner's description is a hint for locating the bug, not a diagnosis. If what or where is unclear (which screen, which control, when), ask briefly; do not guess click positions. If the bug is hard to describe (flashes, jitter, timing, visual glitches), reproduce it on the runner and confirm the cause with evidence (test output, logged values, recorded frames) before fixing, then show the same check passing after the fix. Do not fix on a guess and do not ask the owner to diagnose. Do not state why something is slow or failing until the cause is checked.

## Performance work

- Evidence first: finish the measurement harness and record each phase before choosing fixes. Suspects (loading every photo at once, database queries or image decoding on the main thread, grids without on-demand loading, whole-page recomputation on every change, background work after import saturating the main thread) are directions, not conclusions.
- The page probe measures, on synthetic libraries of 5,000 and 20,000 items: first import, post-import work, People, Map, Timeline, Chapters, Library, viewer open/close, chapter open/close, and repeat navigation. Each report gives ready time, longest main-thread stall, count of stalls over 100 ms, main-thread busy time, memory and a stack sample.
- Each performance fix carries a before/after report from the same probe and a focused test, and fixes the shared mechanism when the same slowness appears on several pages. Performance PRs get the independent review.
- The responsiveness threshold is the owner's decision (see Who decides).

## People and iCloud

- People prominence follows Apple Photos' actual behavior as far as it can be observed or is publicly documented; do not invent a ranking rule from a phrase like "main people". Observation notes and screenshots of the owner's library stay outside the repository.
- Original photos are downloaded from iCloud only when the owner opens a large view or plays a video. Face scanning, burst detection and every other background job use only images already on the device. Missing a very small face is an accepted cost.
- Face-scanning changes live in one task at a time; two implementers never edit them concurrently.

## Preview for the owner

One on-Mac preview thread keeps the owner's preview build on the latest `main`, updated in batches after several merges and only when the owner is idle (unless asked). Other threads do not build on the owner's Mac. Routine Mac steps (installing test tools, running draft builds, making temporary directories) need no question, but use **copies** of the real store and library, never the originals, and never publish. Builds go only in `*.noindex` folders. If the preview thread stalls, check and restart it instead of waiting on it.

## Data compatibility

- Every schema change ships a migration and a test that opens a store from the previous schema with data in it.
- A store that cannot be opened is never deleted or overwritten. Copy it to a timestamped backup path, start a usable store, and tell the user where the backup is.
- Before a release, upgrade a copy of the previous version's real store on the Mac (never the original).

## Privacy (hard rules)

- Never commit photos, videos, previews, EXIF, real GPS, real place history, real paths, Apple Photos data, pairing tokens, credentials or personal memories. The repository is public (only to use free hosted Macs): add no README, description or topics.
- API keys live only in the Keychain, never in code, docs or logs.
- Personal data lives only in gitignored `private-data/`, `dist/` or the app's Application Support folder on the Mac.
- `demo/sample-data.json` stays synthetic (`kind: synthetic-demo-only`, coordinates near 0,0). Tests and scale measurements use synthetic data.
- When adding a new file type or folder, extend the allowlist in `scripts/check_privacy.py` narrowly.
- Do not put personal details about the owner or their partner in repository files.

## UI

- Follow `docs/ui-quality-principles.md`, adapted to native macOS conventions. New screens and sheets use the shared Paper design layer in `macos/Sources/Moments/Design/Paper.swift` (tones, text field style, sheets, form labels, motion).
- The interface is locked to light appearance. Check every UI change at a small window (about 900×600) as well as a large one. When space is tight show icons only, otherwise icon and label.
- Every user-visible string needs German and Chinese (Simplified) as well as English. Add them with `scripts/add_translations.py`; the translation check in `macos.yml` fails on any string missing de or zh-Hans.
- **Big UI changes need a mock-up before implementation.** Make a single-file static HTML sample (synthetic data only, no build step) that shows the states that matter: empty, loading, normal or expanded, and any dangerous confirmation. Show it to the owner and implement after they agree. Big means any of: a new screen, sheet or panel; a changed layout or navigation structure; a new interaction pattern (gesture, drag, multi-step flow); or a change to how a whole page looks. Small means no mock-up: bug fixes, spacing or alignment, wording of existing strings (still the owner's call, see Who decides), icon swaps, moving one control within the same container, and adding a state to an existing view in the existing style. When unsure, treat it as small if the owner can judge it from one screenshot after the fact, otherwise as big.
- Respect reduced motion. Never lose user input, memories, tags or filter state on view switches.

## Before marking a PR ready

```sh
swift test --package-path macos/MomentsCore   # if you have a Swift toolchain
python3 -m unittest discover -s tests          # builds dist/ first
for f in tests/check-*.mjs; do node "$f" || exit 1; done
python3 scripts/check_privacy.py
git diff --check
```
On a Mac, also `python3 tests/check-apple-host.py` and `python3 tests/check-apple-bridge.py`. Swift app code is verified by `macos.yml` and `ui-tests.yml`; a Linux sandbox cannot build it. The app build command used by CI is `xcodegen generate --spec macos/project.yml` followed by `xcodebuild -project macos/Moments.xcodeproj -scheme Moments -destination 'platform=macOS' -derivedDataPath macos/.derivedData CODE_SIGNING_ALLOWED=NO build test`.

## Releases

- Tagging and publishing need the repository owner's explicit go-ahead for each step.
- Version: bug-fix releases bump the third number, features the second, a change in what the app fundamentally is the first.
- Release notes are written for the app's two users in plain language, Chinese first, each item one or two sentences saying what it was like before and what it is like now. No implementation details; leave out problems introduced and fixed within the same cycle; merge pure UI polish into one line. State signing and notarization from the actual build, never copied from the previous release.

## Working with the owner

- Reply in concise Chinese, lead with the outcome, and say what is done, in progress, and waiting on the owner. Keep long material in a file.
- Preserve originals and unrelated work; start file organization read-only.
- Release tags, publishing, and any external write need explicit owner approval.
