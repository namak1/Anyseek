import SwiftUI
import AppKit
import AnyseekCore

struct WorkspaceTabs: View {
    @State private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            SearchWindow().tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(0)
            SpaceManager().tabItem { Label("Space Manager", systemImage: "square.grid.3x3.fill") }.tag(1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .anyseekFocus)) { _ in tab = 0 }
        .onReceive(NotificationCenter.default.publisher(for: .spaceManagerTest)) { _ in tab = 1 }
    }
}
extension Notification.Name { static let spaceManagerTest = Notification.Name("anyseek.spaceManagerTest") }

struct SpaceManager: View {
    @EnvironmentObject var index: IndexStore
    @State private var root = "/"
    @State private var zoom = ""
    @State private var selected: String?
    @State private var tree: SpaceTree?
    @State private var building = false
    @State private var active = false
    @State private var message: String?
    @State private var confirmTrash = false
    @State private var showSetup = false
    @AppStorage("spaceDensity") private var density = 3
    @AppStorage("spaceBias") private var bias = 0
    @AppStorage("spaceShowSizes") private var showSizes = true
    @AppStorage("spaceAllowDelete") private var allowDelete = true
    private var current: Int { tree?.paths[zoom.isEmpty ? root : zoom] ?? 0 }
    private var selectedNode: SpaceNode? {
        guard let tree, let selected, let id = tree.paths[selected] else { return nil }
        return tree.nodes[id]
    }
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HStack {
                Text(zoom.isEmpty ? root : zoom).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                if building { ProgressView().controlSize(.small); Text("Updating map…") }
            }.font(.system(size: 12)).padding(7)
            if let tree, !tree.nodes.isEmpty, tree.nodes[current].bytes > 0 {
                SpaceMap(tree: tree, root: current, selection: $selected, density: density, bias: bias, showSizes: showSizes, open: activate, reveal: reveal, trash: { selected = $0; confirmTrash = true }, allowDelete: allowDelete)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "internaldrive").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text(building || index.indexing ? "Waiting for indexed files…" : "No indexed file sizes in this location")
                    Button("Choose Folder…", action: chooseFolder)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                if let node = selectedNode { Text("\(node.name) · \(size(node.bytes))").lineLimit(1) }
                else if let tree { Text("\(size(tree.nodes[current].bytes)) in indexed files") }
                Spacer()
                Text(index.indexing ? "Indexing · map is partial" : "Indexed file sizes · not physical APFS usage").foregroundStyle(.secondary)
            }.font(.system(size: 11)).padding(6)
        }
        .onAppear { active = true; if !index.roots.contains(root), let first = index.roots.first { root = first } }
        .onDisappear { active = false }
        .task(id: root + String(active)) { if active { await followIndex() } }
        .alert("Space Manager", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") { message = nil } } message: { Text(message ?? "") }
        .confirmationDialog("Move the selected item to Trash?", isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive, action: trash)
            Button("Cancel", role: .cancel) { }
        }
        .sheet(isPresented: $showSetup) { settings }
    }
    private var toolbar: some View {
        HStack(spacing: 10) {
            Menu("Open") {
                ForEach(index.roots, id: \.self) { path in Button(path == "/" ? "Main Drive (/)" : path) { root = path; zoom = ""; selected = nil } }
                Divider(); Button("Choose Folder…", action: chooseFolder)
            }
            Button("Reload") { index.rebuild() }
            Divider().frame(height: 18)
            Button("Zoom In") { if let node = selectedNode { activate(node.path) } }.disabled(selectedNode?.isDirectory != true)
            Button("Zoom Out", action: zoomOut).disabled(zoom.isEmpty || zoom == root)
            Button("Zoom Full") { zoom = ""; selected = nil }
            Divider().frame(height: 18)
            Button("Run or Open") { if let selected { NSWorkspace.shared.open(URL(fileURLWithPath: selected)) } }.disabled(selected == nil)
            Button("Delete") { confirmTrash = true }.disabled(selected == nil || !allowDelete || selected == root)
            Spacer()
            Button("Setup") { showSetup = true }
        }.buttonStyle(.borderless).font(.system(size: 12)).padding(8).background(Color(nsColor: .controlBackgroundColor))
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Space Manager Setup").font(.headline)
            Picker("Map density", selection: $density) { ForEach(0..<7) { Text(["Very sparse","Sparse","Spacious","Normal","Dense","Very dense","Maximum"][$0]).tag($0) } }
            Picker("Rectangle orientation", selection: $bias) { Text("Balanced").tag(0); Text("Wider").tag(6); Text("Taller").tag(-6) }
            Toggle("Show sizes inside rectangles", isOn: $showSizes)
            Toggle("Enable Move to Trash", isOn: $allowDelete)
            Text("Treemap engineering adapted from SpaceMonger 1.4 by Sean Werkema, MIT license. macOS integration by Anyseek.").font(.caption).foregroundStyle(.secondary)
            Button("Done") { showSetup = false }.keyboardShortcut(.defaultAction)
        }.padding(24).frame(width: 440)
    }
    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { root = PathScope.canonical(url.path); zoom = ""; selected = nil }
    }
    private func activate(_ path: String) {
        guard let tree, let id = tree.paths[path] else { return }
        if tree.nodes[id].isDirectory { zoom = path; selected = nil }
        else { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    }
    private func zoomOut() {
        let parent = ((zoom.isEmpty ? root : zoom) as NSString).deletingLastPathComponent
        zoom = PathScope.contains(root,parent) ? parent : root; selected = nil
    }
    private func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    private func trash() {
        guard allowDelete, let selected, selected != root else { return }
        do { try FileManager.default.trashItem(at: URL(fileURLWithPath: selected), resultingItemURL: nil); index.applyLive(removed: [selected]); self.selected = nil }
        catch { message = error.localizedDescription }
    }
    private func followIndex() async {
        var lastRevision = -1, lastLive = -1
        while !Task.isCancelled {
            if lastRevision != index.revision || lastLive != index.liveRevision {
                let revision = index.revision, live = index.liveRevision
                let files = index.files, removed = index.liveRemoved, updated = Array(index.liveUpdated.values), scope = root
                building = true
                let worker = Task.detached(priority: .utility) { try SpaceTree.build(files: files, root: scope, removed: removed, updated: updated) }
                do {
                    let value = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    try Task.checkCancellation()
                    tree = value; lastRevision = revision; lastLive = live; building = false
                    if let selected, value.paths[selected] == nil { self.selected = nil }
                    if !zoom.isEmpty && value.paths[zoom] == nil { zoom = "" }
                } catch { if !Task.isCancelled { building = false; message = error.localizedDescription }; return }
            }
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
        }
    }
    private func size(_ bytes: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(min(Double(Int64.max - 1024),bytes)), countStyle: .file) }
}

