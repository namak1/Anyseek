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
    @State private var results: [FileRecord] = []
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
            Table(results, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { file in
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(width: 16, height: 16)
                        Text(file.name).lineLimit(1).help(file.path).onDrag { NSItemProvider(object: URL(fileURLWithPath: file.path) as NSURL) }
                    }
                }.width(min: 180, ideal: 260)
                TableColumn("Path", value: \.path) { Text(URL(fileURLWithPath: $0.path).deletingLastPathComponent().path).foregroundStyle(.secondary) }.width(min: 180, ideal: 340)
                TableColumn("Size", value: \.size) { Text($0.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file)) }.width(85)
                TableColumn("Date Modified", value: \.modified) { Text($0.modified.formatted(date: .numeric, time: .shortened)) }.width(145)
            }
            .font(.system(size: resultFontSize))
            .background(ClassicTableStyle(alternateRows: alternateRows, fontSize: resultFontSize))
            .background(ResultKeyHandler(open: { open(selection) }, preview: { if !selection.isEmpty { preview = true } }, copy: { copyFiles(selection) }, trash: { if !selection.isEmpty { trashSelection = selection; confirmTrash = true } }))
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Open") { open(ids) }.disabled(ids.isEmpty)
                Button("Reveal in Finder") { reveal(ids) }.disabled(ids.isEmpty)
                Button("Copy Paths") { copy(ids) }.disabled(ids.isEmpty)
                Button("Copy Files") { copyFiles(ids) }.disabled(ids.isEmpty)
                Button("Quick Look") { selection = ids; preview = true }.disabled(ids.isEmpty)
                Button("File Details") { selection = ids; diagnostics = true }.disabled(ids.isEmpty)
                Divider()
                Button("Rename…") { beginRename(ids) }.disabled(ids.count != 1)
                Button("Move to Trash…") { trashSelection = ids; confirmTrash = true }.disabled(ids.isEmpty)
            } primaryAction: { ids in open(ids) }
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
        .task(id: query + category + String(caseSensitive) + String(matchPath) + String(index.revision) + String(wholeWord) + String(regex) + String(showHidden) + String(hideEmptyResults)) { await search() }
        .onChange(of: options) { visible in if !visible { history = UserDefaults.standard.stringArray(forKey: "history") ?? [] } }
        .onChange(of: sortOrder) { _ in results.sort(using: sortOrder) }
        .onAppear { searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .anyseekFocus)) { _ in searchFocused = true }
    }
    private var classicMenuBar: some View {
        HStack(spacing: 0) {
            Menu("File") {
                Button("Open") { open(selection) }.disabled(selection.isEmpty)
                Button("Open Path") { reveal(selection) }.disabled(selection.isEmpty)
                Divider()
                Button("Export…") { export() }
                Divider()
                Button("Exit") { NSApp.terminate(nil) }
            }
            Menu("Edit") {
                Button("Copy") { copyFiles(selection) }.keyboardShortcut("c").disabled(selection.isEmpty)
                Button("Copy Full Name to Clipboard") { copy(selection) }.disabled(selection.isEmpty)
                Button("Select All") { selection = Set(results.map(\.path)) }.keyboardShortcut("a")
                Divider()
                Button("Rename…") { beginRename(selection) }.disabled(selection.count != 1)
                Button("Delete…") { trashSelection = selection; confirmTrash = true }.disabled(selection.isEmpty)
            }
            Menu("View") {
                Toggle("Filter Bar", isOn: $showFilterBar)
                Toggle("Status Bar", isOn: $showStatusBar)
                Toggle("Show Hidden Files", isOn: $showHidden)
                Divider()
                Toggle("Preview", isOn: $previewPane)
                Button("Refresh") { index.rebuild() }.keyboardShortcut("r")
                Button("Zoom In") { resultFontSize = min(22, resultFontSize + 1) }
                Button("Zoom Out") { resultFontSize = max(9, resultFontSize - 1) }
            }
            Menu("Search") {
                Toggle("Match Case", isOn: $caseSensitive)
                Toggle("Match Whole Word", isOn: $wholeWord)
                Toggle("Match Path", isOn: $matchPath)
                Toggle("Enable Regex", isOn: $regex)
                Divider()
                ForEach(categories, id: \.self) { item in Button((category == item ? "✓ " : "") + item) { category = item } }
                Divider()
                Button("Advanced Search…") { advanced = true }
            }
            Menu("Bookmarks") {
                Button("Add to Bookmarks…") { saveBookmark() }.keyboardShortcut("d")
                ForEach(bookmarks, id: \.self) { saved in Button(saved) { restoreBookmark(saved) } }
                Divider()
                Button("Clear Bookmarks") { bookmarks = []; UserDefaults.standard.removeObject(forKey: "bookmarks"); UserDefaults.standard.removeObject(forKey: "bookmarkPresets") }
            }
            Menu("Tools") {
                Button("Options…") { options = true }.keyboardShortcut(",")
                Button("Indexing Details…") { diagnostics = true }
            }
            Menu("Help") {
                Button("Search Syntax") { help = true }
                Button("About Anyseek") { error = "Anyseek 0.3.0\nIndependent macOS implementation. Classic interface reference: Everything 1.4.\nNot affiliated with voidtools." }
            }
            Spacer(minLength: 0)
        }.menuStyle(ClassicMenuStyle()).fixedSize(horizontal: false, vertical: true)
        .font(.system(size: 12)).padding(.horizontal, 5).padding(.vertical, 2)
    }
    private func search() async {
        do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
        let files = index.files, text = query, selectedCategory = category, sensitive = caseSensitive, path = matchPath, whole = wholeWord, regular = regex, hidden = showHidden
        let parser = SearchQuery(text, caseSensitive: sensitive, matchPath: path, wholeWord: whole, regex: regular)
        queryError = parser.error
        let worker = Task.detached(priority: .userInitiated) {
            let extensions: [String: Set<String>] = ["Documents": ["pdf", "doc", "docx", "txt", "rtf", "xlsx", "csv", "pptx", "md"], "Images": ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "svg"], "Audio": ["mp3", "m4a", "flac", "wav", "aac", "aiff", "ogg"], "Video": ["mp4", "mkv", "mov", "avi", "webm", "m4v"], "Archives": ["zip", "rar", "7z", "gz", "tar"]]
            var matches: [FileRecord] = []
            for (offset, file) in files.enumerated() {
                if offset % 256 == 0 && Task.isCancelled { return matches }
                if !hidden && file.path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
                let categoryMatches = selectedCategory == "Everything" || (selectedCategory == "Folders" ? file.isDirectory : !file.isDirectory && (extensions[selectedCategory]?.contains(URL(fileURLWithPath: file.path).pathExtension.lowercased()) ?? false))
                if categoryMatches && parser.matches(file) { matches.append(file) }
            }
            return matches
        }
        let filtered = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        guard !Task.isCancelled else { return }
        results = hideEmptyResults && text.isEmpty ? [] : filtered.sorted(using: sortOrder)
        selection.formIntersection(Set(results.map(\.id)))
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
        for path in PathScope.compact(Array(trashSelection)) {
            do { try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) }
            catch { failures.append("\(path): \(error.localizedDescription)") }
        }
        if !failures.isEmpty { error = failures.joined(separator: "\n") }
        selection = []; index.rebuild()
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
