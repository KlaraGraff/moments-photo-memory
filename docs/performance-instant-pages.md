# Moments Instant Page Switching and Progressive Library Loading

## 1. Purpose

This document defines the implementation for making every sidebar/page switch feel immediate while keeping large libraries scalable. The product behavior is:

1. Clicking a page changes the destination immediately.
2. The destination page shell is visible within 300 ms when the app is idle.
3. The first useful content (title, filters, first visible cards or map pins) appears within 1 second on the 5,000- and 20,000-item synthetic probes.
4. Additional content is built and loaded in the background, in cancellation-safe batches.
5. A page never waits for the complete library before becoming interactive.

A page may show an empty state, skeletons, a previous immutable snapshot, or a partial result while work continues. The page must preserve selection, filters, scroll position, and user edits.

## 2. Evidence and current bottlenecks

The current implementation already has a disposable `LibraryProjection`, but several screens still own full SwiftData queries. The main blockers are:

- `ContentView`, `LibraryView`, `TimelineScreen`, and `TripsScreen` materialize large `@Query` arrays while the destination view is being created.
- `TimelineScreen.inputKey` hashes every visible model and `rebuild()` creates the complete timeline before it can render.
- `MapScreen` still creates the MapKit graph and annotations for the current snapshot before the first usable map state; some tasks are detached but are not fully cancellation-aware.
- Library, People, Timeline, Chapters and group screens do not share one page-loading state or batch contract.
- `LibraryProjectionStore` publishes a complete projection only. It has no page-seed or batch API, and data changes outside import are not yet uniformly invalidating it.
- Existing probe completion can be reported after a timeout, so “test finished” must be separated from “page met the responsiveness threshold”.

The implementation must address the shared mechanisms rather than add per-screen timers or arbitrary sleeps.

## 3. Product behavior and performance contract

### 3.1 First-frame contract

For every destination (`Library`, `People`, `Map`, `Timeline`, `Chapters`, groups, and `Recently Deleted`):

- Selection changes synchronously.
- The destination shell does not require a full SwiftData fetch.
- A cold page shows its title and loading/empty shell immediately.
- A warm page shows its last valid immutable snapshot immediately, then refreshes in place.
- A page is considered usable when the first visible controls and first batch of content are available; background completion is not required for the first-frame assertion.

Recommended budgets:

- `selection-to-shell`: p95 <= 300 ms.
- `selection-to-first-content`: p95 <= 1.0 s.
- `first-thumbnail`: p95 <= 2.0 s after first content when a local thumbnail exists.
- No intentional main-thread stretch >= 100 ms during page selection at 5,000 items. Existing MapKit or OS tile stalls must be reported separately.

The probe must report both `firstContent` and `fullySettled`; the latter may remain long for a large import.

### 3.2 Loading states

Use one shared state model:

```swift
enum PageLoadPhase: Equatable, Sendable {
    case idle
    case loading(generation: Int)
    case partial(loaded: Int, total: Int?, generation: Int)
    case ready(total: Int, generation: Int)
    case empty(generation: Int)
    case failed(messageKey: String, generation: Int)
}
```

The model is UI state only. It must not contain SwiftData models. `generation` prevents stale results from an earlier filter, page switch, or zoom from publishing into the current page.

Rules:

- `loading` renders the page shell and a small skeleton; it never blocks navigation.
- `partial` renders available batches and a quiet progress indicator. Do not replace already rendered cards.
- `ready` removes the progress indicator.
- `empty` is emitted only after the current filter query has completed.
- `failed` preserves the last valid snapshot when one exists and offers retry.
- Cancellation is silent and never becomes an error state.

### 3.3 Batch contract

Add a value-only, sendable request/result contract in `MomentsCore`:

```swift
public struct PageBatchRequest: Equatable, Sendable {
    public let generation: Int
    public let offset: Int
    public let limit: Int
    public let anchor: String?       // day/month/place/camera bucket
    public let filter: LibraryProjectionFilter
}

public struct PageBatch<T: Sendable>: Sendable {
    public let generation: Int
    public let offset: Int
    public let values: [T]
    public let total: Int?
    public let hasMore: Bool
}
```

