# Moments coordination board

Updated by the coordinator. This is the recovery point for a new thread.

## In progress

- **P102 measurement harness** — inspect the failed 5,000-item run, make the probe finish reliably, and collect complete 5,000/20,000 reports. Scope: the probe and its test until the harness is accepted. The latest hosted 5,000-item run measured People at its 45 s page timeout; XCTest's separate 26.9 min total deadline then expired during that phase because it omitted the actual import duration. The test now allows up to 50 min within the workflow's 60 min job ceiling, leaving suite startup and teardown margin.
- **Performance backend redesign** — replace per-screen SwiftData-derived work with a shared background projection. P1/P2 are in PR #103; screen migration is partial and needs independent review plus hosted probe evidence.
- **Performance baseline** — use completed probe evidence to rank the slowest shared mechanisms before assigning the next non-overlapping packages. No optimization is selected from a guess.
- **People prominence research** — public Apple documentation plus read-only observation on the owner's Mac. Personal screenshots and observations stay outside the repository.

## Delegated work

- probe_research — read-only audit of the incomplete hosted page probe and a reliable continuation design.
- projection_review — read-only concurrency and data-consistency review of the shared library projection.
- independent_reviewer — read-only review of the current cross-module performance changes, CI and privacy risks.

## Waiting for CI

- PR #103 needs a fresh hosted UI run after correcting the XCTest total deadline. The latest hosted 5,000-item run stopped after the People report, before Map and later phases, so it is diagnostic evidence, not a complete baseline.

## Waiting for owner

- Agree on the quantitative responsiveness threshold after the completed baseline.
- Evaluate the user-visible effect of PR #101's Chapters AI behavior.
- Perform the small real-library checks for merged PR #100 when the owner is ready.

## Completed / verified

- Cloned the public repository and verified `main` at PR #100's merge.
- Verified open PRs and their latest checks with GitHub: #101 open/green, #102 draft/Linux green/macOS and UI skipped for the draft; the manual #102 UI probe failed after the People phase.
- Added this board, `GOALS.md`, and the Codex agent role files.
- Added the projection design and initial implementation on PR #103; local app build and tests pass.
- Hosted 5,000-item probe run `40750890590` completed all 14 phases. Timeline, Chapters, and repeat navigation timed out, so this is diagnostic baseline evidence rather than a responsiveness pass.
- Projection invalidation now coalesces SwiftData saves, publishes a revision for Timeline/Chapters/Map rebuilds, and resolves display names before publishing.
- Hosted 5,000-item probe run `40754894000` on `9363f44` completed all 14 phases with no timeout; Map ready was 10.77 s and Timeline ready was 26.61 s.
- Hosted 20,000-item runs `40757239709`, `40765465778`, `40775038910`, and `40787759587` all reached import, post-import work, and People, then stalled before Map. The remaining blocker is page-switch initialization on the hosted Mac; no complete 20k page report exists yet.

## Decision log

- Work starts from `main`; no integration branch.
- Synthetic data is used for scale measurements. Real Photos data is read-only and remains outside git.
- The measurement harness must be fixed or replaced before performance code changes are selected.
