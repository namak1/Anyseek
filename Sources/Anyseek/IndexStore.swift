import Foundation
import AppKit
import CoreServices
import AnyseekCore

@MainActor final class IndexStore: ObservableObject {
    @Published var files: [FileRecord] = []
    @Published var revision = 0
    @Published var status = "Choose folders to index"
    @Published var indexing = false
    @Published var roots: [String] = UserDefaults.standard.stringArray(forKey: "roots") ?? []
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var rescanRequested = false
    private let cache: URL
    init() {
        cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Anyseek/index.json")
        Task { await load() }
    }
    private func load() async {
        let location = cache
        let records = await Task.detached { () -> [FileRecord] in
            guard let data = try? Data(contentsOf: location) else { return [] }
            return (try? JSONDecoder().decode([FileRecord].self, from: data)) ?? []
        }.value
        files = records; revision += 1
        if !roots.isEmpty { watch(); rebuild() }
    }
    func chooseFolders() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        roots = Array(Set(roots + panel.urls.map(\.path))).sorted()
        UserDefaults.standard.set(roots, forKey: "roots"); watch(); rebuild()
    }
    func removeRoot(_ root: String) {
        roots.removeAll { $0 == root }; UserDefaults.standard.set(roots, forKey: "roots"); watch(); rebuild()
    }
    func rebuild() {
        guard !indexing else { rescanRequested = true; return }
        indexing = true; status = "Indexing…"
        let paths = roots, location = cache
        Task {
            let result = await Task.detached(priority: .utility) { () -> ([FileRecord], Int, Bool) in
                let fm = FileManager.default
                let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
                var records: [String: FileRecord] = [:]; var errors = 0
                for path in paths {
                    let root = URL(fileURLWithPath: path)
                    guard fm.isReadableFile(atPath: path) else { errors += 1; continue }
                    if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in errors += 1; return true }) {
                        for case let url as URL in enumerator {
                            if url.path == location.deletingLastPathComponent().path { enumerator.skipDescendants(); continue }
                            do {
                                let values = try url.resourceValues(forKeys: Set(keys))
                                records[url.path] = FileRecord(path: url.path, isDirectory: values.isDirectory ?? false, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast)
                            } catch { errors += 1 }
                        }
                    }
                }
                let sorted = records.values.sorted { $0.path < $1.path }
                var saved = true
                do {
                    try fm.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let data = try JSONEncoder().encode(sorted)
                    if (try? Data(contentsOf: location)) != data { try data.write(to: location, options: .atomic) }
                } catch { saved = false }
                return (sorted, errors, saved)
            }.value
            files = result.0; revision += 1; indexing = false
            status = "\(files.count.formatted()) indexed" + (result.1 > 0 ? " · \(result.1) inaccessible locations" : "") + (result.2 ? "" : " · Could not save index")
            if rescanRequested { rescanRequested = false; rebuild() }
        }
    }
    private func watch() {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
        guard !roots.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            let owner = Unmanaged<IndexStore>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in owner.scheduleRescan() }
        }, &context, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2, FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot))
        if let stream { FSEventStreamSetDispatchQueue(stream, .main); if !FSEventStreamStart(stream) { status = "Change monitoring unavailable; use Refresh" } }
    }
    private func scheduleRescan() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in Task { @MainActor in self?.rebuild() } }
        pending = item; DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }
}
