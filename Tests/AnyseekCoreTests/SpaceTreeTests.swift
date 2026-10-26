import XCTest
@testable import AnyseekCore
final class SpaceTreeTests: XCTestCase {
    private func file(_ path: String, _ bytes: Int64, folder: Bool = false) -> FileRecord {
        FileRecord(path: path, isDirectory: folder, size: bytes, modified: .distantPast)
    }
    func testHierarchyAndLiveReplacements() throws {
        let files = [file("/disk/a/large", 80),file("/disk/a/small",20),file("/disk/b",50),file("/disk/a",999,folder:true),file("/disk2/foreign",1000)]
        let tree = try SpaceTree.build(files: files, root: "/disk", removed: ["/disk/a/small"], updated: [file("/disk/b",70)])
        XCTAssertEqual(tree.nodes[0].bytes,150)
        XCTAssertEqual(tree.nodes[tree.paths["/disk/a"]!].bytes,80)
        XCTAssertNil(tree.paths["/disk/a/small"]); XCTAssertNil(tree.paths["/disk2/foreign"])
        let replaced = try SpaceTree.build(files: files, root: "/disk", removed: ["/disk/a"], updated: [file("/disk/a/new",5)])
        XCTAssertEqual(replaced.nodes[0].bytes,55)
    }
    func testGreedyPartitionAreaAndDeterminism() throws {
        let files = [file("/disk/a",60),file("/disk/b",30),file("/disk/c",10)]
        let tree = try SpaceTree.build(files: files, root: "/disk", removed: [], updated: [])
        let rect = CGRect(x:0,y:0,width:1000,height:800)
        let tiles = tree.layout(root:0,rect:rect,density:6)
        XCTAssertEqual(tiles.count,3)
        for tile in tiles {
            XCTAssertEqual(tile.rect.width * tile.rect.height / 800000, tile.bytes / 100, accuracy:0.00001)
            XCTAssertTrue(rect.contains(tile.rect))
        }
        for i in tiles.indices { for j in tiles.indices where i < j { XCTAssertTrue(tiles[i].rect.intersection(tiles[j].rect).isEmpty) } }
        XCTAssertEqual(tiles.map(\.rect),tree.layout(root:0,rect:rect,density:6).map(\.rect))
    }
    func testZeroAndTinyItems() throws {
        let empty = try SpaceTree.build(files: [file("/disk/zero",0)], root:"/disk",removed:[],updated:[])
        XCTAssertTrue(empty.layout(root:0,rect:CGRect(x:0,y:0,width:100,height:100)).isEmpty)
        let files = (0..<10000).map { file("/disk/\($0)",1) }
        let tree = try SpaceTree.build(files:files,root:"/disk",removed:[],updated:[])
        let tiles = tree.layout(root:0,rect:CGRect(x:0,y:0,width:500,height:300))
        XCTAssertLessThan(tiles.count,1000)
        XCTAssertEqual(tiles.reduce(0) { $0 + $1.bytes },10000)
    }
    func testMainDriveDoesNotCountRemovableDriveTwice() throws {
        let tree = try SpaceTree.build(files:[file("/Users/a",10),file("/Volumes/USB/a",100)],root:"/",removed:[],updated:[])
        XCTAssertEqual(tree.nodes[0].bytes,10)
    }
}
