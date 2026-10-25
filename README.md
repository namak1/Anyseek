# Anyseek

**Every file. Instantly.** A native macOS file search application, independently implemented with Everything as the reference for search behaviour and a compact table interface.

## Current version: 0.1.0 — first functional foundation

Requires macOS 13 or later. No account, server, or Spotlight index is needed. Choose **Add Folders** on first launch to select your search locations.

- Search as you type; sortable Name, Path, Size, Date Modified columns.
- File type filters, case/path matching, quoted phrases, AND (spaces), OR (`|`), exclusions (`!`), wildcards and `regex:`.
- `ext:pdf;docx`, `file:`, `folder:`, `path:`, `size:>100mb`, `size:<1gb`, `dm:today`.
- Open results, reveal in Finder, copy paths, and CSV export.
- Saved search bookmarks and configurable indexed folders.
- Persistent local index in `~/Library/Application Support/Anyseek/index.json`.
- FSEvents monitoring triggers debounced background rescans. Cached results load at startup, then refresh.
- Inaccessible paths and index-save failures appear in the status bar.

## Build and run

Install Xcode Command Line Tools, then:

```sh
swift test
bash scripts/build-app.sh
open dist/Anyseek.app
```

GitHub Actions builds an Apple Silicon app ZIP on macOS. Open the repository's Actions tab, select a successful **macOS Build** run, and download its artifact. Builds are ad-hoc signed, not Apple-notarized; macOS may require an explicit Open action. No notarization credentials are included.

## Scope and parity

This is the first implementation, **not yet an indistinguishable or feature-complete Everything replacement**. Current indexing enumerates selected folders and stores JSON; change events rescan selected roots rather than updating individual records. Million-file performance is not yet benchmarked. Network and disconnected-drive handling need further work; unavailable roots are removed from the active results on refresh. File contents are not searched.

Next milestones:

1. Transactional database and incremental per-path updates, cancellation and indexing progress.
2. Everything 1.4 reference inventory, matching menus/dialogs/settings and side-by-side acceptance checks.
3. Full query grammar (grouping, ranges and additional functions), preview, multi-selection file actions and history.
4. Global shortcut, login/background behaviour, external-volume lifecycle and recovery tests.
5. Performance benchmarks, Intel build, app icon, signed/notarized distribution.

macOS permissions constrain coverage. The app does not bypass access restrictions; add locations explicitly and review Privacy & Security settings if needed. There is no claim of affiliation with voidtools.
