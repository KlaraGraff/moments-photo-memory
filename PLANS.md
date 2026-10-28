# Moments coordination board

Updated by the coordinator. This is the recovery point for a new thread.

## In progress

- **P102 measurement harness** — inspect the failed 5,000-item run, make the probe finish reliably, and collect complete 5,000/20,000 reports. Scope: PR #102 files only until the harness is accepted.
- **Performance baseline** — after P102 is reliable, rank the slowest shared mechanisms before assigning fixes. No optimization is selected from a guess.
- **People prominence research** — public Apple documentation plus read-only observation on the owner's Mac. Personal screenshots and observations stay outside the repository.

## Waiting for CI

- None in this checkout. PR #102's latest hosted UI run failed because the probe did not finish; the failure is evidence, not a passing baseline.

## Waiting for owner

- Agree on the quantitative responsiveness threshold after the completed baseline.
- Evaluate the user-visible effect of PR #101's Chapters AI behavior.
- Perform the small real-library checks for merged PR #100 when the owner is ready.

## Completed / verified

- Cloned the public repository and verified `main` at PR #100's merge.
- Verified open PRs and their latest checks with GitHub: #101 open/green, #102 draft/Linux green/macOS and UI skipped for the draft; the manual #102 UI probe failed after the People phase.
- Added this board, `GOALS.md`, and the Codex agent role files.

## Decision log

- Work starts from `main`; no integration branch.
- Synthetic data is used for scale measurements. Real Photos data is read-only and remains outside git.
- The measurement harness must be fixed or replaced before performance code changes are selected.
