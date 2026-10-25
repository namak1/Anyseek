import SwiftUI
import AppKit
import AnyseekCore
import UniformTypeIdentifiers

struct FastResultsTable: NSViewRepresentable {
    var files: ResultRows
    @Binding var selection: Set<String>
    @Binding var sortOrder: [KeyPathComparator<FileRecord>]
    var generation: Int
    var alternate: Bool
    var fontSize: Double
    var open: (Set<String>) -> Void
    var preview: (Set<String>) -> Void
    var copy: (Set<String>) -> Void
    var trash: (Set<String>) -> Void
    var actions: (Set<String>) -> NSMenu
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        let table = ResultTable(); table.allowsMultipleSelection = true; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.openRows)
        for (key,title,width) in [("name","Name",260.0),("path","Path",340.0),("size","Size",90.0),("modified","Date Modified",150.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key)); column.title = title; column.width = width
            column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            table.addTableColumn(column)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        table.context = { [weak coordinator = context.coordinator] in coordinator?.contextMenu() ?? NSMenu() }
        table.keyAction = { [weak coordinator = context.coordinator] event in coordinator?.key(event) ?? false }
        scroll.documentView = table; context.coordinator.table = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator; c.parent = self
        guard let table = c.table else { return }
        table.usesAlternatingRowBackgroundColors = alternate; table.rowHeight = fontSize + 6
        table.intercellSpacing = NSSize(width: 3, height: 0); table.backgroundColor = .white
        let currentSelection = Set(table.selectedRowIndexes.filter { files.indices.contains($0) }.map { files[$0].path })
        if c.generation != generation || c.fontSize != fontSize || currentSelection != selection {
            c.fontSize = fontSize
            c.generation = generation; c.updating = true
            table.reloadData()
            if selection.isEmpty { table.deselectAll(nil) }
            else {
                // Restoring a selection after a sort must not scan millions of rows
                // on the AppKit thread. Ignore obsolete restoration tasks.
                c.restore?.cancel()
                let wanted = selection, rows = files, token = generation
                c.restore = Task.detached(priority: .userInitiated) { [c] in
                    var positions = IndexSet()
                    for row in rows.indices {
                        if row & 4095 == 0 && Task.isCancelled { return }
                        if wanted.contains(rows[row].path) { positions.insert(row) }
                    }
                    let selectedPositions = positions
                    await MainActor.run {
                        guard c.generation == token, c.parent.selection == wanted, let table = c.table else { return }
                        c.updating = true
                        table.selectRowIndexes(selectedPositions, byExtendingSelection: false)
                        c.updating = false
                    }
                }
            }
            c.updating = false
            table.scrollRowToVisible(0)
        }
    }
    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var parent: FastResultsTable
        weak var table: NSTableView?
        var generation = -1
        var fontSize = 0.0
        var updating = false
        var restore: Task<Void, Never>?
        let date = DateFormatter()
        let icons = NSCache<NSString, NSImage>()
        init(_ parent: FastResultsTable) { self.parent = parent; date.dateStyle = .short; date.timeStyle = .short }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.files.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.files.indices.contains(row), let column = tableColumn else { return nil }
            let file = parent.files[row]; let id = column.identifier
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = id
            if cell.textField == nil {
                let text = NSTextField(labelWithString: ""); text.translatesAutoresizingMaskIntoConstraints = false; text.lineBreakMode = .byTruncatingMiddle
                cell.addSubview(text); cell.textField = text
                NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: id.rawValue == "name" ? 23 : 4),text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
                if id.rawValue == "name" {
                    let icon = NSImageView(); icon.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(icon); cell.imageView = icon
                    NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),icon.widthAnchor.constraint(equalToConstant: 16),icon.heightAnchor.constraint(equalToConstant: 16)])
                }
            }
            cell.textField?.font = .systemFont(ofSize: parent.fontSize)
            switch id.rawValue {
            case "name": cell.textField?.stringValue = file.name; cell.imageView?.image = icon(file)
            case "path": cell.textField?.stringValue = (file.path as NSString).deletingLastPathComponent
            case "size": cell.textField?.stringValue = file.isDirectory ? "" : ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
            default: cell.textField?.stringValue = date.string(from: file.modified)
            }
            cell.toolTip = file.path; return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            parent.selection = Set(table.selectedRowIndexes.filter { parent.files.indices.contains($0) }.map { parent.files[$0].path })
        }
        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first else { return }
            let order: SortOrder = descriptor.ascending ? .forward : .reverse
            switch descriptor.key {
            case "size": parent.sortOrder = [KeyPathComparator(\FileRecord.size, order: order)]
            case "modified": parent.sortOrder = [KeyPathComparator(\FileRecord.modified, order: order)]
            case "path": parent.sortOrder = [KeyPathComparator(\FileRecord.path, order: order)]
            default: parent.sortOrder = [KeyPathComparator(\FileRecord.name, order: order)]
            }
        }
        private func icon(_ file: FileRecord) -> NSImage {
            let ext = (file.name as NSString).pathExtension.lowercased()
            let key = (file.isDirectory ? "<folder>" : ext) as NSString
            if let cached = icons.object(forKey: key) { return cached }
            let image = NSWorkspace.shared.icon(for: file.isDirectory ? .folder : (UTType(filenameExtension: ext) ?? .data))
            icons.countLimit = 256; icons.setObject(image, forKey: key)
            return image
        }
        @objc func openRows() { parent.open(parent.selection) }
        func contextMenu() -> NSMenu { parent.actions(parent.selection) }
        func key(_ event: NSEvent) -> Bool {
            if event.keyCode == 36 { parent.open(parent.selection); return true }
            if event.keyCode == 49 { parent.preview(parent.selection); return true }
            if event.keyCode == 51 && event.modifierFlags.contains(.command) { parent.trash(parent.selection); return true }
            if event.keyCode == 8 && event.modifierFlags.contains(.command) { parent.copy(parent.selection); return true }
            return false
        }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? { NSURL(fileURLWithPath: parent.files[row].path) }
    }
}
final class ResultTable: NSTableView {
    var context: (() -> NSMenu)?
    var keyAction: ((NSEvent) -> Bool)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 && !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return context?()
    }
    override func keyDown(with event: NSEvent) { if keyAction?(event) != true { super.keyDown(with: event) } }
}
