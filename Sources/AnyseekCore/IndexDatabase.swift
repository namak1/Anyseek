import Foundation
import CSQLite
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Confined to the indexing actor. Search snapshots never share this connection.
public final class IndexDatabase {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw failure() }
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, directory INTEGER NOT NULL, size INTEGER NOT NULL, modified REAL NOT NULL)")
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
    private func failure() -> NSError { NSError(domain: "Anyseek.Index", code: 1, userInfo: [NSLocalizedDescriptionKey: db.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open index database"]) }
    private func execute(_ sql: String) throws { if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK { throw failure() } }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }
        return stmt
    }
    public func load() throws -> [FileRecord] {
        let stmt = try statement("SELECT path,directory,size,modified FROM files ORDER BY path")
        defer { sqlite3_finalize(stmt) }
        var files: [FileRecord] = []
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            guard let path = sqlite3_column_text(stmt, 0) else { throw failure() }
            files.append(FileRecord(path: String(cString: path), isDirectory: sqlite3_column_int(stmt, 1) != 0, size: sqlite3_column_int64(stmt, 2), modified: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))))
            result = sqlite3_step(stmt)
        }
        guard result == SQLITE_DONE else { throw failure() }
        return files
    }
    /// Atomically replace only rescanned subtrees, with literal path boundaries.
    public func replace(scopes: [String], records: [FileRecord]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let delete = try statement("DELETE FROM files WHERE path = ? OR substr(path,1,length(?)) = ?")
            defer { sqlite3_finalize(delete) }
            for path in scopes {
                let prefix = path == "/" ? "/" : path + "/"
                sqlite3_bind_text(delete, 1, path, -1, transient)
                sqlite3_bind_text(delete, 2, prefix, -1, transient)
                sqlite3_bind_text(delete, 3, prefix, -1, transient)
                guard sqlite3_step(delete) == SQLITE_DONE else { throw failure() }
                sqlite3_reset(delete); sqlite3_clear_bindings(delete)
            }
            let insert = try statement("INSERT OR REPLACE INTO files VALUES(?,?,?,?)")
            defer { sqlite3_finalize(insert) }
            for record in records {
                sqlite3_bind_text(insert, 1, record.path, -1, transient)
                sqlite3_bind_int(insert, 2, record.isDirectory ? 1 : 0)
                sqlite3_bind_int64(insert, 3, record.size)
                sqlite3_bind_double(insert, 4, record.modified.timeIntervalSince1970)
                guard sqlite3_step(insert) == SQLITE_DONE else { throw failure() }
                sqlite3_reset(insert); sqlite3_clear_bindings(insert)
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
}

public enum PathScope {
    public static func isTrash(_ path: String) -> Bool { path.split(separator: "/").contains { $0 == ".Trash" || $0 == ".Trashes" } }
    /// Resolve the existing ancestor with POSIX realpath. Foundation can shorten
    /// /private/var to /var while directory enumeration returns /private/var.
    public static func canonical(_ path: String) -> String {
        if let resolved = realpath(path, nil) { defer { free(resolved) }; return String(cString: resolved) }
        guard path != "/" else { return path }
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().path
        return canonical(parent) + (parent == "/" ? "" : "/") + url.lastPathComponent
    }
    private static func lexical(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() } }
            else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }
    public static func contains(_ parent: String, _ child: String) -> Bool {
        child == parent || child.hasPrefix(parent == "/" ? "/" : parent + "/")
    }
    public static func compact(_ paths: [String]) -> [String] {
        var result: [String] = []
        for path in Set(paths.map { lexical($0) }).sorted(by: { $0.count < $1.count }) {
            if !result.contains(where: { contains($0, path) }) { result.append(path) }
        }
        return result.sorted()
    }
}
