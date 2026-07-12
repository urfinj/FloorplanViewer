# FloorplanViewer

Native SwiftUI/iOS viewer for automatically downloaded, offline DZI floorplans. The app prepares
three project packages without a download button, renders only visible tiles with `CATiledLayer`,
and stores package state and normalized markers in GRDB.

## Run

Requirements: Xcode 26, an iOS 17+ simulator, XcodeGen 2.45+, SwiftFormat 0.62+, SwiftLint 0.65+,
and xcbeautify.

```sh
make generate
open FloorplanViewer.xcodeproj
```

Run the `FloorplanViewer` scheme on an iPhone or iPad simulator. Useful verification commands:

```sh
make lint
make test
make build
```

`project.yml` is the source of truth for the generated Xcode project. Package endpoints are
centralized in `PackageCatalog`; the current development mirror is intentional and should not be
changed as part of unrelated work. Server-owned catalog names/URLs are synchronized into existing
databases at launch by stable project ID, without invalidating downloaded files or markers.

## Dependencies

- **GRDB 7** — mandatory persistence layer, using a WAL `DatabasePool`, migrations, foreign keys,
  repositories, and `ValueObservation` async streams.
- **SWCompression 4** — the assignment-sanctioned small archive dependency, used for gzip and tar.
  Extraction is wrapped behind `ArchiveExtracting`, guarded against traversal/special entries,
  bounded by entry count and expanded size, and exercised independently in tests.

No web viewer or full architecture framework is used.

## Architecture

```text
SwiftUI views -> @MainActor observable models -> repositories / service protocols
                                              -> PackagePreparationCoordinator actor
Repositories -> GRDB DatabasePool             -> downloader / extractor / validator / storage
Viewer -> UIScrollView -> CATiledLayer -> thread-safe, bounded TileProvider cache
```

`AppEnvironment` is the composition root. Launch opens and migrates the store off the main actor,
runs disk/DB recovery before exposing the UI, then starts automatic preparation. SwiftUI never
imports GRDB. UIKit is confined to the native tiled viewer because `UIScrollView` and
`CATiledLayer` provide viewport-aware drawing and background tile callbacks.

The code uses Swift 6 complete concurrency checking with Main Actor default isolation. Blocking
download writes, extraction, validation, and launch file work run outside the main actor. One
coordinator actor owns package transitions, per-project single-flight tasks, retry scheduling,
and a concurrency semaphore capped at two pipelines.

## GRDB schema

- `project`: id, display name, package URL, stable sort order.
- `package`: state, relative archive/extraction/descriptor/tile paths, DZI dimensions and format,
  progress, failure reason, retry count/schedule, and attempt/success timestamps.
- `marker`: id, project foreign key, normalized `x/y`, creation timestamp.
- `appState`: singleton containing the last selected project.

Foreign keys are enabled; project deletion cascades package/marker data and nulls selection.
Marker coordinates and download progress have database checks. The package readiness set consists
of all local paths plus all DZI metadata columns. It is written atomically, cleared together on
demotion, and exposed only through a complete-or-absent `ReadyPackage` read model.

Only container-relative package paths are persisted. Resolution rejects absolute and escaping
paths. The database remains backed up because markers are user data; the re-downloadable
`Packages` directory is excluded from backup but stays in Application Support so iOS cache
eviction cannot break the offline promise.

## Package state model

```text
notPrepared -> queued -> downloading -> downloaded -> extracting -> ready
                         |                            |
                         +---------- failed <--------+

ready --missing/corrupt local files--> downloaded (archive exists) or queued
```

Offline is a condition, not a failed attempt. Work needing a download parks in `queued` without
incrementing retry history; an existing archive still extracts offline. Launch recovery demotes
interrupted downloads/extractions to the nearest safe checkpoint, wipes staging, verifies ready
files, makes failed work due, and removes unreferenced package artifacts. Markers are never part of
package replacement or recovery.

## Automatic preparation, retry, and idempotency

Preparation starts on launch and is retriggered by project selection, foreground entry,
connectivity restoration, a coalesced due timer, viewer entry, and optional manual Retry.

Each project is single-flight: its task is registered before the coordinator actor can suspend.
All work uses unique staging paths. A download is checked for non-empty/complete length, promoted,
and only then referenced by the database. Extraction is validated in staging; every expected,
non-empty DZI tile is checked before the directory is atomically promoted and marked ready.