If a generic public type is inconvenient for Swift 5.9 compatibility, use concrete `PhotoPageBatch`, `TimelinePageBatch`, and `ChapterPageBatch` with the same fields. No `MediaItem`, `Trip`, `Place`, or other SwiftData model may cross the boundary.

Default batch sizes:

- Library grid: 36 cards, prefetch one additional batch.
- Timeline: 2 months or 60 dated photos, whichever is smaller for the first batch; subsequent batches 2 months/120 photos.
- Chapters/Trips: 12 chapter cards, then 12 per request.
- People: all lightweight person summaries, then 24 photo covers per selected person.
- Recently Deleted: 36 cards.
- Map pins are governed by the LOD caps below, not offset pagination.

Every request receives a cancellation check before reading, after reading, and before publishing.

## 4. Data architecture

### 4.1 Projection source of truth

`LibraryProjectionStore` remains disposable derived state. SwiftData remains authoritative. Extend the projection with:

- stable ordered photo IDs for each filterable sort order;
- lightweight people summaries and person-to-photo ID lists;
- chapter/trip summaries and their photo ID lists;
- deleted-item summaries for Recently Deleted;
- thumbnail reference metadata (ID, size class, local asset availability), without file paths or personal EXIF;
- revision and source-change generation.

Do not add a schema migration. All additions are in-memory value types.

### 4.2 Invalidation

Create one coalescing invalidation path for import, delete/restore, date/place/person correction, group membership, notes, stacks, and trip/chapter edits. The path schedules one projection rebuild after a short debounce, increments the source generation, cancels the old build, and publishes one revision after a complete immutable snapshot.

A page request captures both `projection.revision` and its own request generation. It may publish only when both still match. Initial empty projection publication must also increment the revision so pages that mounted before the first build rebuild once.

### 4.3 SwiftData access

The projection reader creates a background `ModelContext` and fetches only scalar fields and relationship IDs needed by the descriptors. Page views must not hash or sort the complete SwiftData arrays in `body` or in a `.task(id:)` key.

Detail actions may fetch selected IDs on the main model context after a user opens a place, photo, person, chapter, or editor. The fetch must be bounded to the selected IDs and must not fetch the full library as a fallback.

## 5. Page host and caching

Add a shared page host around the `NavigationSplitView` detail column. The host owns:

- current destination;
- a bounded cache of page shells and immutable page snapshots;
- one cancellation token per destination;
- last visible scroll anchors for Library/Timeline/Chapters;
- current filter revision.

The cache holds value snapshots and IDs, not full SwiftData object graphs. Retain the current page and at most one recently visited heavy page; evict older batches by generation. A destination switch cancels work for the old page unless it is already within the prefetch window.

Use `PageHost` to preserve state rather than keeping every SwiftUI screen permanently mounted. If a page is already warm, render its cached snapshot synchronously and schedule validation in the background.

## 6. Progressive page rules

### Library

- Replace the page's full-library body dependency with projection descriptors and bounded detail fetches.
- Compute matching IDs off the main actor once per filter revision.
- Render the first 36 IDs in a `LazyVGrid`; request another batch when the last visible card enters a one-screen prefetch threshold.
- Keep the existing selection, filter, grid density, and scroll anchor.
- Thumbnail loading uses the existing cache and adds cancellation-aware prefetch for the next batch.

### Timeline

- Build a lightweight day/month index from projection descriptors.
- Render the first two visible months/60 photos as soon as the index is available.
- Append later months when the scroll sentinel approaches the end.
- Keep memory lines and trip links as ID-based summaries; fetch full records only when a user opens or edits them.
- Remove the full-array `inputKey` hash and replace it with `(projectionRevision, filterRevision, loadedAnchor)`.

### Chapters and Trips

- Show chapter/trip summary cards first.
- Load photos for a chapter only when its card enters the viewport or the user opens it.
- For an opened chapter, render the first 36 photos and append on scroll.
- Preserve manual chapter edits and chapter selection while background batches arrive.

### People

