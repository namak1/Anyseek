import SwiftUI
import AppKit
import AnyseekCore

@main struct AnyseekApp: App {
    @StateObject private var index = IndexStore()
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
    @State private var query = ""
    @State private var category = "Everything"
    @State private var caseSensitive = false
    @State private var matchPath = false
    @State private var results: [FileRecord] = []
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\FileRecord.name)]
    @State private var folders = false
    @State private var bookmarks = UserDefaults.standard.stringArray(forKey: "bookmarks") ?? []
    @State private var error: String?
    @FocusState private var searchFocused: Bool
    private let categories = ["Everything", "Folders", "Documents", "Images", "Audio", "Video", "Archives"]
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search files and folders", text: $query).textFieldStyle(.plain).focused($searchFocused)
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                Picker("Filter", selection: $category) { ForEach(categories, id: \.self) { Text($0) } }.labelsHidden().frame(width: 140)
            }.padding(12)
            Divider()
            HStack {
                Toggle("Match Case", isOn: $caseSensitive)
                Toggle("Match Path", isOn: $matchPath)
                Spacer()
                Menu("Bookmarks") {
                    Button("Bookmark Current Search") {
                        if !query.isEmpty && !bookmarks.contains(query) { bookmarks.append(query); UserDefaults.standard.set(bookmarks, forKey: "bookmarks") }
                    }
                    ForEach(bookmarks, id: \.self) { saved in Button(saved) { query = saved } }
                    Divider()
                    Button("Clear Bookmarks") { bookmarks = []; UserDefaults.standard.removeObject(forKey: "bookmarks") }
                }.frame(width: 110)
            }.toggleStyle(.checkbox).font(.system(size: 11)).padding(.horizontal, 12).padding(.vertical, 6)
            Table(results, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { file in
                    HStack(spacing: 6) {
                        Image(systemName: file.isDirectory ? "folder.fill" : "doc").foregroundStyle(file.isDirectory ? .blue : .secondary)
                        Text(file.name).lineLimit(1)
                    }
                }.width(min: 180, ideal: 260)
                TableColumn("Path", value: \.path) { Text(URL(fileURLWithPath: $0.path).deletingLastPathComponent().path).foregroundStyle(.secondary) }.width(min: 180, ideal: 340)
                TableColumn("Size", value: \.size) { Text($0.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file)) }.width(85)
                TableColumn("Date Modified", value: \.modified) { Text($0.modified.formatted(date: .numeric, time: .shortened)) }.width(145)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Open") { open(ids) }.disabled(ids.isEmpty)
                Button("Reveal in Finder") { reveal(ids) }.disabled(ids.isEmpty)
                Button("Copy Paths") { copy(ids) }.disabled(ids.isEmpty)
            } primaryAction: { ids in open(ids) }
            Divider()
            HStack {
                Text("\(results.count.formatted()) objects")
                Spacer()
                if index.indexing { ProgressView().controlSize(.small) }
                Text(index.status)
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 7)
        }
        .toolbar {
            Button { index.chooseFolders() } label: { Label("Add Folders", systemImage: "folder.badge.plus") }
            Button { folders = true } label: { Label("Indexed Folders", systemImage: "externaldrive") }
            Button { index.rebuild() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            Button { export() } label: { Label("Export Results", systemImage: "square.and.arrow.up") }
            Button { searchFocused = true } label: { Label("Find", systemImage: "magnifyingglass") }.keyboardShortcut("f")
        }
        .sheet(isPresented: $folders) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Indexed Folders").font(.headline)
                Text("Add the folders or drives you want to search. Access-denied locations are reported in the status bar.").foregroundStyle(.secondary)
                List(index.roots, id: \.self) { root in HStack { Text(root); Spacer(); Button("Remove") { index.removeRoot(root) } } }.frame(height: 200)
                HStack { Button("Add Folders…") { index.chooseFolders() }; Spacer(); Button("Done") { folders = false }.keyboardShortcut(.defaultAction) }
            }.padding(20).frame(width: 620)
        }
        .alert("Anyseek", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        .task(id: query + category + String(caseSensitive) + String(matchPath) + String(index.revision)) { await search() }
        .onChange(of: sortOrder) { _ in results.sort(using: sortOrder) }
        .onAppear { searchFocused = true }
    }
    private func search() async {
        do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
        let files = index.files, text = query, selectedCategory = category, sensitive = caseSensitive, path = matchPath
        let filtered = await Task.detached(priority: .userInitiated) {
            let parser = SearchQuery(text, caseSensitive: sensitive, matchPath: path)
            let extensions: [String: Set<String>] = ["Documents": ["pdf", "doc", "docx", "txt", "rtf", "xlsx", "csv", "pptx", "md"], "Images": ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "svg"], "Audio": ["mp3", "m4a", "flac", "wav", "aac", "aiff", "ogg"], "Video": ["mp4", "mkv", "mov", "avi", "webm", "m4v"], "Archives": ["zip", "rar", "7z", "gz", "tar"]]
            return files.filter { file in
                let categoryMatches = selectedCategory == "Everything" || (selectedCategory == "Folders" ? file.isDirectory : !file.isDirectory && (extensions[selectedCategory]?.contains(URL(fileURLWithPath: file.path).pathExtension.lowercased()) ?? false))
                return categoryMatches && parser.matches(file)
            }
        }.value
        guard !Task.isCancelled else { return }
        results = filtered.sorted(using: sortOrder)
        selection.formIntersection(Set(results.map(\.id)))
    }
    private func open(_ ids: Set<String>) { for path in ids { if !NSWorkspace.shared.open(URL(fileURLWithPath: path)) { error = "Could not open \(path)" } } }
    private func reveal(_ ids: Set<String>) { NSWorkspace.shared.activateFileViewerSelecting(ids.map { URL(fileURLWithPath: $0) }) }
    private func copy(_ ids: Set<String>) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ids.sorted().joined(separator: "\n"), forType: .string) }
    private func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Anyseek-results.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func csv(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let text = "Name,Path,Size,Modified\n" + results.map { [csv($0.name), csv($0.path), String($0.size), csv(ISO8601DateFormatter().string(from: $0.modified))].joined(separator: ",") }.joined(separator: "\n")
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { self.error = error.localizedDescription }
    }
}
