import AppKit
import SwiftUI

/// Transparent overlay on a history row: click pastes, right-click opens a menu,
/// drag carries the item (or all marked items) into another app.
/// Drag is done in AppKit because SwiftUI's `onDrag` lets held modifier keys (⌘ from ⌘⇧V)
/// narrow the drag operation, and drop targets then refuse the item.
struct DragClickArea: NSViewRepresentable {
    let onClick: (NSEvent.ModifierFlags) -> Void
    let menu: () -> NSMenu?
    let payload: () -> [ClipItem]

    func makeNSView(context: Context) -> DragClickView {
        let view = DragClickView()
        update(view)
        return view
    }

    func updateNSView(_ view: DragClickView, context: Context) {
        update(view)
    }

    private func update(_ view: DragClickView) {
        view.onClick = onClick
        view.menuProvider = menu
        view.payload = payload
    }
}

final class DragClickView: NSView, NSDraggingSource {
    var onClick: ((NSEvent.ModifierFlags) -> Void)?
    var menuProvider: (() -> NSMenu?)?
    var payload: (() -> [ClipItem])?
    private var mouseDownEvent: NSEvent?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // ⌃-click is the same as a right-click on the Mac.
        if event.modifierFlags.contains(.control) {
            showMenu(for: event)
            return
        }
        mouseDownEvent = event
    }

    override func rightMouseDown(with event: NSEvent) {
        showMenu(for: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard hypot(dx, dy) > 4 else { return }
        mouseDownEvent = nil
        let items = draggingItems()
        guard !items.isEmpty else { return }
        beginDraggingSession(with: items, event: down, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownEvent != nil else { return }
        mouseDownEvent = nil
        onClick?(event.modifierFlags)
    }

    private func showMenu(for event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic] : []
    }

    /// Held ⌘⇧ must not change what the drop target is offered.
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    // MARK: Payload

    private func draggingItems() -> [NSDraggingItem] {
        let items = payload?() ?? []
        var writers: [NSPasteboardWriting] = []
        for item in items {
            switch item.kind {
            case .text:
                writers.append((item.text ?? "") as NSString)
            case .image:
                // A PNG file URL: chats and upload fields accept it as an image file.
                if let path = item.imagePath {
                    writers.append(URL(fileURLWithPath: path) as NSURL)
                }
            case .files:
                writers += item.files.map { URL(fileURLWithPath: $0) as NSURL }
            }
        }
        let image = snapshot()
        return writers.map { writer in
            let dragging = NSDraggingItem(pasteboardWriter: writer)
            dragging.setDraggingFrame(bounds, contents: image)
            return dragging
        }
    }

    /// Picture of the row under this overlay, used as the drag image.
    private func snapshot() -> NSImage {
        guard let content = window?.contentView else { return NSImage(size: bounds.size) }
        let rect = convert(bounds, to: content)
        guard let rep = content.bitmapImageRepForCachingDisplay(in: rect) else {
            return NSImage(size: bounds.size)
        }
        content.cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }
}
