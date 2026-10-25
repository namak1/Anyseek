import SwiftUI
import AppKit
import AnyseekCore
import ServiceManagement

struct AnyseekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var index = makeIndexStore()
    var body: some Scene {
        WindowGroup("Anyseek") { SearchWindow().environmentObject(index).frame(minWidth: 780, minHeight: 460) }
        .commands {
            CommandGroup(after: .newItem) { Button("Add Indexed Folders…") { index.chooseFolders() }.keyboardShortcut("o", modifiers: [.command, .shift]) }
            CommandGroup(after: .toolbar) { Button("Refresh Index") { index.rebuild() }.keyboardShortcut("r") }
        }
    }
}
struct SearchWindow: View {
    @EnvironmentObject var index: IndexStore
    @AppStorage("lastQuery") private var query = ""
    @State private var wholeWord = false
    @State private var regex = false
    @State private var queryError: String?
    @State private var history = UserDefaults.standard.stringArray(forKey: "history") ?? []
    @State private var preview = false
    @AppStorage("previewPane") private var previewPane = false
    @State private var diagnostics = false
    @State private var help = false
    @State private var renamePath: String?
    @State private var newName = ""
    @State private var trashSelection = Set<String>()
    @State private var confirmTrash = false
    @AppStorage("showHidden") private var showHidden = true
    @State private var category = "Everything"
    @State private var caseSensitive = false
    @State private var matchPath = false
    @State private var results: ResultRows = .empty
    @State private var resultIndex = ResultIndex()
    @State private var resultGeneration = 0
    @State private var sortGeneration = 0
    @State private var searching = false
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\FileRecord.name)]
    @State private var folders = false
    @State private var options = false
    @State private var advanced = false
    @AppStorage("showFilterBar") private var showFilterBar = false
    @AppStorage("showStatusBar") private var showStatusBar = true
    @AppStorage("hideEmptyResults") private var hideEmptyResults = false
    @AppStorage("alternateRows") private var alternateRows = false
    @AppStorage("resultFontSize") private var resultFontSize = 12.0
    @State private var bookmarks = UserDefaults.standard.stringArray(forKey: "bookmarks") ?? []
    @State private var error: String?
    @FocusState private var searchFocused: Bool
    private let categories = ["Everything", "Folders", "Documents", "Images", "Audio", "Video", "Archives"]
    var body: some View {
        VStack(spacing: 0) {
            classicMenuBar
            HStack(spacing: 2) {
                TextField("", text: $query).textFieldStyle(.plain).focused($searchFocused)
                    .font(.system(size: 13)).padding(.horizontal, 4).frame(height: 23)
                    .background(Color.white).border(Color.gray.opacity(0.6))
                    .onSubmit { if let first = results.first { open(selection.isEmpty ? [first.path] : selection) } }
                Menu { ForEach(history, id: \.self) { saved in Button(saved) { query = saved } } } label: { Image(systemName: "chevron.down").font(.system(size: 9)) }.menuStyle(.borderlessButton).frame(width: 16)
                if showFilterBar { Picker("Filter", selection: $category) { ForEach(categories, id: \.self) { Text($0) } }.labelsHidden().frame(width: 115) }
            }.padding(.horizontal, 3).padding(.vertical, 3)
            if let queryError { Text(queryError).foregroundStyle(.red).font(.caption).padding(6) }
            HSplitView {
            FastResultsTable(files: results, selection: $selection, sortOrder: $sortOrder, generation: resultGeneration, alternate: alternateRows, fontSize: resultFontSize, open: { open($0) }, preview: { selection = $0; preview = true }, copy: { copyFiles($0) }, trash: { trashSelection = $0; confirmTrash = !$0.isEmpty }, actions: { ids in
                let menu = NSMenu(); menu.autoenablesItems = false
                menu.addItem(MenuCommand("Open", enabled: !ids.isEmpty) { open(ids) })
                menu.addItem(MenuCommand("Reveal in Finder", enabled: !ids.isEmpty) { reveal(ids) })
                menu.addItem(MenuCommand("Copy Files", enabled: !ids.isEmpty) { copyFiles(ids) })
                menu.addItem(MenuCommand("Copy Paths", enabled: !ids.isEmpty) { copy(ids) })
                menu.addItem(MenuCommand("Quick Look", enabled: !ids.isEmpty) { selection = ids; preview = true })
                menu.addItem(MenuCommand("Rename…", enabled: ids.count == 1) { beginRename(ids) })
                menu.addItem(MenuCommand("Move to Trash…", enabled: !ids.isEmpty) { trashSelection = ids; confirmTrash = true })
                return menu
            })
            if previewPane {
                VStack {
                    if let path = selection.sorted().first { FilePreview(path: path) }
                    else { Text("Select a file to preview").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                }.frame(minWidth: 180, idealWidth: 260)
            }
            }
            Divider()
            if showStatusBar { HStack {
                Text("\(results.count.formatted()) objects")
                Spacer()
                if searching { Text("Updating results…") }
                if index.indexing { ProgressView().controlSize(.small) }
                Text(index.status)
                if index.indexing { Button("Pause") { index.cancel() }.buttonStyle(.link) }
                if !index.issues.isEmpty { Button("Details") { diagnostics = true }.buttonStyle(.link) }
                Text([caseSensitive ? "CASE" : "", wholeWord ? "WORD" : "", matchPath ? "PATH" : "", regex ? "REGEX" : "", category == "Everything" ? "" : category].filter { !$0.isEmpty }.joined(separator: "  "))
            }.font(.system(size: 11)).padding(.horizontal, 5).padding(.vertical, 3) }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.light)
        .sheet(isPresented: $options) { ClassicOptions(index: index) }
        .sheet(isPresented: $advanced) { AdvancedSearchDialog(query: $query) }
        .sheet(isPresented: $folders) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Indexed Folders").font(.headline)
                Text("Add the folders or drives you want to search. Access-denied locations are reported in the status bar.").foregroundStyle(.secondary)
                List(index.roots, id: \.self) { root in HStack { Text(root); Spacer(); Button("Remove") { index.removeRoot(root) } } }.frame(height: 200)
                Text("Excluded folders").font(.headline)
                List(index.excluded, id: \.self) { path in HStack { Text(path); Spacer(); Button("Remove") { index.removeExclusion(path) } } }.frame(height: 110)
                Button("Exclude Folder…") { index.chooseFolders(exclude: true) }
                HStack { Button("Add Folders…") { index.chooseFolders() }; Spacer(); Button("Done") { folders = false }.keyboardShortcut(.defaultAction) }
            }.padding(20).frame(width: 620)
        }
        .sheet(isPresented: $preview) {
            VStack {
                HStack { Text(selection.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Preview").font(.headline); Spacer(); Button("Done") { preview = false } }
                if let path = selection.sorted().first { FilePreview(path: path).frame(minWidth: 640, minHeight: 440) }
            }.padding().frame(minWidth: 680, minHeight: 480)
        }
        .sheet(isPresented: $diagnostics) {
            VStack(alignment: .leading) {
                Text("Indexing & Selection Details").font(.headline)
                ForEach(results.filter { selection.contains($0.path) }.prefix(5)) { file in
                    Text("\(file.name)\n\(file.path)\n\(file.size.formatted()) bytes · \(file.modified.formatted())").textSelection(.enabled)
                }
                Text("Offline roots keep their cached entries. Denied paths may need access in System Settings.").foregroundStyle(.secondary)
                List(Array(index.issues.enumerated()), id: \.offset) { item in Text(item.element).textSelection(.enabled) }
                Button("Done") { diagnostics = false }
            }.padding().frame(width: 650, height: 400)
        }
        .sheet(isPresented: $help) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Search Anyseek").font(.headline)
                Text("invoice *.pdf\n<*.jpg | *.png> !draft\next:pdf;docx size:1mb..10mb\npath:/Documents dm:7days\nfolder:photos\nregex:\"^Report[0-9]+\"\n*.txt content:\"shipping notice\"").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Text("Spaces mean AND; | means OR; ! excludes; < > group terms. Quote phrases and regex containing spaces or operators. Content search reads UTF-8 files up to 16 MB and is slower. PDF/Word text extraction is not included.").foregroundStyle(.secondary)
                Text("⌃⌥Space opens Anyseek globally. ⌘F focuses search. Select results for Finder actions; drag a filename to another app.")
                Button("Done") { help = false }.keyboardShortcut(.defaultAction)
            }.padding(24).frame(width: 600)
        }
        .alert("Rename", isPresented: Binding(get: { renamePath != nil }, set: { if !$0 { renamePath = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { renamePath = nil }
            Button("Rename") { rename() }
        } message: { Text("Enter a new filename, including its extension.") }
        .confirmationDialog("Move \(trashSelection.count) selected items to Trash?", isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { trash() }
            Button("Cancel", role: .cancel) { }
        }
        .alert("Anyseek", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        .task(id: query + category + String(caseSensitive) + String(matchPath) + String(index.revision) + String(wholeWord) + String(regex) + String(showHidden) + String(hideEmptyResults) + String(sortGeneration) + String(index.liveRevision)) { await search() }
        .onChange(of: options) { visible in if !visible { history = UserDefaults.standard.stringArray(forKey: "history") ?? [] } }
        .onChange(of: sortOrder) { _ in sortGeneration += 1 }
        .onAppear { query = ""; category = "Everything"; hideEmptyResults = false; searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .anyseekFocus)) { _ in searchFocused = true }
    }
    private var classicMenuBar: some View { NativeMenuBar(menus: nativeMenus).frame(height: 24) }
    private var nativeMenus: [NSMenu] {
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let result = NSMenu(title: title); result.autoenablesItems = false
            items.forEach { result.addItem($0) }; return result
        }
        func command(_ title: String, checked: Bool = false, enabled: Bool = true, _ action: @escaping () -> Void) -> NSMenuItem { MenuCommand(title, checked: checked, enabled: enabled, action: action) }
        return [
            menu("File", [command("Open", enabled: !selection.isEmpty) { open(selection) }, command("Open Path", enabled: !selection.isEmpty) { reveal(selection) }, .separator(), command("Export…") { export() }, .separator(), command("Exit") { NSApp.terminate(nil) }]),
            menu("Edit", [command("Copy", enabled: !selection.isEmpty) { copyFiles(selection) }, command("Copy Full Name to Clipboard", enabled: !selection.isEmpty) { copy(selection) }, command("Select All") { selection = Set(results.map(\.path)) }, .separator(), command("Rename…", enabled: selection.count == 1) { beginRename(selection) }, command("Delete…", enabled: !selection.isEmpty) { trashSelection = selection; confirmTrash = true }]),
            menu("View", [command("Filter Bar", checked: showFilterBar) { showFilterBar.toggle() }, command("Status Bar", checked: showStatusBar) { showStatusBar.toggle() }, command("Show Hidden Files", checked: showHidden) { showHidden.toggle() }, .separator(), command("Preview", checked: previewPane) { previewPane.toggle() }, command("Refresh") { index.rebuild() }, command("Zoom In") { resultFontSize = min(22, resultFontSize + 1) }, command("Zoom Out") { resultFontSize = max(9, resultFontSize - 1) }]),
            menu("Search", [command("Match Case", checked: caseSensitive) { caseSensitive.toggle() }, command("Match Whole Word", checked: wholeWord) { wholeWord.toggle() }, command("Match Path", checked: matchPath) { matchPath.toggle() }, command("Enable Regex", checked: regex) { regex.toggle() }, .separator()] + categories.map { item in command(item, checked: category == item) { category = item } } + [.separator(), command("Advanced Search…") { advanced = true }]),
            menu("Bookmarks", [command("Add to Bookmarks…") { saveBookmark() }] + bookmarks.map { saved in command(saved) { restoreBookmark(saved) } } + [.separator(), command("Clear Bookmarks") { bookmarks = []; UserDefaults.standard.removeObject(forKey: "bookmarks"); UserDefaults.standard.removeObject(forKey: "bookmarkPresets") }]),
            menu("Tools", [command("Options…") { options = true }, command("Indexing Details…") { diagnostics = true }]),
            menu("Help", [command("Search Syntax") { help = true }, command("About Anyseek") { error = "Anyseek 0.3.1\nIndependent macOS file search." }])
        ]
    }
    private func search() async {
        let files = index.files, text = query, selectedCategory = category, sensitive = caseSensitive, path = matchPath, whole = wholeWord, regular = regex, hidden = showHidden
        let parser = SearchQuery(text, caseSensitive: sensitive, matchPath: path, wholeWord: whole, regex: regular)
        queryError = parser.error
        let comparator = sortOrder.first
        let column: ResultColumn = comparator?.keyPath == \FileRecord.size ? .size : comparator?.keyPath == \FileRecord.modified ? .modified : comparator?.keyPath == \FileRecord.path ? .path : .name
        let descending = comparator?.order == .reverse
        let revision = index.revision
        let liveToken = index.liveRevision, removed = index.liveRemoved, updated = Array(index.liveUpdated.values)
        let signature = [text, selectedCategory, String(sensitive), String(path), String(whole), String(regular), String(hidden)].joined(separator: "\0")
        let engine = resultIndex
        searching = true
        let worker = Task.detached(priority: .userInitiated) {
            let extensions: [String: Set<String>] = ["Documents": ["pdf", "doc", "docx", "txt", "rtf", "xlsx", "csv", "pptx", "md"], "Images": ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "svg"], "Audio": ["mp3", "m4a", "flac", "wav", "aac", "aiff", "ogg"], "Video": ["mp4", "mkv", "mov", "avi", "webm", "m4v"], "Archives": ["zip", "rar", "7z", "gz", "tar"]]
            return try await engine.results(files: files, revision: revision, signature: signature, column: column, descending: descending, liveToken: liveToken, removed: removed, updated: updated) { file in
                if !hidden && file.path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return false }
                let categoryMatches = selectedCategory == "Everything" || (selectedCategory == "Folders" ? file.isDirectory : !file.isDirectory && (extensions[selectedCategory]?.contains((file.name as NSString).pathExtension.lowercased()) ?? false))
                return categoryMatches && (text.isEmpty || parser.matches(file))
            }
        }
        do {
            let filtered = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled else { return }
            results = hideEmptyResults && text.isEmpty ? .empty : filtered
            resultGeneration += 1; searching = false
            // Selection reconciliation only examines selected rows, not every path.
            if !selection.isEmpty { selection.formIntersection(Set(results.lazy.filter { selection.contains($0.path) }.map(\.path))) }
        } catch is CancellationError { }
        catch { searching = false; self.error = error.localizedDescription }
    }
    private func open(_ ids: Set<String>) { rememberSearch(); for path in ids { if !NSWorkspace.shared.open(URL(fileURLWithPath: path)) { error = "Could not open \(path)" } } }
    private func reveal(_ ids: Set<String>) { NSWorkspace.shared.activateFileViewerSelecting(ids.map { URL(fileURLWithPath: $0) }) }
    private func copy(_ ids: Set<String>) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ids.sorted().joined(separator: "\n"), forType: .string) }
    private struct Preset: Codable {
        var category: String; var matchCase: Bool; var matchPath: Bool; var wholeWord: Bool; var regex: Bool
    }
    private func saveBookmark() {
        guard !query.isEmpty else { return }
        if !bookmarks.contains(query) { bookmarks.append(query) }
        UserDefaults.standard.set(bookmarks, forKey: "bookmarks")
        let preset = Preset(category: category, matchCase: caseSensitive, matchPath: matchPath, wholeWord: wholeWord, regex: regex)
        if let data = try? JSONEncoder().encode(preset) {
            var presets = UserDefaults.standard.dictionary(forKey: "bookmarkPresets") ?? [:]
            presets[query] = data; UserDefaults.standard.set(presets, forKey: "bookmarkPresets")
        }
    }
    private func restoreBookmark(_ saved: String) {
        query = saved
        guard let data = UserDefaults.standard.dictionary(forKey: "bookmarkPresets")?[saved] as? Data,
              let preset = try? JSONDecoder().decode(Preset.self, from: data) else { return }
        category = preset.category; caseSensitive = preset.matchCase; matchPath = preset.matchPath; wholeWord = preset.wholeWord; regex = preset.regex
    }
    private func rememberSearch() {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        history.removeAll { $0 == query }; history.insert(query, at: 0); history = Array(history.prefix(50))
        UserDefaults.standard.set(history, forKey: "history")
    }
    private func copyFiles(_ ids: Set<String>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(ids.sorted().map { NSURL(fileURLWithPath: $0) })
    }
    private func beginRename(_ ids: Set<String>) {
        guard ids.count == 1, let path = ids.first else { return }
        newName = URL(fileURLWithPath: path).lastPathComponent; renamePath = path
    }
    private func rename() {
        guard let path = renamePath else { return }
        defer { renamePath = nil }
        guard !newName.isEmpty, newName != ".", newName != "..", !newName.contains("/"), !newName.contains(":"), !newName.contains("\0") else { error = "Enter a valid filename without / or :"; return }
        let source = URL(fileURLWithPath: path), destination = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(newName)
        if source == destination { return }
        do { try FileManager.default.moveItem(at: source, to: destination); index.rebuild() }
        catch { self.error = error.localizedDescription }
    }
    private func trash() {
        var failures: [String] = []
        var deleted: [String] = []
        for path in PathScope.compact(Array(trashSelection)) {
            do { try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil); deleted.append(path) }
            catch { failures.append("\(path): \(error.localizedDescription)") }
        }
        if !deleted.isEmpty { index.applyLive(removed: deleted); results = results.removing { file in deleted.contains { PathScope.contains($0, file.path) } }; resultGeneration += 1 }
        if !failures.isEmpty { error = failures.joined(separator: "\n") }
        selection = []
    }
    private func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Anyseek-results.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func csv(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let text = "Name,Path,Size,Modified\n" + results.map { [csv($0.name), csv($0.path), String($0.size), csv(ISO8601DateFormatter().string(from: $0.modified))].joined(separator: ",") }.joined(separator: "\n")
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { self.error = error.localizedDescription }
    }
}

@MainActor private func makeIndexStore() -> IndexStore {
    guard CommandLine.arguments.contains("--ui-smoke-test") else { return IndexStore() }
    let fm = FileManager.default
    let base = URL(fileURLWithPath: PathScope.canonical(fm.temporaryDirectory.path)).appendingPathComponent("Anyseek-UI-" + UUID().uuidString)
    let root = base.appendingPathComponent("Documents")
    do {
        try fm.createDirectory(at: root.appendingPathComponent("Voyages"), withIntermediateDirectories: true)
        try "Sample invoice".write(to: root.appendingPathComponent("Flora invoice.txt"), atomically: true, encoding: .utf8)
        try "Vessel,Port\nFlora,Jebel Ali".write(to: root.appendingPathComponent("Schedule.csv"), atomically: true, encoding: .utf8)
    } catch { fputs("UI fixture failed: \(error)\n", stderr); exit(1) }
    return IndexStore(cacheURL: base.appendingPathComponent("cache"), selectedRoots: [root.path])
}
