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
    init(cache: URL) { self.cache = URL(fileURLWithPath: PathScope.canonical(cache.path)) }
    private func db() throws -> IndexDatabase {
        if let database { return database }
        let opened = try IndexDatabase(url: cache.appendingPathComponent("index.sqlite")); database = opened; return opened
    }
    func load() throws -> [FileRecord] { try db().load() }
    func persistLive(removed: [String], updated: [FileRecord]) throws {
        try db().replace(scopes: removed, records: updated)
    }
    func scan(scopes: [String], roots: [String], excluded: [String], progress: @escaping @Sendable (Int) -> Void, snapshot: (@Sendable ([FileRecord]) -> Void)? = nil) throws -> ScanResult {
        let fm = FileManager.default
        let old = try db().load()
        var issues: [String] = []; var collected: [String: FileRecord] = [:]; var completed: [String] = []
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        func excludedPath(_ path: String) -> Bool { PathScope.isTrash(path) || PathScope.contains(cache.path, path) || excluded.contains { PathScope.contains($0, path) } }
        var lastSnapshot = Date.distantPast
        func record(_ url: URL) throws {
            let values = try url.resourceValues(forKeys: keys)
            collected[url.path] = FileRecord(path: url.path, isDirectory: values.isDirectory ?? false, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast)
            if collected.count % 2000 == 0 {
                progress(collected.count)
                if Date().timeIntervalSince(lastSnapshot) > 5 { lastSnapshot = Date(); snapshot?(Array(collected.values)) }
            }
        }
        for path in (scopes.contains("/") ? ["/"] : []) + PathScope.compact(scopes.filter { $0 != "/" }) {
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
                        if path == "/" && (PathScope.contains("/Volumes", item.path) || PathScope.contains("/System/Volumes", item.path) || PathScope.contains("/dev", item.path)) { iterator.skipDescendants(); continue }
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
        if completed.contains("/") {
            for item in old where item.path.hasPrefix("/Volumes/") && roots.contains(where: { $0 != "/" && PathScope.contains($0, item.path) && !completed.contains($0) }) { collected[item.path] = item }
        }
        let removed = old.filter { item in !roots.contains(where: { PathScope.contains($0, item.path) }) || excludedPath(item.path) }.map(\.path)
        try db().replace(scopes: PathScope.compact(completed + removed), records: Array(collected.values))
        return ScanResult(files: try db().load(), issues: Array(issues.prefix(200)))
    }
}