- Render people names, counts, and cover IDs from projection summaries.
- Load covers in small batches and load the selected person's full photo list only after selection.
- Keep the existing face confirmation/editing flow on SwiftData; only browsing is progressive.

### Recently Deleted and groups

- Build summary rows from projection descriptors.
- Keep deletion confirmation synchronous and safe: the confirmation must not be bypassed by a background load.
- Resolve smart-group membership from the projection for browsing; detail edits still use SwiftData.

## 7. Map level-of-detail and batching

The map must never create an annotation for every photo at globe scale.

### 7.1 Caps

Use deterministic spatial buckets so every region contributes to the result:

- Globe: at most 120 regional clusters; no photo thumbnails and no route polylines.
- Country/continent: at most 240 clusters; use lightweight count pins and optional representative thumbnails only for visible buckets.
- City/area: at most 400 clusters; load visible place thumbnails and routes in batches.
- Local place: no arbitrary cap for the selected place, but thumbnails use the normal visible-window batch.

The exact bucket count is a constant in the Map LOD policy, covered by tests. A bucket carries total photo count, date range, center, child bucket IDs, and one deterministic representative ID.

### 7.2 Zoom behavior

- Initial map shell and globe pins publish as soon as the base projection is available.
- Zooming computes only the target level and current camera bounds.
- A zoom task cancels the previous zoom task and publishes only if its camera generation still matches.
- Zoom-in reveals child buckets, then place pins, then thumbnails/routes.
- Zoom-out discards detailed child annotations immediately and returns to the capped aggregate view.
- Clicking a globe bucket zooms to its center; clicking a closer cluster loads only that cluster's selected IDs.

Do not display a misleading “complete” state while a requested level is still loading. Show a small non-blocking loading indicator near the map controls.

## 8. Thumbnail and memory policy

- The first page batch requests only thumbnail-size assets.
- Prefetch at most one batch ahead and cancel requests outside the viewport plus one batch.
- Full-resolution assets are requested only by the viewer.
- Keep the existing cache key and add size class/scale to prevent a large viewer image from evicting all grid thumbnails.
- Never put real paths, EXIF, GPS, or photo bytes into projection fixtures, tests, or git.

## 9. Static preview gate

Before changing the native UI, create `docs/performance-instant-pages-preview.html` as a single-file, synthetic-data visual sample. It must show at least:

- Library: empty, loading, first batch plus “more loading”, and filter change;
- Timeline/Chapters: shell, partial list, expanded chapter, and scroll continuation;
- Map: globe cap, zoomed detail, loading cancellation, and selected cluster;
- dangerous confirmation: delete-group or delete-photo confirmation without destructive execution.

The preview is a design/interaction review artifact only. It does not become app code and must not contain personal data. Native implementation begins after the preview is available for review.

## 10. Work packages

Each package owns the listed files and must not edit another package's files. Child agents do not add, commit, push, merge, or send external messages. The coordinator reviews and integrates all changes.

### P1 — Core paging and projection contract

Files: `macos/MomentsCore/Sources/MomentsCore/Library/LibraryProjection.swift`, new value-type files in the same folder, and `macos/MomentsCore/Tests/MomentsCoreTests/Library/`.

Implement the page batch contracts, projection indexes/summaries, filter matching, deterministic pagination, and Map LOD bucket value types. Add Linux-runnable tests for ordering, generation fields, filters, batch boundaries, and bucket caps. Do not change SwiftUI views.

### P2 — Projection store, invalidation, and page host

Files: `macos/Sources/Moments/Library/LibraryProjectionStore.swift`, new `macos/Sources/Moments/Performance/` files, `macos/Sources/Moments/Views.swift`, and focused app tests if available.

Implement coalesced invalidation for all known save paths, cancellation-safe projection builds, the bounded page cache, and `PageHost`/`PageLoadPhase` integration at the detail-column boundary. Keep the existing page bodies compiling; provide adapters if needed. Do not implement per-page grids or Map annotations.

### P3 — Library and thumbnail progressive loading

Files: `macos/Sources/Moments/Library/LibraryView.swift`, `LibraryModel.swift`, `ThumbnailCache.swift`, and Library tests.