Failures use equal-jitter exponential backoff (base 3 seconds, cap 5 minutes), persisted retry
facts, and a six-attempt automatic session cap. Selection, connectivity restoration, and manual
retry reset the session cap; manual retry also resets persisted scheduling. Real duplicate
reachability notifications are suppressed so they cannot reset the cap repeatedly. Progress is a
structured async callback and is persisted only after a 5% or 500 ms threshold.

Repeated preparation cannot create duplicate downloads or extractions. Stale partial downloads
are deleted before restart; a kept archive resumes at extraction; corrupt archives are removed so
the next attempt downloads again; a broken ready row is repaired before the viewer receives paths.

## DZI parsing and validation

The locator recursively finds the `.dzi` file and discovers the tile directory instead of
hardcoding `floorplan_files`. `XMLParser` reads width, height, tile size, overlap, and format. The
non-standard `dzi.json` is only a diagnostic cross-check.

The supplied pyramids are rebased VIPS pyramids (`0...4`), not canonical Deep Zoom numbering up to
level 12. The highest integer folder found on disk is treated as full resolution. This also works
for canonical pyramids. Validation requires contiguous level directories and every tile implied by
the descriptor/grid; this prevents sparse packages from producing silent white holes.

## Native tile rendering and performance

`UIScrollView` owns pan, pinch, fit, centering, and double-tap zoom. Its image-sized content view is
backed by `CATiledLayer`. Each draw callback maps the Core Graphics CTM to a DZI level, enumerates
only tiles intersecting that callback rect, and reads those files lazily. `preview.jpg` is not used.

`CATiledLayer` draws concurrently off-main. `TileProvider` therefore uses immutable inputs and a
thread-safe `NSCache`, bounded by both tile count and decoded-byte cost (48 MB). Tile draw logging is
disabled by default even in DEBUG; set `FLOORPLAN_DEBUG_TILES=1` when diagnosing LOD selection.
`levelsOfDetailBias = 2` provides over-zoom headroom without loading the whole floorplan bitmap.

## Markers

A UIKit recognizer reports taps in full-resolution image space. The resolver selects the nearest
marker within a screen-constant hit radius, deselects appropriately, or converts a placement to
normalized coordinates. GRDB stores values in `0...1`, so markers survive zoom, pan, screen-size
changes, switching projects, relaunch, and offline use. SwiftUI renders constant-size pins from the
live viewport transform; marker insertion and deletion never touch package state.

## Tests

The suite is deterministic and network-free: in-memory GRDB, temporary storage, injected clock and
path monitor, scriptable seams, `file://` download fixtures, and generated archives.

| Assignment area | Representative coverage |
|---|---|
| State transitions | `happyPathWalksToReadyWithArtifactsAndReadinessSet` |
| Idempotency | `repeatedPrepareWhileInFlightStartsExactlyOneDownload` |
| Retry | `sessionCapStopsAutoRetriesAndExplicitTriggersResetIt` |
| Partial/relaunch recovery | `interruptedDownloadingDemotesToQueued` |
| Missing ready files | `brokenReadyDemotesByArchivePresence` |
| DZI parsing | `parsesRealSampleDescriptor` |
| Tile geometry | `rebasedPyramidMatchesGroundTruth` |
| Marker conversion | `placedMarkerRoundTripsThroughViewport` |
| Marker persistence | `insertRoundTripsThroughFreshFetch` |
| Offline behavior | `offlineWithArchiveStillExtractsToReady` |

The end-to-end integration test uses the real downloader, extractor, validator, storage, GRDB, and
coordinator over a generated `file://` archive. The suite intentionally favors state-machine and
ground-truth tests over a combinatorial coverage target.

## Known limitations

- No background `URLSession`; a killed transfer restarts from its recoverable queued state.
- No resume data; partial archives are intentionally discarded to keep integrity rules simple.
- SWCompression currently decodes these small (~600 KB) gzip archives in memory.
- Reachability is a scheduling hint, never treated as proof that a request will succeed.
- The sample JPEG source itself has limited detail when magnified beyond native resolution.
- User-facing text is English-only; there is no localization catalog yet.

## Improvements with more time

- Background downloads with validated resume data and OS task restoration.
- Streaming gzip/tar extraction for large production packages.
- Per-tile checksum or server manifest validation.
- Batched marker layers for thousands of markers and performance signposts/metrics.
- Optional `preview.jpg` underlay while the first tile callbacks complete.
- CI across supported iPhone/iPad OS versions, UI accessibility tests, and visual snapshots.