struct SpaceMap: NSViewRepresentable {
    let tree: SpaceTree
    let root: Int
    @Binding var selection: String?
    let density: Int
    let bias: Int
    let showSizes: Bool
    let open: (String) -> Void
    let reveal: (String) -> Void
    let trash: (String) -> Void
    let allowDelete: Bool
    func makeNSView(context: Context) -> SpaceMapCanvas { SpaceMapCanvas() }
    func updateNSView(_ view: SpaceMapCanvas, context: Context) {
        view.model = self; view.needsLayout = true; view.needsDisplay = true
    }
}
final class SpaceMapCanvas: NSView, NSViewToolTipOwner {
    var model: SpaceMap?
    private(set) var tiles: [SpaceTile] = []
    private var hovered: Int?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func layout() {
        super.layout()
        guard let model else { return }
        tiles = model.tree.layout(root: model.root, rect: bounds.insetBy(dx: 2,dy: 2), density: model.density, bias: model.bias)
        removeAllToolTips()
        for (i,tile) in tiles.enumerated() { addToolTip(tile.rect, owner: self, userData: UnsafeMutableRawPointer(bitPattern: i + 1)) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeInKeyWindow,.mouseMoved,.mouseEnteredAndExited,.inVisibleRect], owner: self))
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); dirtyRect.fill()
        guard let model else { return }
        let palette: [NSColor] = [.init(calibratedRed: 0.72,green: 0.85,blue: 1,alpha: 1), .init(calibratedRed: 0.76,green: 0.94,blue: 0.72,alpha: 1), .init(calibratedRed: 1,green: 0.88,blue: 0.62,alpha: 1), .init(calibratedRed: 1,green: 0.74,blue: 0.72,alpha: 1), .init(calibratedRed: 0.86,green: 0.77,blue: 1,alpha: 1)]
        for tile in tiles where tile.rect.intersects(dirtyRect) {
            let rect = tile.rect.insetBy(dx: 0.5,dy: 0.5)
            let node = tile.node.map { model.tree.nodes[$0] }
            (node == nil ? NSColor.lightGray : palette[tile.depth % palette.count]).setFill(); rect.fill()
            NSColor.white.setStroke(); NSBezierPath(rect: rect).stroke()
            guard rect.width > 25, rect.height > 12 else { continue }
            let name = node?.name ?? "Smaller items"
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingMiddle
            let font = NSFont.systemFont(ofSize: 10, weight: node?.isDirectory == true ? .semibold : .regular)
            let attrs: [NSAttributedString.Key: Any] = [.font: font,.foregroundColor: NSColor.black,.paragraphStyle: style]
            (name as NSString).draw(in: NSRect(x: rect.minX + 3,y: rect.minY + 1,width: max(0,rect.width - 6),height: 13), withAttributes: attrs)
            if model.showSizes && node?.isDirectory != true && rect.height > 30 {
                let bytes = ByteCountFormatter.string(fromByteCount: Int64(min(Double(Int64.max - 1024),tile.bytes)), countStyle: .file)
                (bytes as NSString).draw(in: NSRect(x: rect.minX + 3,y: rect.minY + 15,width: max(0,rect.width - 6),height: 13), withAttributes: attrs)
            }
        }
        if let selected = model.selection, let tile = tiles.last(where: { $0.node.map { model.tree.nodes[$0].path == selected } ?? false }) {
            NSColor.selectedControlColor.setStroke(); let path = NSBezierPath(rect: tile.rect.insetBy(dx: 1,dy: 1)); path.lineWidth = 3; path.stroke()
        }
        if let hovered, tiles.indices.contains(hovered) { NSColor.black.withAlphaComponent(0.6).setStroke(); NSBezierPath(rect: tiles[hovered].rect.insetBy(dx: 1,dy: 1)).stroke() }
    }
    private func hit(_ event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return tiles.indices.reversed().first { tiles[$0].rect.contains(point) }
    }
    private func path(_ tile: Int) -> String? {
        guard let model else { return nil }
        return model.tree.nodes[tiles[tile].node ?? tiles[tile].parent].path
    }
    override func mouseMoved(with event: NSEvent) { let next = hit(event); if hovered != next { hovered = next; needsDisplay = true } }
    override func mouseExited(with event: NSEvent) { hovered = nil; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let id = hit(event), let path = path(id) else { model?.selection = nil; return }
        model?.selection = path; needsDisplay = true
        if event.clickCount == 2 { model?.open(path) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let id = hit(event), let path = path(id), let model else { return nil }
        model.selection = path
        let menu = NSMenu()
        menu.addItem(MenuCommand("Open / Zoom In") { model.open(path) })
        menu.addItem(MenuCommand("Reveal in Finder") { model.reveal(path) })
        menu.addItem(MenuCommand("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string) })
        menu.addItem(.separator())
        menu.addItem(MenuCommand("Move to Trash…", enabled: model.allowDelete && path != model.tree.nodes[model.root].path) { model.trash(path) })
        return menu
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, let path = model?.selection { model?.open(path) }
        else if event.keyCode == 51 && event.modifierFlags.contains(.command), let path = model?.selection, model?.allowDelete == true { model?.trash(path) }
        else { super.keyDown(with: event) }
    }
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let model, let hit = tiles.indices.reversed().first(where: { tiles[$0].rect.contains(point) }) else { return "" }
        let tile = tiles[hit], node = model.tree.nodes[tile.node ?? tile.parent]
        return "\(node.path)\n\(ByteCountFormatter.string(fromByteCount: Int64(min(Double(Int64.max - 1024),tile.bytes)), countStyle: .file))\(tile.node == nil ? " in smaller items; double-click to zoom into parent" : "")"
    }
}
