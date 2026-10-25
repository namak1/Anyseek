import SwiftUI
import AppKit
import ServiceManagement

struct ClassicOptions: View {
    @ObservedObject var index: IndexStore
    @Environment(\.dismiss) private var dismiss
    @State private var page: String? = "General"
    @AppStorage("hideEmptyResults") private var hideEmpty = false
    @AppStorage("alternateRows") private var alternateRows = false
    @AppStorage("resultFontSize") private var fontSize = 12.0
    @AppStorage("showHidden") private var hidden = true
    @AppStorage("showFilterBar") private var filterBar = false
    @AppStorage("showStatusBar") private var statusBar = true
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var error: String?
    private let pages = ["General", "Results", "View", "Fonts", "Keyboard", "History", "Indexes", "Folders", "Exclude"]
    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                List(pages, id: \.self, selection: $page) { Text($0).font(.system(size: 12)) }.frame(width: 150)
                VStack(alignment: .leading, spacing: 12) {
                    Text(page ?? "General").font(.system(size: 13, weight: .semibold))
                    Divider()
                    content
                    Spacer()
                }.padding(10).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white).border(Color.gray.opacity(0.4))
            }
            HStack { if let error { Text(error).foregroundStyle(.red).font(.caption) }; Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(12).frame(width: 650, height: 470).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.light)
    }
    @ViewBuilder private var content: some View {
        switch page ?? "General" {
        case "General":
            Toggle("Start Anyseek on system startup", isOn: $login).onChange(of: login) { enabled in
                do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                catch { self.error = error.localizedDescription; login = SMAppService.mainApp.status == .enabled }
            }
            Text("The notification-area icon and global hotkey remain available when the search window is closed.").font(.caption).foregroundStyle(.secondary)
        case "Results":
            Toggle("Hide results when the search is empty", isOn: $hideEmpty)
            Text("Double-click a result to open it. Use the context menu for path, clipboard, rename and Trash actions.").font(.caption)
        case "View":
            Toggle("Alternate row color", isOn: $alternateRows)
            Toggle("Show filter bar", isOn: $filterBar)
            Toggle("Show status bar", isOn: $statusBar)
            Toggle("Show hidden files and folders", isOn: $hidden)
        case "Fonts":
            HStack { Text("Result list font size:"); Stepper("\(Int(fontSize)) pt", value: $fontSize, in: 9...22).frame(width: 130) }
        case "Keyboard":
            Text("Global shortcut: Control + Option + Space\nSearch: Command + F\nRefresh: Command + R\nCopy files: Command + C\nSelect all: Command + A\nPreview: Space\nOpen: Return\nMove to Trash: Command + Delete").lineSpacing(8).font(.system(size: 12))
        case "History":
            Button("Clear search history now") { UserDefaults.standard.removeObject(forKey: "history") }
            Button("Clear last search") { UserDefaults.standard.removeObject(forKey: "lastQuery") }
        case "Indexes":
            Text("Database location:").font(.caption)
            Text("~/Library/Application Support/Anyseek/index.sqlite").font(.system(size: 11)).textSelection(.enabled)
            Text("\(index.files.count.formatted()) indexed objects")
            HStack { Button("Force Rebuild") { index.rebuild() }; Button("Pause") { index.cancel() } }
            Text(index.status).font(.caption)
        case "Folders":
            List(index.roots, id: \.self) { path in HStack { Text(path).font(.system(size: 11)); Spacer(); Button("Remove") { index.removeRoot(path) } } }
            HStack { Button("Add…") { index.chooseFolders() }; Button("Update All Now") { index.rebuild() } }
        case "Exclude":
            List(index.excluded, id: \.self) { path in HStack { Text(path).font(.system(size: 11)); Spacer(); Button("Remove") { index.removeExclusion(path) } } }
            Button("Add Folder…") { index.chooseFolders(exclude: true) }
        default: EmptyView()
        }
    }
}

struct AdvancedSearchDialog: View {
    @Binding var query: String
    @Environment(\.dismiss) private var dismiss
    @State private var all = ""
    @State private var phrase = ""
    @State private var any = ""
    @State private var exclude = ""
    @State private var location = ""
    @State private var extensions = ""
    @State private var minSize = ""
    @State private var maxSize = ""
    @State private var modified = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Advanced Search").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                row("All these words:", $all)
                row("This exact phrase:", $phrase)
                row("Any of these words:", $any)
                row("None of these words:", $exclude)
                Divider()
                row("Located in:", $location)
                row("Extensions (pdf;docx):", $extensions)
                row("Minimum size (e.g. 1mb):", $minSize)
                row("Maximum size (e.g. 10mb):", $maxSize)
                row("Date modified:", $modified)
            }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("OK") { apply(); dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 590).preferredColorScheme(.light)
    }
    private func row(_ name: String, _ value: Binding<String>) -> some View { GridRow { Text(name).font(.system(size: 12)); TextField("", text: value).frame(minWidth: 300) } }
    private func apply() {
        func quoted(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "") + "\"" }
        var terms: [String] = []
        if !all.isEmpty { terms.append(all) }
        if !phrase.isEmpty { terms.append(quoted(phrase)) }
        if !any.isEmpty { terms.append("<" + any.split(separator: " ").map { quoted(String($0)) }.joined(separator: " | ") + ">") }
        terms += exclude.split(separator: " ").map { "!" + quoted(String($0)) }
        if !location.isEmpty { terms.append("path:" + quoted(location)) }
        if !extensions.isEmpty { terms.append("ext:" + extensions) }
        if !minSize.isEmpty { terms.append("size:>=" + minSize) }
        if !maxSize.isEmpty { terms.append("size:<=" + maxSize) }
        if !modified.isEmpty { terms.append("dm:" + modified) }
        query = terms.joined(separator: " ")
    }
}

struct ClassicTableStyle: NSViewRepresentable {
    let alternateRows: Bool
    let fontSize: Double
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let content = view.window?.contentView else { return }
            func apply(_ parent: NSView) {
                if let table = parent as? NSTableView {
                    table.usesAlternatingRowBackgroundColors = alternateRows
                    table.rowHeight = CGFloat(fontSize + 6)
                    table.intercellSpacing = NSSize(width: 3, height: 0)
                    table.backgroundColor = .white
                }
                for child in parent.subviews { apply(child) }
            }
            apply(content)
        }
    }
}
