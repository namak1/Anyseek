import Foundation
import AppKit
import CoreServices
import AnyseekCore

struct ScanResult {
    let files: [FileRecord]
    let issues: [String]
}
actor IndexEngine {
    private var database: IndexDatabase?
    private let cache: URL
    init(cache: URL) { self.cache = cache }
    private func db() throws -> IndexDatabase {
        if let database { return database }
        let opened = try IndexDatabase(url: cache.appendingPathComponent("index.sqlite")); database = opened; return opened
    }
    func load() throws -> [FileRecord] { try db().load() }
    func scan(scopes: [String], roots: [String], excluded: [String], progress: @escaping @Sendable (Int) -> Void) throws -> ScanResult {
        let fm = FileManager.default
        let old = try db().load()
        var issues: [String] = []; var collected: [String: FileRecord] = [:]; var completed: [String] = []
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        func excludedPath(_ path: String) -> Bool { PathScope.contains(cache.path, path) || excluded.contains { PathScope.contains($0, path) } }
        func record(_ url: URL) throws {
            let values = try url.resourceValues(forKeys: keys)
            collected[url.path] = FileRecord(path: url.path, isDirectory: values.isDirectory ?? false, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast)
            if collected.count % 2000 == 0 { progress(collected.count) }
        }
        for path in PathScope.compact(scopes) {
            try Task.checkCancellation()
            // An unavailable root is retained, so unplugging a drive never erases its catalogue.
            if roots.contains(where: { PathScope.contains($0, path) && !fm.isReadableFile(atPath: $0) }) {
                issues.append("Offline or inaccessible: \(path)"); continue
            }
            if excludedPath(path) { completed.append(path); continue }
            var directory: ObjCBool = false
            if !fm.fileExists(atPath: path, isDirectory: &directory) { completed.append(path); continue }
            guard fm.isReadableFile(atPath: path) else { issues.append("Access denied: \(path)"); continue }
            let url = URL(fileURLWithPath: path)
            var failed: [String] = []
            do { try record(url) } catch { issues.append("Cannot read: \(path)"); continue }
            if directory.boolValue {
                if let iterator = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { url, error in
                    failed.append(url.path); issues.append("\(url.path): \(error.localizedDescription)"); return true
                }) {
                    for case let item as URL in iterator {
                        try Task.checkCancellation()
                        if excludedPath(item.path) { iterator.skipDescendants(); continue }
                        do {
                            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey])
                            try record(item)
                            if values.isSymbolicLink == true { iterator.skipDescendants() }
                        } catch { failed.append(item.path); issues.append("Cannot read: \(item.path)") }
                    }
                } else { failed.append(path); issues.append("Cannot enumerate: \(path)") }
            }
            // Keep old data beneath denied subdirectories instead of treating it as deleted.
            for item in old where failed.contains(where: { PathScope.contains($0, item.path) }) && !excludedPath(item.path) { collected[item.path] = item }
            completed.append(path)
        }
        try Task.checkCancellation()
        let removed = old.filter { item in !roots.contains(where: { PathScope.contains($0, item.path) }) || excludedPath(item.path) }.map(\.path)
        try db().replace(scopes: PathScope.compact(completed + removed), records: Array(collected.values))
        return ScanResult(files: try db().load(), issues: Array(issues.prefix(200)))
    }
}

@MainActor final class IndexStore: ObservableObject {
    @Published var files: [FileRecord] = []
    @Published var revision = 0
    @Published var status = "Loading index…"
    @Published var indexing = false
    @Published var issues: [String] = []
    @Published var roots = UserDefaults.standard.stringArray(forKey: "roots") ?? []
    @Published var excluded = UserDefaults.standard.stringArray(forKey: "excluded") ?? []
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var queued = Set<String>()
    private var job: Task<Void, Never>?
    private var paused = false
    private var cache: URL
    private let engine: IndexEngine
    private var volumeObservers: [NSObjectProtocol] = []
    init() {
        cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Anyseek")
        engine = IndexEngine(cache: cache)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didWakeNotification] {
            volumeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor [weak self] in self?.watch(); self?.rebuild() } })
        }
        Task {
            do { files = try await engine.load(); revision += 1 } catch { issues = [error.localizedDescription] }
            watch()
            if roots.isEmpty { status = "Add folders to start searching" } else { rebuild() }
        }
    }
    func chooseFolders(exclude: Bool = false) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = exclude ? "Exclude" : "Index"
        guard panel.runModal() == .OK else { return }
        if exclude { excluded = PathScope.compact(excluded + panel.urls.map(\.path)); UserDefaults.standard.set(excluded, forKey: "excluded") }
        else { roots = PathScope.compact(roots + panel.urls.map(\.path)); UserDefaults.standard.set(roots, forKey: "roots") }
        watch(); restart()
    }
    func removeRoot(_ root: String) { roots.removeAll { $0 == root }; UserDefaults.standard.set(roots, forKey: "roots"); watch(); restart() }
    func removeExclusion(_ path: String) { excluded.removeAll { $0 == path }; UserDefaults.standard.set(excluded, forKey: "excluded"); restart() }
    private func restart() { paused = false; job?.cancel(); queued.formUnion(roots); if roots.isEmpty { queued.insert("/") }; if !indexing { launch() } }
    func cancel() { paused = true; queued.removeAll(); pending?.cancel(); job?.cancel() }
    func rebuild() { paused = false; queued.formUnion(roots); if roots.isEmpty { queued.insert("/") }; if !indexing { launch() } }
    private func launch() {
        guard !queued.isEmpty else { return }
        let scopes = Array(queued); queued.removeAll()
        let selectedRoots = roots, exclusions = excluded
        indexing = true; status = "Indexing…"
        job = Task {
            do {
                let result = try await engine.scan(scopes: selectedRoots.isEmpty ? [] : scopes, roots: selectedRoots, excluded: exclusions) { [weak self] count in
                    Task { @MainActor [weak self] in if self?.indexing == true { self?.status = "Indexing… \(count.formatted()) objects" } }
                }
                files = result.files; issues = result.issues; revision += 1
                status = "\(files.count.formatted()) indexed" + (issues.isEmpty ? "" : " · \(issues.count) issues")
            } catch is CancellationError { status = "Indexing paused · cached results available" }
            catch { status = "Index failed"; issues = [error.localizedDescription] }
            indexing = false; job = nil
            if !paused && !queued.isEmpty { launch() }
        }
    }
    private func watch() {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
        guard !roots.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let owner = Unmanaged<IndexStore>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as! [String]
            let droppedMask = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
            let full = (0..<count).contains { flags[$0] & droppedMask != 0 }
            Task { @MainActor in owner.changed(paths, full: full) }
        }, &context, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1, FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents))
        if let stream { FSEventStreamSetDispatchQueue(stream, .main); if !FSEventStreamStart(stream) { issues.append("Change monitoring unavailable. Use Refresh.") } }
    }
    private func changed(_ paths: [String], full: Bool) {
        let relevant = paths.filter { path in !PathScope.contains(cache.path, path) && !excluded.contains(where: { PathScope.contains($0, path) }) }
        guard !relevant.isEmpty else { return }
        if full { queued.formUnion(roots) }
        else {
            for path in relevant {
                if roots.contains(path) { queued.insert(path) }
                else if roots.contains(where: { PathScope.contains($0, path) }) { queued.insert(path) }
            }
        }
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in Task { @MainActor in if self?.indexing == false && self?.paused == false { self?.launch() } } }
        pending = item; DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }
}
