import AppKit
import SwiftUI

final class MenuCommand: NSMenuItem {
    private let actionBody: () -> Void
    init(_ title: String, checked: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
        actionBody = action
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self; state = checked ? .on : .off; isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { actionBody() }
}
struct NativeMenuBar: NSViewRepresentable {
    let menus: [NSMenu]
    func makeNSView(context: Context) -> MenuStrip { MenuStrip() }
    func updateNSView(_ view: MenuStrip, context: Context) { view.menus = menus; view.needsDisplay = true }
}
final class MenuStrip: NSView {
    var menus: [NSMenu] = []
    private var active: Int?
    private var switching: Int?
    private var timer: Timer?
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 24) }
    func frames() -> [NSRect] {
        var x: CGFloat = 4
        return menus.map { menu in
            let width = (menu.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width + 15
            defer { x += width }; return NSRect(x: x, y: 1, width: width, height: 22)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        for (i, frame) in frames().enumerated() {
            if active == i { NSColor.selectedMenuItemColor.setFill(); frame.fill() }
            (menus[i].title as NSString).draw(at: NSPoint(x: frame.minX + 7, y: frame.midY - 7), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: active == i ? NSColor.selectedMenuItemTextColor : NSColor.labelColor])
        }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = frames().firstIndex(where: { $0.contains(point) }) else { return }
        show(index)
    }
    private func show(_ index: Int) {
        guard menus.indices.contains(index), window != nil else { return }
        active = index; switching = nil; needsDisplay = true
        let menu = menus[index]
        // Native menu tracking runs its own run loop. Poll in that mode so
        // sibling menu hover keeps working while the dropdown owns the mouse.
        let timer = Timer(timeInterval: 0.025, repeats: true) { [weak self, weak menu] _ in
            guard let self, let window = self.window, self.switching == nil else { return }
            let point = self.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            guard let next = self.frames().firstIndex(where: { $0.contains(point) }), next != self.active else { return }
            self.switching = next; menu?.cancelTracking()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .eventTracking)
        let frame = frames()[index]
        menu.popUp(positioning: nil, at: NSPoint(x: frame.minX, y: frame.minY), in: self)
        timer.invalidate(); self.timer = nil
        let next = switching
        active = nil; switching = nil; needsDisplay = true
        if let next { DispatchQueue.main.async { [weak self] in self?.show(next) } }
    }
}
