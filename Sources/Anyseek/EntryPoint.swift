import Foundation
import AppKit
import AnyseekCore

@main enum EntryPoint {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--self-test") {
            do { try await integrationTest(); print("PASS: indexing, changes, rename, delete, exclusions, offline catalogue, persistence, cancellation"); exit(0) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        AnyseekApp.main()
    }
    static func integrationTest() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("Anyseek-test-" + UUID().uuidString)
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
        try require(result.files.contains { $0.path == original.path }, "Initial scan missing file")
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
            try Task.checkCancellation()
            return try await engine.scan(scopes: [root.path], roots: [root.path], excluded: [], progress: { _ in })
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw NSError(domain: "Anyseek.SelfTest", code: 1) } catch is CancellationError { }
        result = try await engine.scan(scopes: [], roots: [], excluded: [], progress: { _ in })
        try require(result.files.isEmpty, "Removed root remains indexed")
    }
}