@MainActor final class IndexStore: ObservableObject {
    @Published var files: [FileRecord] = []
    @Published var revision = 0
    @Published var liveRevision = 0
    private(set) var liveRemoved = Set<String>()
    private(set) var liveUpdated: [String: FileRecord] = [:]
    @Published var status = "Loading index…"
    @Published var indexing = false
    @Published var issues: [String] = []
    @Published var roots = UserDefaults.standard.stringArray(forKey: "roots") ?? []
    @Published var excluded = UserDefaults.standard.stringArray(forKey: "excluded") ?? []
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var livePending: DispatchWorkItem?
    private var livePaths = Set<String>()
    private var liveRecursive = Set<String>()
    private var queued = Set<String>()
    private var job: Task<Void, Never>?
    private var paused = false
    private var cache: URL
    private let engine: IndexEngine
    private let automaticVolumes: Bool
    private var volumeObservers: [NSObjectProtocol] = []
    init(cacheURL: URL? = nil, selectedRoots: [String]? = nil, benchmarkFiles: [FileRecord]? = nil) {
        automaticVolumes = selectedRoots == nil
        cache = cacheURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Anyseek")
        cache = URL(fileURLWithPath: PathScope.canonical(cache.path))
        engine = IndexEngine(cache: cache)
        if let selectedRoots { roots = selectedRoots } else { roots = detectedVolumes() }
        roots = Array(Set(roots.map { PathScope.canonical($0) })).sorted()
        excluded = PathScope.compact(excluded.map { PathScope.canonical($0) })
        if let benchmarkFiles { files = benchmarkFiles; revision = 1; status = "Performance fixture"; return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didWakeNotification] {
            volumeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor [weak self] in self?.refreshVolumes(); self?.watch(); self?.rebuild() } })
        }
        Task {
            do { files = try await engine.load(); revision += 1 } catch { issues = [error.localizedDescription] }
            watch()
            if roots.isEmpty { status = "Add folders to start searching" } else { rebuild() }
        }
    }
    private func detectedVolumes() -> [String] {
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsBrowsableKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let paths = volumes.compactMap { url -> String? in
            let path = url.path
            guard path.hasPrefix("/Volumes/"), !path.hasPrefix("/Volumes/."),
                  let info = try? url.resourceValues(forKeys: Set(keys)), info.volumeIsLocal != false else { return nil }
            return PathScope.canonical(path)
        }
        return ["/"] + Array(Set(paths)).sorted()
    }
    private func refreshVolumes() {
        guard automaticVolumes else { return }
        roots = detectedVolumes()
        // Hide disconnected volumes immediately; the next scan reconciles storage.
        files.removeAll { file in file.path.hasPrefix("/Volumes/") && !roots.dropFirst().contains(where: { PathScope.contains($0, file.path) }) }
        revision += 1
    }
    /// Publish immediately; persistence must never wait on or block the UI.
    func containsLive(_ path: String) -> Bool {
        if liveUpdated[path] != nil { return true }
        if liveRemoved.contains(where: { PathScope.contains($0, path) }) { return false }
        return files.contains { $0.path == path }
    }
    func applyLive(removed: [String], updated: [FileRecord] = []) {
        for path in removed {
            liveRemoved.insert(path)
            liveUpdated = liveUpdated.filter { !PathScope.contains(path, $0.key) }
        }
        for file in updated { liveUpdated[file.path] = file }
        liveRevision += 1
        Task { do { try await engine.persistLive(removed: removed, updated: updated) } catch { issues.append(error.localizedDescription) } }
    }
    private func inspectLive(_ paths: [String], recursive: Set<String>) {
        let selectedRoots = roots, exclusions = excluded, cachePath = cache.path
        Task {
            let patch = await Task.detached(priority: .userInitiated) { () -> ([String], [FileRecord]) in
                let fm = FileManager.default
                var removed: [String] = [], records: [FileRecord] = []
                let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
                func read(_ path: String) {
                    guard !PathScope.isTrash(path), !PathScope.contains(cachePath, path), !exclusions.contains(where: { PathScope.contains($0, path) }) else { return }
                    if let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys) {
                        records.append(FileRecord(path: path, isDirectory: v.isDirectory ?? false, size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate ?? .distantPast))
                    }
                }
                for path in Set(paths) {
                    guard selectedRoots.contains(where: { PathScope.contains($0, path) }) else { continue }
                    if !fm.fileExists(atPath: path) {
                        // Only infer deletion when the parent remains accessible.
                        if fm.isReadableFile(atPath: (path as NSString).deletingLastPathComponent) { removed.append(path) }
                        continue
                    }
                    read(path)
                    if recursive.contains(path), let iterator = fm.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: Array(keys), options: []) {
                        for case let item as URL in iterator {
                            if exclusions.contains(where: { PathScope.contains($0, item.path) }) || PathScope.contains(cachePath, item.path) { iterator.skipDescendants(); continue }
                            read(item.path)
                        }
                    }
                }
                return (removed, records)
            }.value
            if !patch.0.isEmpty || !patch.1.isEmpty { applyLive(removed: patch.0, updated: patch.1) }
        }
    }
    func shutdown() {
        job?.cancel(); pending?.cancel(); livePending?.cancel()
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
        for observer in volumeObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        volumeObservers.removeAll()
    }
    func chooseFolders(exclude: Bool = false) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = exclude ? "Exclude" : "Index"
        guard panel.runModal() == .OK else { return }
        if exclude { excluded = PathScope.compact(excluded + panel.urls.map { PathScope.canonical($0.path) }); UserDefaults.standard.set(excluded, forKey: "excluded") }
        else { roots = PathScope.compact(roots + panel.urls.map { PathScope.canonical($0.path) }); UserDefaults.standard.set(roots, forKey: "roots") }
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
                let initiallyEmpty = files.isEmpty
                let result = try await engine.scan(scopes: selectedRoots.isEmpty ? [] : scopes, roots: selectedRoots, excluded: exclusions, progress: { [weak self] count in
                    Task { @MainActor [weak self] in if self?.indexing == true { self?.status = "Indexing… \(count.formatted()) objects" } }
                }, snapshot: { [weak self] partial in
                    guard initiallyEmpty else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.indexing else { return }
                        self.files = partial; self.revision += 1
                    }
                })
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
            let raw = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as! [String]
            let paths = raw.map { path -> String in
                let prefix = "/System/Volumes/Data"
                return path.hasPrefix(prefix + "/") ? String(path.dropFirst(prefix.count)) : path
            }
            let droppedMask = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
            let full = (0..<count).contains { flags[$0] & droppedMask != 0 }
            let recursive = Set((0..<count).filter { flags[$0] & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 && flags[$0] & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed) != 0 }.map { paths[$0] })
            let visible = (0..<count).filter { i in
                let dir = flags[i] & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
                let structural = flags[i] & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed) != 0
                return !dir || structural || full
            }.map { paths[$0] }
            Task { @MainActor in owner.changed(visible, full: full, recursive: recursive) }
        }, &context, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents))
        if let stream { FSEventStreamSetDispatchQueue(stream, .main); if !FSEventStreamStart(stream) { issues.append("Change monitoring unavailable. Use Refresh.") } }
    }
    private func changed(_ paths: [String], full: Bool, recursive: Set<String>) {
        let relevant = paths.filter { path in !PathScope.isTrash(path) && !PathScope.contains(cache.path, path) && !excluded.contains(where: { PathScope.contains($0, path) }) }
        guard !relevant.isEmpty else { return }
        livePaths.formUnion(relevant); liveRecursive.formUnion(recursive)
        if livePending == nil {
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let paths = Array(self.livePaths), directories = self.liveRecursive
                self.livePaths.removeAll(); self.liveRecursive.removeAll(); self.livePending = nil
                self.inspectLive(paths, recursive: directories)
            }
            livePending = item; DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
        }
        if full { queued.formUnion(roots) }
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in Task { @MainActor in if self?.indexing == false && self?.paused == false { self?.launch() } } }
        pending = item; DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }
}
