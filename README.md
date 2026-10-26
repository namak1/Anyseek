# Anyseek

**Every file. Instantly.** Native, offline macOS file search with an independent index and an Everything-style compact results table.

## Download and install

Requires **macOS 13 or later**. The ZIP contains a **universal application for Apple Silicon and Intel**.

1. Open [Downloads](https://github.com/namak1/Anyseek/releases) and download **Anyseek.dmg** from the newest release.
2. Double-click the DMG, then drag **Anyseek.app** onto the **Applications** folder beside it.
3. Eject the disk image. Open **Applications → Anyseek**.
4. The main drive and connected removable drives are indexed automatically. Results appear as the first scan progresses; subsequent launches show cached results immediately. No coding tools or Terminal commands are needed.

A ZIP containing the same ready-to-run `.app` is also available under the release assets.

The app is ad-hoc signed, not Apple-notarized. If macOS blocks it, use **System Settings → Privacy & Security → Open Anyway** after reviewing the download source. Some protected folders require permission in Privacy & Security; the app reports inaccessible locations rather than bypassing restrictions.

## Classic interface update in 0.3.0

The main window now uses a compact menu strip, full-width search field, white results table, status flags and an optional split preview pane. Options use a sidebar dialog; Advanced Search builds queries through form fields. See [the explicit parity checklist](docs/PARITY.md) for remaining differences. This is not yet an exact Everything recreation.

## Working features

- Search as you type with Name, Path, Size, Date Modified columns and reversible column sorting.
- Case, whole-word, full-path and regular-expression modes; file-type and hidden-file filters.
- Boolean AND/OR/NOT, grouped expressions, quoted phrases, wildcard matching, extension/path/size/date filters.
- SQLite index with atomic transactions; cached startup and background filesystem monitoring.
- Updates affected paths, reconciles changed subtrees, and performs a full reconciliation after wake/mount or dropped events.
- Keeps cached records for offline roots; reports access failures, with pause, refresh, and exclusion controls.
- Open files, reveal in Finder, copy paths/files, drag filenames out, rename, and move to Trash with confirmation.
- Quick Look preview, file details, CSV export, bookmarks and recent searches.
- Menu-bar access, **Control–Option–Space** global shortcut, and optional launch at login.
- UTF-8 text content search (files up to 16 MB), performed on demand.

All search/index data stays on your Mac. No account, cloud service, or Spotlight index is required. Closing the window keeps monitoring running; choose **Quit Anyseek** from its menu-bar icon to stop it.

## Search examples

| Query | Meaning |
| --- | --- |
| `flora invoice` | Both words in the filename |
| `"Flora invoice"` | Exact phrase |
| `<*.pdf \| *.docx> !draft` | PDFs or Word files excluding draft |
| `ext:jpg;jpeg;png` | Any of these extensions |
| `folder:photos` | Folders containing photos |
| `path:/Documents invoice` | Invoice names under matching paths |
| `parent:/Users/sam/Downloads` | Direct children only |
| `size:>100mb` | Files larger than 100 MiB |
| `size:1mb..10mb` | Inclusive size range |
| `dm:today`, `dm:yesterday`, `dm:7days` | Modified date filters |
| `dm:2026-01-01..2026-12-31` | Inclusive date range |
| `regex:"^Report[0-9]+"` | Regex against names (or paths with Match Path) |
| `*.txt content:"shipping notice"` | Read text inside matching files |

Spaces mean AND, `|` means OR, `!` means NOT, and `< >` group expressions. Quote regex patterns containing operator characters. Size units use powers of 1024. Invalid expressions display an error instead of silently showing incorrect matches.

### Keyboard and file actions

- **Control–Option–Space:** show/focus Anyseek globally.
- **Command–F:** focus search; **Command–R:** refresh the index.
- **Return in search:** open the selection, or the first result.
- With the results table focused: **Space** previews, **Return** opens, **Command–C** copies files, **Command–Delete** asks to move the selection to Trash.
- Right-click results for all file actions. Rename never overwrites an existing destination.

## Build and validation

Install Xcode Command Line Tools, then:

```sh
swift test
swift run Anyseek --self-test
bash scripts/build-app.sh
open dist/Anyseek.app
```

GitHub Actions runs parser/database tests, a real-filesystem lifecycle integration check, and the universal release build. Packaging verifies both CPU architectures, the property list and the ad-hoc code signature. A SHA-256 checksum accompanies the ZIP.

The index is stored at `~/Library/Application Support/Anyseek/index.sqlite`; folder preferences, bookmarks and history are in the app's user defaults. The old JSON index is no longer used; configured roots are rebuilt automatically on upgrade.

## Current limits

This is a working file-search application, **not a claim of complete or indistinguishable Everything parity**. Windows-specific features and undocumented query functions are not implemented. PDF/Word content extraction, duplicate detection, batch rename, a CLI, and network search servers are not included. Text content search is limited to UTF-8 files up to 16 MB. Symlink directories are not traversed. Disconnected entries remain searchable but cannot be opened until their volume returns. File operations use filesystem permissions and do not override them.

Search uses shared metadata, integer row references, reusable drive-wide sort orders, radix sorting for size/date, and constant-time direction reversal. The native table virtualizes rows; live changes use an overlay without invalidating base sort orders. CI exercises one million synthetic records in both optimized engine tests and the actual native table. See [performance architecture and benchmark methodology](docs/PERFORMANCE.md). These checks do not establish speed parity with Everything on your hardware. Initial disk scans, memory use, and real-drive workloads still need profiling. No affiliation with voidtools is implied.

Opening one top-level menu enables hover switching across the other menu titles, using native menu tracking. Protected locations remain subject to macOS access permissions.

## Space Manager tab (0.5)

Anyseek includes a native disk map using a Swift adaptation of SpaceMonger 1.4's greedy balanced binary treemap layout. Select a drive from Open, explore nested size rectangles, double-click folders to zoom, and use Zoom Out/Zoom Full to navigate. Hover for paths and sizes; right-click for Open, Reveal in Finder, Copy Path and confirmed Move to Trash. Setup controls density, orientation, size labels and deletion availability.

The map builds from Anyseek's saved index and live overlay on a background task. Its totals are logical sizes of indexed files, not a complete physical APFS storage report. Inaccessible/excluded files, snapshots, clones and shared blocks are not reconciled. Empty/zero-byte entries have no proportional area; small items are grouped and can be explored by zooming into their parent. Root `/` excludes removable drives under `/Volumes`; choose those separately in Open.

Original layout engineering: Sean Werkema, SpaceMonger 1.4, MIT. See [third-party license](ThirdParty/SpaceMonger-LICENSE.txt), also bundled inside the app's Resources directory. This is an integrated macOS adaptation, not an official SpaceMonger release.
