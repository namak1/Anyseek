import Foundation

public struct SpaceNode {
    public let path: String
    public let name: String
    public var bytes: Double
    public var children: [Int]
    public let isDirectory: Bool
    public let modified: Date
}
public struct SpaceTile {
    public let node: Int?
    public let parent: Int
    public let rect: CGRect
    public let depth: Int
    public let bytes: Double
}
public struct SpaceTree {
    public let nodes: [SpaceNode]
    public let paths: [String: Int]
    public static func build(files: [FileRecord], root: String, removed: Set<String>, updated: [FileRecord]) throws -> SpaceTree {
        var nodes = [SpaceNode(path: root, name: root == "/" ? "Macintosh HD" : (root as NSString).lastPathComponent, bytes: 0, children: [], isDirectory: true, modified: .distantPast)]
        var paths = [root: 0]
        let changed = Set(updated.map(\.path)), scopes = PathScope.compact(Array(removed))
        func ensure(_ path: String) -> Int {
            if let id = paths[path] { return id }
            let parent = (path as NSString).deletingLastPathComponent
            let parentID = ensure(parent)
            let id = nodes.count
            nodes.append(SpaceNode(path: path, name: (path as NSString).lastPathComponent, bytes: 0, children: [], isDirectory: true, modified: .distantPast))
            paths[path] = id; nodes[parentID].children.append(id)
            return id
        }
        func insert(_ file: FileRecord) {
            guard PathScope.contains(root, file.path), file.path != root, !PathScope.isTrash(file.path) else { return }
            if root == "/" && file.path.hasPrefix("/Volumes/") { return }
            let parent = ensure((file.path as NSString).deletingLastPathComponent)
            if let existing = paths[file.path] {
                if !file.isDirectory { nodes[existing].bytes = Double(max(0, file.size)) }
                return
            }
            let id = nodes.count; paths[file.path] = id
            nodes.append(SpaceNode(path: file.path, name: file.name, bytes: file.isDirectory ? 0 : Double(max(0, file.size)), children: [], isDirectory: file.isDirectory, modified: file.modified))
            nodes[parent].children.append(id)
        }
        for (i,file) in files.enumerated() {
            if i & 1023 == 0 { try Task.checkCancellation() }
            if !changed.contains(file.path) && !scopes.contains(where: { PathScope.contains($0, file.path) }) { insert(file) }
        }
        for file in updated { try Task.checkCancellation(); insert(file) }
        // Parents are always created before their children, even for unsorted snapshots.
        for i in nodes.indices.reversed() {
            if i & 1023 == 0 { try Task.checkCancellation() }
            if nodes[i].isDirectory {
                nodes[i].bytes = nodes[i].children.reduce(0) { $0 + nodes[$1].bytes }
                let ordered = nodes[i].children.sorted { a,b in nodes[a].bytes == nodes[b].bytes ? nodes[a].path < nodes[b].path : nodes[a].bytes > nodes[b].bytes }
                nodes[i].children = ordered
            }
        }
        return SpaceTree(nodes: nodes, paths: paths)
    }

    /// Swift port of SpaceMonger 1.4's BuildFolderLayout/SizeFolders, by
    /// Sean Werkema. MIT license: ThirdParty/SpaceMonger-LICENSE.txt.
    /// Descending sizes are greedily assigned to the lighter of two groups.
    public func layout(root: Int, rect: CGRect, density: Int = 3, bias: Int = 0) -> [SpaceTile] {
        guard nodes.indices.contains(root), rect.width > 0, rect.height > 0 else { return [] }
        let thresholds: [(CGFloat,CGFloat)] = [(96,64),(64,48),(48,32),(32,24),(24,16),(16,12),(8,6)]
        let minimum = thresholds[min(6,max(0,density))]
        var tiles: [SpaceTile] = []
        func folder(_ id: Int, _ rect: CGRect, _ depth: Int) {
            guard depth < 128 else { return }
            partition(nodes[id].children.filter { nodes[$0].bytes > 0 }, rect, id, depth)
        }
        func partition(_ ids: [Int], _ rect: CGRect, _ parent: Int, _ depth: Int) {
            guard !ids.isEmpty, rect.width > 0, rect.height > 0 else { return }
            if ids.count == 1 {
                let id = ids[0]
                tiles.append(SpaceTile(node: id, parent: parent, rect: rect, depth: depth, bytes: nodes[id].bytes))
                if nodes[id].isDirectory && rect.width > minimum.0 && rect.height > minimum.1 + 15 {
                    folder(id, CGRect(x: rect.minX + 3, y: rect.minY + 15, width: rect.width - 6, height: rect.height - 18), depth + 1)
                }
                return
            }
            var a: [Int] = [], b: [Int] = [], sa = 0.0, sb = 0.0
            for id in ids {
                if sa <= sb { a.append(id); sa += nodes[id].bytes }
                else { b.append(id); sb += nodes[id].bytes }
            }
            guard sa + sb > 0 else { return }
            if rect.width <= minimum.0 || rect.height <= minimum.1 || tiles.count > 20000 {
                tiles.append(SpaceTile(node: nil, parent: parent, rect: rect, depth: depth, bytes: sa + sb)); return
            }
            let horizontal = rect.width * CGFloat(8 + max(0,bias)) > rect.height * CGFloat(8 + max(0,-bias))
            let fraction = CGFloat(sa / (sa + sb))
            if horizontal {
                let width = rect.width * fraction
                partition(a, CGRect(x: rect.minX,y: rect.minY,width: width,height: rect.height),parent,depth)
                partition(b, CGRect(x: rect.minX + width,y: rect.minY,width: rect.width - width,height: rect.height),parent,depth)
            } else {
                let height = rect.height * fraction
                partition(a, CGRect(x: rect.minX,y: rect.minY,width: rect.width,height: height),parent,depth)
                partition(b, CGRect(x: rect.minX,y: rect.minY + height,width: rect.width,height: rect.height - height),parent,depth)
            }
        }
        folder(root,rect,0)
        return tiles
    }
}
