import SwiftUI
import AppKit
import AnyseekCore

struct WorkspaceTabs: View {
    @AppStorage("workspaceTab") private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            SearchWindow().tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(0)
            SpaceManager().tabItem { Label("Space Manager", systemImage: "square.grid.3x3.fill") }.tag(1)
        }
        .preferredColorScheme(.light)
        .onReceive(NotificationCenter.default.publisher(for: .anyseekFocus)) { _ in tab = 0 }
        .onReceive(NotificationCenter.default.publisher(for: .spaceManagerTest)) { _ in tab = 1 }
    }
}
extension Notification.Name { static let spaceManagerTest = Notification.Name("anyseek.spaceManagerTest") }

struct SpaceManager: View {
    @EnvironmentObject var index: IndexStore
    @AppStorage("spaceRoot") private var root = "/"
    @State private var zoom = ""
    @State private var selected: String?
    @State private var tree: SpaceTree?
    @State private var building = false
    @State private var active = false
    @State private var message: String?
    @State private var confirmTrash = false
    @State private var showSetup = false
    @State private var volumeSpace: (total: Double, free: Double)?
    @AppStorage("spaceShowFreeSpace") private var showFreeSpace = false
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
            toolbar.fixedSize(horizontal: false, vertical: true).layoutPriority(1)
            HStack {
                Text(zoom.isEmpty ? root : zoom).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                Toggle("Show Free Space", isOn: $showFreeSpace).toggleStyle(.checkbox)
                if building { ProgressView().controlSize(.small); Text("Updating map…") }
            }.font(.system(size: 12)).padding(7).fixedSize(horizontal: false, vertical: true)
            if showFreeSpace {
                VStack(alignment: .leading, spacing: 4) {
                    if let space = volumeSpace {
                        HStack {
                            Text("Volume free: \(size(space.free))")
                            Spacer()
                            Text("Used: \(size(space.total - space.free)) · Total: \(size(space.total))")
                        }
                        GeometryReader { geometry in
                            HStack(spacing: 0) {
                                Color.gray.opacity(0.45).frame(width: geometry.size.width * CGFloat(1 - space.free / space.total))
                                Color.green.opacity(0.65)
                            }
                        }.frame(height: 12).clipShape(RoundedRectangle(cornerRadius: 3))
                        Text("Green = free space on this volume. The map below shows indexed files in the selected folder.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Volume free space unavailable").foregroundStyle(.secondary)
                    }
                }.font(.system(size: 11)).padding(.horizontal, 8).padding(.bottom, 7)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let tree, !tree.nodes.isEmpty, tree.nodes[current].bytes > 0 {
                GeometryReader { geometry in
                    SpaceMap(tree: tree, root: current, selection: $selected, density: density, bias: bias, showSizes: showSizes, open: activate, reveal: reveal, trash: { selected = $0; confirmTrash = true }, allowDelete: allowDelete)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
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
            }.font(.system(size: 11)).padding(6).fixedSize(horizontal: false, vertical: true)
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
        SpaceToolbar(roots: index.roots, canZoomIn: selectedNode?.isDirectory == true,
                     canZoomOut: !zoom.isEmpty && zoom != root, hasSelection: selected != nil,
                     canDelete: selected != nil && allowDelete && selected != root,
                     chooseRoot: { root = $0; zoom = ""; selected = nil }, chooseFolder: chooseFolder,
                     reload: { index.rebuild() }, zoomIn: { if let node = selectedNode { activate(node.path) } },
                     zoomOut: zoomOut, zoomFull: { zoom = ""; selected = nil },
                     open: { if let selected { NSWorkspace.shared.open(URL(fileURLWithPath: selected)) } },
                     delete: { confirmTrash = true }, setup: { showSetup = true })
            .frame(height: 36)
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
        var lastRevision = -1, lastLive = -1, capacityTick = 0
        volumeSpace = nil
        while !Task.isCancelled {
            if capacityTick % 10 == 0 {
                let scope = root
                let capacity = await Task.detached(priority: .utility) { () -> (total: Double, free: Double)? in
                    guard let values = try? URL(fileURLWithPath: scope).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
                          let total = values.volumeTotalCapacity, total > 0,
                          let free = values.volumeAvailableCapacity else { return nil }
                    return (Double(total), Double(max(0, min(total, free))))
                }.value
                guard !Task.isCancelled else { return }
                volumeSpace = capacity
            }
            capacityTick += 1
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
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); context.clip(to: bounds)
        defer { context.restoreGState() }
        NSColor.white.setFill(); bounds.fill()
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

// Use native controls so the toolbar has a stable height and inspectable buttons.
struct SpaceToolbar: NSViewRepresentable {
    let roots: [String]
    let canZoomIn: Bool
    let canZoomOut: Bool
    let hasSelection: Bool
    let canDelete: Bool
    let chooseRoot: (String) -> Void
    let chooseFolder: () -> Void
    let reload: () -> Void
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let zoomFull: () -> Void
    let open: () -> Void
    let delete: () -> Void
    let setup: () -> Void
    func makeNSView(context: Context) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        let menu = NSPopUpButton(frame: .zero, pullsDown: true)
        stack.addArrangedSubview(menu)
        for title in ["Reload", "Zoom In", "Zoom Out", "Zoom Full", "Run or Open", "Delete", "Setup"] {
            let button = SpaceToolbarButton(title: title, target: nil, action: nil)
            button.bezelStyle = .rounded; button.controlSize = .small
            button.font = .systemFont(ofSize: 12)
            button.target = button; button.action = #selector(SpaceToolbarButton.invoke)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            stack.addArrangedSubview(button)
        }
        return stack
    }
    func updateNSView(_ stack: NSStackView, context: Context) {
        if let popup = stack.arrangedSubviews.first as? NSPopUpButton {
            let menu = NSMenu()
            menu.addItem(withTitle: "Open", action: nil, keyEquivalent: "")
            for path in roots {
                menu.addItem(MenuCommand(path == "/" ? "Main Drive (/)" : path) { chooseRoot(path) })
            }
            menu.addItem(.separator())
            menu.addItem(MenuCommand("Choose Folder…", action: chooseFolder))
            popup.menu = menu
        }
        let actions: [(Bool, () -> Void)] = [(true, reload), (canZoomIn, zoomIn), (canZoomOut, zoomOut),
            (true, zoomFull), (hasSelection, open), (canDelete, delete), (true, setup)]
        for (view, action) in zip(stack.arrangedSubviews.dropFirst(), actions) {
            guard let button = view as? SpaceToolbarButton else { continue }
            button.isEnabled = action.0; button.handler = action.1
        }
    }
}
final class SpaceToolbarButton: NSButton {
    var handler: (() -> Void)?
    @objc func invoke() { handler?() }
}
