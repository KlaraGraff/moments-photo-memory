# Moments goals

## Current goal: make the native app usable at library scale

Moments must remain responsive during a first import and while browsing a library of 5,000 and 20,000 synthetic photos. The work is evidence-led: the measurement harness must finish and record each requested phase before performance changes are chosen.

### Acceptance criteria

- The page probe reports first import, post-import work, People, Map, Timeline, Chapters, Library, viewer open/close, chapter open/close, and repeat navigation for both 5,000 and 20,000 synthetic items.
- Each report includes ready time, longest main-thread stall, stalls over 100 ms, main-thread busy time, memory, and a stack sample.
- Each performance fix has a before/after report from the same probe and a focused test.
- No real photos, paths, GPS, EXIF, Apple Photos records, or credentials enter git, CI logs, PRs, or artifacts.
- A reviewer independently checks cross-module, performance, schema, migration, CI, and workflow changes.

The concrete responsiveness threshold is a pending product decision. The coordinator will propose a threshold after the completed baseline is available.

## Separate product track: People prominence

Research Apple's public guidance and observe Apple Photos on the owner's Mac without changing the real library. Then align Moments' prominence/key-photo behavior with the evidence. Do not invent a new ranking rule from the phrase "main people" alone. Face scanning changes stay in one task with the existing #100 behavior and are never edited concurrently by two implementers.

## In flight

- PR #101: Chapters AI organization; awaiting owner evaluation and the required independent review before merge.
- PR #102: page-scale measurement harness; draft, Linux green, hosted macOS/UI probe incomplete.
- PR #100: iCloud originals are requested only for the item being viewed; merged, awaiting owner real-library confirmation.