Migrate browsing from full-library view-body work to projection batches. Implement first-batch rendering, scroll-triggered loading, state preservation, thumbnail prefetch/cancellation, and cold/warm loading states. Detail editors may continue to use bounded SwiftData fetches.

### P4 — Timeline, Chapters, Trips, People, and groups

Files: `macos/Sources/Moments/Timeline/TimelineScreen.swift`, `TripsScreen.swift`, `ChapterViews.swift`, `People/PeopleScreen.swift`, `Views.swift` group adapters only if P2 leaves a narrow hook, and related tests.

Implement page seeds and progressive batches for Timeline, Chapters/Trips, People, groups, and Recently Deleted. Remove full-array build keys and keep edits/detail actions correct. Do not alter Map LOD or the projection core contracts beyond an explicitly documented adapter need.

### P5 — Map LOD and progressive map assets

Files: `macos/Sources/Moments/Map/MapScreen.swift`, new Map LOD helper files, and Map tests.

Implement globe/country/city/local caps, deterministic bucket aggregation, viewport-aware batches, cancellation on zoom/filter changes, and selected-cluster detail loading. Preserve existing controls and map selection semantics. Do not fetch the full SwiftData library during the first map frame.

### P6 — Preview, probe, and acceptance checks

Files: `docs/performance-instant-pages-preview.html`, `macos/Sources/Moments/PageProbe.swift`, `macos/Tests/MomentsUITests/` page-probe tests, and narrowly scoped test scripts.

Create the static preview before native UI work, extend the probe to record selection-to-shell, first-content, first-thumbnail, fully-settled, cancellation, and memory metrics, and add acceptance assertions for 5k/20k synthetic libraries. A timeout must fail the responsiveness assertion even if the test process exits cleanly. Do not weaken existing tests.

## 11. Dependency and integration order

1. P1 defines value contracts and tests.
2. P6 creates the static preview and probe schema; it may use temporary placeholder values until P1 is merged.
3. P2 adds the store and host adapters.
4. P3, P4, and P5 implement screens in parallel after the contracts exist. They must keep the app compiling against the host adapters.
5. P6 runs the complete verification sweep after all packages land.

If a package needs another package's type, depend on the documented contract and add a small adapter in the owning package. Do not edit another package's implementation file to make integration easier.

## 12. Verification and acceptance

Required before a PR is ready:

```sh
swift test --package-path macos/MomentsCore
python3 -m unittest discover -s tests
for f in tests/check-*.mjs; do node "$f" || exit 1; done
python3 scripts/check_privacy.py
git diff --check
```

On a hosted Mac also run the app build, `MomentsTests`, `MomentsUITests`, `python3 tests/check-apple-host.py`, and `python3 tests/check-apple-bridge.py` as applicable.

The final probe must show, separately for cold and warm switches:

- every destination reaches shell state within 300 ms p95;
- every destination reaches first useful content within 1 s p95 at 5,000 items;
- 20,000 items reaches shell and first content without waiting for full projection completion;
- Map globe stays within the configured annotation cap;
- scrolling appends batches without losing filters, selection, or scroll anchors;
- no stale generation publishes after a switch, filter change, or zoom cancellation;
- no real personal data enters fixtures, reports, artifacts, or commits.

A full projection rebuild may still take longer after import. That is acceptable only when the page shell and the currently visible batch remain interactive.

## 13. Known risks and mitigations

- **Stale snapshot shown briefly:** label only the loading/refresh affordance; never mix results from different filter generations.
- **Memory growth from page caching:** retain value descriptors and bounded batches, not model graphs; measure footprint after warm navigation.
- **Map bucket hides detail:** expose counts and zoom affordance; use deterministic spatial buckets and selected-bucket expansion.
- **Cancellation races:** generation checks at every await and before publish; add tests for rapid switch/filter/zoom sequences.
- **SwiftUI layout churn:** keep `body` keys small and revision-based; do not hash full model arrays.
- **Platform variance:** report p50/p95 and hosted-run IDs; do not claim a fixed wall-clock guarantee from one CI host.
