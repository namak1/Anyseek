import AppKit
import Carbon
import QuickLookUI
import SwiftUI

extension Notification.Name {
    static let anyseekFocus = Notification.Name("anyseek.focus")
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    func applicationDidFinishLaunching(_ notification: Notification) {
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
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NSApp.sendAction(Selector(("newWindow:")), to: nil, from: nil)
        }
        NotificationCenter.default.post(name: .anyseekFocus, object: nil)
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
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] event in
            guard let window = view?.window, window == event.window,
                  !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField) else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 49 && modifiers.isEmpty { preview(); return nil }
            if event.keyCode == 36 && modifiers.isEmpty { open(); return nil }
            if event.keyCode == 8 && modifiers == .command { copy(); return nil }
            if event.keyCode == 51 && modifiers == .command { trash(); return nil }
            return event
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) } }
    final class Coordinator { var monitor: Any? }
}
