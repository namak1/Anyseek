# Search and sorting architecture

Anyseek keeps one immutable metadata snapshot and represents results with integer row references. The native NSTableView asks for visible rows; it does not create a view for each indexed file.

- Each drive-wide name/path/size/date order is built lazily and reused across queries.
- Size and date use eight-pass radix sorting; equal values use deterministic path ordering.
- Reversing a prepared result changes its addressing direction, without copying or re-sorting its rows.
- A query computes a membership mask and selects rows from an existing order. It does not sort the matched records again.
- Live filesystem changes mask stale base entries and merge replacement/additional records into the ordered results. Base sort orders remain reusable.
- Sort and filter loops check cancellation. The UI does not queue speculative sorting ahead of interactive work.
- Filename matching uses an allocation-free ASCII path where possible, with Foundation matching for Unicode names and queries.
- Selection restoration runs off the AppKit thread. File-type icons are cached, avoiding filesystem icon lookups during scrolling.

## Reproducible checks

`swift test` checks sorting against reference orders, ties, Unicode search, cancellation, immutable result snapshots, deletions and replacements, plus the existing query/database suite.

`swift test -c release --filter ResultIndexTests` measures one million synthetic file records: first size sort, cached reversal, filename search, and live update publication. Use release measurements for performance; debug Swift code is substantially slower.

The packaged application also supports `--ui-performance-test` for CI. It loads one million synthetic records into the real search window, changes native table sort descriptors, and measures until the updated table has been laid out and displayed. Fixture construction and initial disk indexing are excluded. This is separate from the four-file screenshot smoke test.

## Limits

These measurements are not a comparison against Everything on matching hardware and data. Real drive performance depends on file counts, filenames, available memory, disk activity, and permission checks. Initial scanning still enumerates accessible directories; restarting loads SQLite and reconciles the disk. Sort indexes are currently in-memory and rebuilt for a new base snapshot. Name/path ordering is comparison-based, and very large groups of equal numeric values require path comparisons. New queries and live overlay updates still perform linear passes over the index. Content search reads files and has different latency from filename search. Memory usage and long-running event storms need separate profiling.
