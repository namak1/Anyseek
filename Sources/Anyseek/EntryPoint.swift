import Foundation
import AppKit
import AnyseekCore

@main enum EntryPoint {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--list-auto-roots") {
            let store = IndexStore()
            print(String(data: try! JSONEncoder().encode(store.roots), encoding: .utf8)!)
            store.shutdown(); exit(0)
        }
        if CommandLine.arguments.contains("--self-test") {
            do { try await integrationTest(); print("PASS: indexing, changes, rename, delete, exclusions, offline catalogue, persistence, cancellation"); exit(0) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        AnyseekApp.main()
    }
    @MainActor static func integrationTest() async throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: PathScope.canonical(fm.temporaryDirectory.path)).appendingPathComponent("Anyseek-test-" + UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("files"), cache = base.appendingPathComponent("cache")
        try fm.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let original = root.appendingPathComponent("nested/original.txt")
        try "hello".write(to: original, atomically: true, encoding: .utf8)
        let engine = IndexEngine(cache: cache)
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "Anyseek.SelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        var result = try await engine.scan(scopes: [root.path], roots: [root.path], excluded: [], progress: { _ in })
        try require(result.files.contains { $0.path == original.path }, "Initial scan missing file: \(original.path); found \(result.files.map(\.path)); issues \(result.issues)")
        let renamed = root.appendingPathComponent("nested/renamed.txt")
        try fm.moveItem(at: original, to: renamed)
        result = try await engine.scan(scopes: [original.path, renamed.path], roots: [root.path], excluded: [], progress: { _ in })
        try require(!result.files.contains { $0.path == original.path } && result.files.contains { $0.path == renamed.path }, "Rename reconciliation failed")
        try fm.removeItem(at: renamed)
        result = try await engine.scan(scopes: [renamed.path], roots: [root.path], excluded: [], progress: { _ in })
        try require(!result.files.contains { $0.path == renamed.path }, "Deleted file remains")
        try "hidden".write(to: original, atomically: true, encoding: .utf8)
        result = try await engine.scan(scopes: [root.path], roots: [root.path], excluded: [root.appendingPathComponent("nested").path], progress: { _ in })
        try require(!result.files.contains { $0.path == original.path }, "Exclusion failed")
        _ = try await engine.scan(scopes: [root.path], roots: [root.path], excluded: [], progress: { _ in })
        let offline = base.appendingPathComponent("disconnected")
        try fm.moveItem(at: root, to: offline)
        result = try await engine.scan(scopes: [root.path], roots: [root.path], excluded: [], progress: { _ in })
        try require(result.files.contains { $0.path == original.path } && !result.issues.isEmpty, "Offline catalogue lost")
        let reopened = IndexEngine(cache: cache)
        let cached = try await reopened.load()
        try require(cached == result.files, "Persistence failed")
        let cancelled = Task {
            try await Task.sleep(nanoseconds: 10_000_000)
            try Task.checkCancellation()
            return try await engine.scan(scopes: [root.path], roots: [root.path], excluded: [], progress: { _ in })
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw NSError(domain: "Anyseek.SelfTest", code: 1) } catch is CancellationError { }
        result = try await engine.scan(scopes: [], roots: [], excluded: [], progress: { _ in })
        try require(result.files.isEmpty, "Removed root remains indexed")
        // Exercise the actual FSEvents callback and debouncing, not just the scanner.
        try fm.moveItem(at: offline, to: root)
        let store = IndexStore(cacheURL: base.appendingPathComponent("watch-cache"), selectedRoots: [root.path])
        defer { store.shutdown() }
        func waitFor(_ condition: () -> Bool, _ message: String) async throws {
            for _ in 0..<150 {
                if condition() { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try require(false, message)
        }
        try await waitFor({ !store.indexing && !store.files.isEmpty }, "Watcher initial scan timed out")
        let watched = root.appendingPathComponent("watch.txt")
        try "watch".write(to: watched, atomically: true, encoding: .utf8)
        try await waitFor({ store.containsLive(watched.path) }, "FSEvents did not index created file")
        let moved = root.appendingPathComponent("watch-renamed.txt")
        try fm.moveItem(at: watched, to: moved)
        try await waitFor({ store.containsLive(moved.path) && !store.containsLive(watched.path) }, "FSEvents rename failed")
        try fm.removeItem(at: moved)
        try await waitFor({ !store.containsLive(moved.path) }, "FSEvents deletion failed")
        print("PASS: live FSEvents create/rename/delete")
        // Simulate quitting midway through a first scan, then reopening a new release.
        let partialRoot = base.appendingPathComponent("partial-files")
        let partialCache = base.appendingPathComponent("partial-cache")
        try fm.createDirectory(at: partialRoot, withIntermediateDirectories: true)
        for i in 0..<2100 { try Data([1]).write(to: partialRoot.appendingPathComponent("file-\(i)")) }
        let partialEngine = IndexEngine(cache: partialCache)
        let interrupted = Task {
            try await partialEngine.scan(scopes: [partialRoot.path], roots: [partialRoot.path], excluded: [], progress: { _ in }, snapshot: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        do { _ = try await interrupted.value; try require(false, "Expected interrupted first scan") }
        catch is CancellationError { }
        let restored = try await IndexEngine(cache: partialCache).load()
        try require(restored.count >= 2000, "Interrupted scan checkpoint lost after reopening")
        print("PASS: partial first-scan progress survives restart")
    }
}
