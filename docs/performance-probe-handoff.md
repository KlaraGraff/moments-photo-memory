# Performance Probe Handoff

## Scope

Finish the current People, Map and 5k page-probe work on PR #103. Do not start the deferred 20k optimization. Keep all performance data synthetic; the quantitative acceptance thresholds in `GOALS.md` are still awaiting a product decision.

## Current Branch

- Branch: `codex/performance-probe`
- PR: https://github.com/KlaraGraff/moments-photo-memory/pull/103
- Last pushed commit: `337074f` (`Map: defer photo loading until detailed cluster`)
- Two local, uncommitted changes remain: `macos/Sources/Moments/People/PeopleScreen.swift` and `.github/workflows/ui-tests.yml`.

## Completed And Pushed

- `cbbafdc` fixes PageProbe's per-test wait to 50 minutes.
- `f4462ed` caches People face summaries and avoids rebuilding them for every scan batch.
- `9ce1a00` opens the real place cluster after a cross-page map focus request.
- `337074f` keeps synthetic `coarse-world:` buckets out of photo loading and retains the map request until a detailed cluster exists.
- The 5k report from run `41214019387` recorded all 14 phases. People timed out its 45-second settle window and two map navigation UI tests failed at that earlier head. The report's timings are diagnostic, not approved acceptance thresholds.

## Current Unpushed Changes

- `PeopleScreen.swift` limits initially rendered unnamed face groups to 24, then appends 24 when the loading sentinel appears. The prior 5k report showed People first content at 1.35 seconds, first thumbnail at 1.56 seconds, but a 44.75-second settle timeout and 43.47 seconds of main-thread work. Samples implicated `FaceObservation` view construction and per-face correction menus.
- `ui-tests.yml` raises the UI job ceiling from 60 to 75 minutes. The full suite takes about 15 minutes before the PageProbe test begins, so its 50-minute wait could not finish under the old 60-minute job timeout.

## Verification Evidence

- On commit `337074f`, Linux checks passed, macOS native checks passed, and the local macOS app build passed.
- `swift test --package-path macos/MomentsCore` passed 60/60 locally.
- UI run `41223976577` was cancelled at the 60-minute workflow limit, not by an assertion. The probe test started at 17:35:31 UTC and was still waiting when the job ended at 18:20:38 UTC. Its report only contains the import phases and People; it contains no Map result. Screenshot export failed because the job timeout left an incomplete `.xcresult`.
- The current local People/workflow changes have not yet been tested on the hosted Mac.

## Next Steps

1. Finish the independent review of the two local changes; address any concrete issue.
2. Run `git diff --check`, the app build, `swift test --package-path macos/MomentsCore`, and the repository's privacy and translation checks.
3. Commit and push the local changes to PR #103. The new push should start Linux, native macOS, and the 75-minute UI workflow.
4. Read the complete 5k page report from the new UI run. Confirm the People phase no longer times out and that Map and the following page phases complete; confirm both map-focus tests pass.
5. Only when every required check on the head commit is green, follow the repository rule to squash-merge PR #103 using the PR title and number. Do not tag or release.

## Boundaries

- Do not start 20k tuning or change product-facing performance thresholds.
- Do not use real photos, GPS, paths or other personal library data in tests or artifacts.
- Keep the full UI suite enabled; the longer timeout exists to let the page probe report a real result, not to skip tests.
