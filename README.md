# Anyseek

**Every file. Instantly.** Native, offline macOS file search with an independent index and an Everything-style compact results table.

## Download and install

Requires **macOS 13 or later**. The ZIP contains a **universal application for Apple Silicon and Intel**.

1. Open [GitHub Actions](https://github.com/namak1/Anyseek/actions), choose a successful **macOS Build**, and download **Anyseek-macos-universal** under Artifacts.
2. Extract the artifact, then `Anyseek-macos.zip`. Drag **Anyseek.app** into Applications.
3. Launch Anyseek and choose **Add Folders**. Select your home folder or the drives you want indexed.
4. Type a filename or search expression. Indexing runs in the background; subsequent launches load the saved catalogue.

The app is ad-hoc signed, not Apple-notarized. If macOS blocks it, use **System Settings → Privacy & Security → Open Anyway** after reviewing the download source. Some protected folders require permission in Privacy & Security; the app reports inaccessible locations rather than bypassing restrictions.

## Working features in 0.2.0

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

Million-file latency and memory usage have not been benchmarked. Search scans an in-memory snapshot; SQLite provides durable storage. The native UI, global shortcut, and login integration should also be checked on the target Mac. No affiliation with voidtools is implied.
