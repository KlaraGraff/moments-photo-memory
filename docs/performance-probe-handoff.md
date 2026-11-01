# Performance Probe Handoff

## Scope

Finish the current People, Map and 5k page-probe work on PR #103. Do not start the deferred 20k optimization. Keep all performance data synthetic; the quantitative acceptance thresholds in `GOALS.md` are still awaiting a product decision.

## Current Branch

- Branch: `codex/performance-probe`
- PR: https://github.com/KlaraGraff/moments-photo-memory/pull/103
- Latest implementation commit: `8da9c30` (`People: batch scan progress updates`); handoff update commit: `c5bee77`. The worktree is clean.
- The PR is open and ready for review. Do not start the deferred 20k tuning in this work package.

## Current Status

- Run `41254824378` passed both Linux jobs on `8da9c30`.
- Native macOS run `41254824345` passed on the same head.
- UI run `41254824348` generated synthetic fixtures, then remained in its main UI test step for about 42 minutes without reaching any report phase. It was cancelled; no People result is available from this run.
- Local verification on this head: `swift test --package-path macos/MomentsCore` passed 60/60; `python3 scripts/check_privacy.py` passed; `git diff --check` passed; the native app build succeeded. Xcode printed existing CoreSimulator-version and Swift concurrency/import warnings; the macOS build itself succeeded.
- The localization check needs Xcode's exported `.xcloc` files, so it is verified by the hosted native workflow rather than by the local privacy script.
- The docs-only push of `c5bee77` triggered Linux run `41258141503` (passed) plus native/UI runs `41258141504` and `41258141515`; the latter two were cancelled before reports because the code had already been checked on `8da9c30` and the workflow was still using the long combined smoke/probe job.

## Completed And Pushed

- `cbbafdc` fixes PageProbe's per-test wait to 50 minutes.
- `f4462ed` caches People face summaries and avoids rebuilding them for every scan batch.
- `9ce1a00` opens the real place cluster after a cross-page map focus request.
- `337074f` keeps synthetic `coarse-world:` buckets out of photo loading and retains the map request until a detailed cluster exists.
- The 5k report from run `41214019387` recorded all 14 phases. People timed out its 45-second settle window and two map navigation UI tests failed at that earlier head. The report's timings are diagnostic, not approved acceptance thresholds.

## Changes In This Batch

- `PeopleScreen.swift` limits initially rendered unnamed face groups to 24, then appends 24 when the loading sentinel appears. The prior 5k report showed People first content at 1.35 seconds, first thumbnail at 1.56 seconds, but a 44.75-second settle timeout and 43.47 seconds of main-thread work. Samples implicated `FaceObservation` view construction and per-face correction menus.
- Face scanning no longer publishes a main-actor progress callback for every image. Visible progress advances at each 16-photo batch boundary; scan results and cancellation behavior remain unchanged. This targets the repeated People view-graph updates seen in the samples.
- `ui-tests.yml` raises the UI job ceiling from 60 to 75 minutes. The full suite takes about 15 minutes before the PageProbe test begins, so its 50-minute wait could not finish under the old 60-minute job timeout.

## Verification Evidence

- On commit `337074f`, Linux checks passed, macOS native checks passed, and the local macOS app build passed.
- `swift test --package-path macos/MomentsCore` passed 60/60 locally.
- UI run `41223976577` was cancelled at the 60-minute workflow limit, not by an assertion. The probe test started at 17:35:31 UTC and was still waiting when the job ended at 18:20:38 UTC. Its report only contains the import phases and People; it contains no Map result. Screenshot export failed because the job timeout left an incomplete `.xcresult`.
The follow-up run `41231328545` tested commit `6939545` with the 75-minute job limit. Linux and native macOS passed. The UI run completed normally and produced all 14 page phases, but the probe still failed only at People: first content 1.30 s, first thumbnail 1.46 s, fully settled 44.89 s (timed out), 131 stalls over 100 ms, and 43.78 s main-thread busy. Map settled in 3.91 s; Timeline 3.83 s; Chapters 5.28 s; Library 2.12 s. The following UI tests, including both information-under-photos tests and map navigation tests, passed. The timeout increase fixed report truncation; it did not fix People.

The current head's native run `41254824345` passed. UI run `41254824348` was cancelled after no phase progress for about 42 minutes, so the full People page-probe result is unavailable. The last complete probe remains `41231328545` on `6939545`, where People timed out but Map and later phases completed.

## Next Steps

1. Treat the current code checks as complete except for hosted UI measurement: Linux, native macOS, local build, Core tests, privacy, and translation checks passed; the latest UI run was cancelled without a report.
2. Before another full probe, split `.github/workflows/ui-tests.yml` into an ordinary smoke job and a dedicated PageProbe job. Give PageProbe its own timeout, print a heartbeat after every phase, and fail with a diagnostic artifact when no phase advances for a bounded interval. Keep the existing 45-second per-page settle cap and 50-minute probe deadline, but make the outer job deadline independent of the smoke suite.
3. Run the dedicated PageProbe on `8da9c30` with 5,000 synthetic photos. Only after a complete report exists, decide whether the People progress change needs another code fix. Do not start 20k tuning.
4. If People still times out, use its report and stack samples to make one evidence-led fix within this People/probe scope, add or update a focused test, and rerun the dedicated probe.
5. Update this handoff with the final run ID, head SHA, complete phase timings, and any remaining uncertainty. Do not tag or release.

## Boundaries

- Do not start 20k tuning or change product-facing performance thresholds.
- Do not use real photos, GPS, paths or other personal library data in tests or artifacts.
- Keep the full UI suite enabled; the longer timeout exists to let the page probe report a real result, not to skip tests.
