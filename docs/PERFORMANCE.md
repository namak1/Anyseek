# Search and sorting architecture

Anyseek keeps one immutable metadata snapshot and represents results with integer row references. The native NSTableView asks for visible rows; it does not create a view for each indexed file.

- Each drive-wide name/path/size/date order is built lazily and reused across queries.
- Size and date use eight-pass radix sorting; equal values use deterministic path ordering.
- Reversing a prepared result changes its addressing direction, without copying or re-sorting its rows.
- A query computes a membership mask and selects rows from an existing order. It does not sort the matched records again.
- Live filesystem changes mask stale base entries and merge replacement/additional records into the ordered results. Base sort orders remain reusable.
- Sort and filter loops check cancellation. The UI does not queue speculative sorting ahead of interactive work.
- Filename matching uses an allocation-free ASCII path where possible, with Foundation matching for Unicode names and queries.
- Selection restoration uses binary lookup for unchanged records and falls back to a background path scan after metadata changes. File-type icons are cached, avoiding filesystem icon lookups during scrolling.

## Reproducible checks

`swift test` checks sorting against reference orders, ties, Unicode search, cancellation, immutable result snapshots, deletions and replacements, plus the existing query/database suite.

`swift test -c release --filter ResultIndexTests` measures one million synthetic file records: first size sort, cached reversal, filename search, and live update publication. Use release measurements for performance; debug Swift code is substantially slower.

The packaged application also supports `--ui-performance-test` for CI. It loads one million synthetic records into the real search window, changes native table sort descriptors, and measures until the updated table has been laid out and displayed. Fixture construction and initial disk indexing are excluded. This is separate from the four-file screenshot smoke test.

## Limits

These measurements are not a comparison against Everything on matching hardware and data. Real drive performance depends on file counts, filenames, available memory, disk activity, and permission checks. Initial scanning still enumerates accessible directories; restarting loads SQLite and reconciles the disk. Sort indexes are currently in-memory and rebuilt for a new base snapshot. Name/path ordering is comparison-based, and very large groups of equal numeric values require path comparisons. New queries and live overlay updates still perform linear passes over the index. Content search reads files and has different latency from filename search. Memory usage and long-running event storms need separate profiling.

## October 27 interactive-path changes

Research: [Swift EverythingMac](https://github.com/alesloa/everything-mac),
[Rust/Swift EverythingMac](https://github.com/seedds/EverythingMac),
[FSearch](https://github.com/cboxdoerfer/fsearch), and
[SQLite WAL](https://www.sqlite.org/wal.html). These projects support keeping
the native UI while improving data structures; their published benchmarks
are not measurements of Anyseek.

Implemented:
- Event-driven search notifications replace the 300 ms polling interval.
  A one-element buffer coalesces updates without cancelling an active query.
- Sparse queries sort their matches instead of building a whole-drive order.
- Appending plain ASCII literal text filters previous matches. Backspace,
  changed options, Unicode, regex and advanced syntax retain full evaluation.
- Sorted base snapshots use binary path lookup for live suppression.
- SQLite subtree deletion uses indexed ranges instead of per-row substr().
- FSEvents uses NoDefer and a 16 ms collection window instead of 150 ms.

Local optimized Swift 6.0.3 / Linux x86_64 synthetic million-record comparison
(single runs, engine only, fixture construction excluded):

| Operation | Before | After |
| --- | ---: | ---: |
| Cold Report-123, name order | 309 ms | 93 ms |
| Extend to Report-1234 | 105 ms | 0.277 ms |
| Extend to Report-12345 | 101 ms | 0.023 ms |

All 26 search/database/result tests passed in the temporary core-only Linux
harness. SpaceTree/CoreGraphics, AppKit, SwiftUI and FSEvents require macOS;
the native workflow must still run before release. Cold dense sorts, broad
queries, content reads and initial indexing still have measurable latency.
These numbers do not establish zero-delay behavior on a user's Mac.
