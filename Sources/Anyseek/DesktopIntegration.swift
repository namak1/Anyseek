import AppKit
import Carbon
import QuickLookUI
import SwiftUI
import AnyseekCore

extension Notification.Name {
    static let anyseekFocus = Notification.Name("anyseek.focus")
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var searchWindow: NSWindow?
    private var windowObserver: NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow, !(window is NSPanel) else { return }
            window.isReleasedWhenClosed = false
            self?.searchWindow = window
        }
        if CommandLine.arguments.contains("--ui-smoke-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.smokeTest() }
        }
        if CommandLine.arguments.contains("--ui-performance-test") {
            Task { @MainActor in await self.performanceTest() }
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Anyseek")
        let menu = NSMenu()
        let show = NSMenuItem(title: "Show Anyseek    ⌃⌥Space", action: #selector(showWindow), keyEquivalent: "")
        show.target = self; menu.addItem(show); menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Anyseek", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu; self.item = item
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.showWindow() }
            return noErr
        }, 1, &event, nil, &handler)
        let id = EventHotKeyID(signature: 0x41534B31, id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { show.title = "Show Anyseek (shortcut unavailable)" }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    @objc func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) ?? searchWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            NSApp.sendAction(Selector(("newWindow:")), to: nil, from: nil)
        }
        NotificationCenter.default.post(name: .anyseekFocus, object: nil)
    }
    @MainActor private func performanceTest() async {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        func wait(_ condition: () -> Bool) async -> Bool {
            for _ in 0..<6000 {
                if condition() { return true }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return false
        }
        var table: NSTableView?
        let ready = await wait {
            table = NSApp.windows.compactMap(\.contentView).flatMap { descendants($0) }.compactMap { $0 as? NSTableView }.first
            return table?.numberOfRows == 1_000_000
        }
        guard ready, let table, let coordinator = table.dataSource as? FastResultsTable.Coordinator else {
            fputs("UI performance: million-row table did not become ready\n", stderr); exit(1)
        }
        table.selectRowIndexes(IndexSet(integer: 500000), byExtendingSelection: false)
        let selectedPath = coordinator.parent.files[500000].path
        for (key, ascending) in [("size", true), ("size", false), ("modified", true), ("modified", false), ("name", true)] {
            let generation = coordinator.generation, start = Date()
            table.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
            guard await wait({ coordinator.generation > generation }) else { fputs("UI sort timed out\n", stderr); exit(1) }
            guard await wait({
                table.selectedRowIndexes.count == 1 && table.selectedRow >= 0 && coordinator.parent.files[table.selectedRow].path == selectedPath
            }) else { fputs("UI selection restoration failed\n", stderr); exit(1) }
            table.layoutSubtreeIfNeeded(); table.displayIfNeeded()
            let rows = coordinator.parent.files
            guard rows.count == 1_000_000 else { exit(1) }
            if key == "size", let first = rows.first, let last = rows.last {
                guard ascending ? first.size <= last.size : first.size >= last.size else { exit(1) }
            }
            print("UI BENCHMARK 1000000: \(key) \(ascending ? "ascending" : "descending") click-to-table=\(Date().timeIntervalSince(start))s")
        }
        print("PASS: million-row native table column switching and reversal")
        NSApp.terminate(nil)
    }
    private func smokeTest() {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain }), let content = window.contentView else { fputs("UI smoke: missing search window\n", stderr); exit(1) }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        guard descendants(content).contains(where: { $0 is NSTableView }) else { fputs("UI smoke: missing results table\n", stderr); exit(1) }
        content.layoutSubtreeIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { exit(1) }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        do {
            let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/Anyseek-window.png")
            guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
            try png.write(to: url)
            print("PASS: macOS search window and native results table rendered")
            NSApp.terminate(nil)
        } catch { fputs("UI smoke: \(error)\n", stderr); exit(1) }
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
struct FilePreview: NSViewRepresentable {
    let path: String
    func makeNSView(context: Context) -> QLPreviewView { QLPreviewView(frame: .zero, style: .normal)! }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = NSURL(fileURLWithPath: path) }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}

/// Table-only key handling: typing spaces in the search field remains untouched.
struct ResultKeyHandler: NSViewRepresentable {
    let open: () -> Void
    let preview: () -> Void
    let copy: () -> Void
    let trash: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let actions = context.coordinator
        actions.open = open; actions.preview = preview; actions.copy = copy; actions.trash = trash
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] event in
            guard let window = view?.window, window == event.window,
                  !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField) else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 49 && modifiers.isEmpty { actions.preview(); return nil }
            if event.keyCode == 36 && modifiers.isEmpty { actions.open(); return nil }
            if event.keyCode == 8 && modifiers == .command { actions.copy(); return nil }
            if event.keyCode == 51 && modifiers == .command { actions.trash(); return nil }
            return event
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        let actions = context.coordinator
        actions.open = open; actions.preview = preview; actions.copy = copy; actions.trash = trash
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) } }
    final class Coordinator {
        var monitor: Any?
        var open: () -> Void = {}; var preview: () -> Void = {}; var copy: () -> Void = {}; var trash: () -> Void = {}
    }
}
