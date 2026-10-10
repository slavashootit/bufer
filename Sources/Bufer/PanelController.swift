import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Floating panel that can take keyboard focus for the search field.
final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelModel: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { selection = 0; reload() } }
    }
    @Published var scope: ClipScope = .all {
        didSet { if scope != oldValue { selection = 0; reload() } }
    }
    @Published private(set) var items: [ClipItem] = []
    @Published var selection = 0
    /// Items picked with ⇧-click, in the order they were picked.
    @Published var marked: [ClipItem] = []
    @Published var previewing = false
    /// Bumped on every show so the view re-focuses the search field.
    @Published var focusToken = 0
    @Published private(set) var apps: [AppGroup] = []
    @Published private(set) var counts: [ClipCategory: Int] = [:]
    @Published private(set) var pinnedCount = 0
    /// ⌘⇧V is physically held, so ⇧ in clicks and arrows comes from the hotkey, not the user.
    var hotKeyHeld = false

    let store: Store

    init(store: Store) {
        self.store = store
    }

    var selected: ClipItem? {
        items.indices.contains(selection) ? items[selection] : nil
    }

    var searchPlaceholder: String {
        switch scope {
        case .all: return "Пошук"
        case .pinned: return "Пошук у закріплених"
        case .category(let category): return "Пошук: \(category.title.lowercased())"
        case .app(let id): return "Пошук у \(apps.first { $0.id == id }?.name ?? "програмі")"
        }
    }

    /// Sidebar entries in display order, for ⇥ / ⇧⇥ cycling.
    var scopes: [ClipScope] {
        let categories = ClipCategory.allCases
            .filter { (counts[$0] ?? 0) > 0 }
            .map { ClipScope.category($0) }
        return [ClipScope.all, ClipScope.pinned] + categories + apps.map { ClipScope.app($0.id) }
    }

    func reload() {
        items = store.fetch(query: query, scope: scope)
        apps = store.apps()
        counts = store.categoryCounts()
        pinnedCount = store.pinnedCount()
        if selection >= items.count { selection = max(0, items.count - 1) }
        if items.isEmpty { previewing = false }
    }

    func reset() {
        query = ""
        scope = .all
        selection = 0
        marked = []
        previewing = false
        reload()
        focusToken += 1
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selection = min(max(selection + delta, 0), items.count - 1)
    }

    func cycleScope(_ delta: Int) {
        let list = scopes
        guard !list.isEmpty else { return }
        let index = list.firstIndex(of: scope) ?? 0
        scope = list[(index + delta + list.count) % list.count]
    }

    func isMarked(_ item: ClipItem) -> Bool {
        marked.contains { $0.id == item.id }
    }

    func toggleMark(_ item: ClipItem) {
        if let index = marked.firstIndex(where: { $0.id == item.id }) {
            marked.remove(at: index)
        } else {
            marked.append(item)
        }
    }

    func markSelected() {
        if let item = selected, !isMarked(item) { marked.append(item) }
    }

    func togglePin(_ item: ClipItem) {
        store.setPinned(item.id, !item.pinned)
        reload()
    }

    func delete(_ item: ClipItem) {
        store.delete(item.id)
        marked.removeAll { $0.id == item.id }
        reload()
    }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let model: PanelModel
    private let panel: Panel
    private let onPaste: (PasteRequest) -> Void
    private var keyMonitor: Any?
    /// ⌘, inside the panel.
    var onOpenSettings: () -> Void = {}

    init(model: PanelModel, onPaste: @escaping (PasteRequest) -> Void) {
        self.model = model
        self.onPaste = onPaste
        panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: PanelView(
            model: model,
            onPick: { [weak self] index, flags in self?.handleClick(at: index, flags: flags) },
            menuFor: { [weak self] item in self?.contextMenu(for: item) ?? NSMenu() },
            dragItems: { [weak self] item in self?.dragItems(for: item) ?? [item] },
            onSettings: { [weak self] in
                self?.hide()
                self?.onOpenSettings()
            }
        ))

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        }
    }

    var isVisible: Bool { panel.isVisible }

    /// App that was frontmost when the panel opened: the paste target.
    private(set) var targetApp: NSRunningApplication?

    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            targetApp = front
        }
        model.reset()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let size = panel.frame.size
        var origin = NSPoint(x: mouse.x - 20, y: mouse.y - size.height - 12)
        if !Prefs.panelAtCursor, let visible = screen?.visibleFrame {
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        }
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)
        // Bufer becomes the active app while the panel is open. When it hides again,
        // macOS hands focus back to the previous app's window and text cursor,
        // which a non-activating panel alone does not reliably do.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    private var isHiding = false

    func hide() {
        // orderOut triggers windowDidResignKey, which calls hide() again.
        guard !isHiding else { return }
        isHiding = true
        defer { isHiding = false }
        dragWaitTimer?.invalidate()
        dragWaitTimer = nil
        panel.orderOut(nil)
        // Return focus to the app you came from (no-op if you already clicked elsewhere).
        if NSApp.isActive { NSApp.hide(nil) }
    }

    private var dragWaitTimer: Timer?

    /// Hides now, or after the mouse button is released if an item is being dragged,
    /// so a drag started from the panel can still be dropped.
    func hideWhenDragEnds() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            hide()
            return
        }
        dragWaitTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSEvent.pressedMouseButtons & 1 == 0 else { return }
                self.hide()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragWaitTimer = timer
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    // MARK: - Actions

    /// ⌥ flips the "plain text by default" setting for this paste.
    private func wantsPlain(_ flags: NSEvent.ModifierFlags) -> Bool {
        Prefs.plainTextByDefault != flags.contains(.option)
    }

    private func paste(_ items: [ClipItem], plain: Bool, pasteAfter: Bool = true) {
        guard !items.isEmpty else { return }
        model.marked = []
        hide()
        onPaste(PasteRequest(items: items, plain: plain, pasteAfter: pasteAfter))
    }

    /// Marked items if any, otherwise the selected one.
    private var chosenItems: [ClipItem] {
        if !model.marked.isEmpty { return model.marked }
        return model.selected.map { [$0] } ?? []
    }

    private func handleClick(at index: Int, flags: NSEvent.ModifierFlags) {
        guard model.items.indices.contains(index) else { return }
        let item = model.items[index]
        if flags.contains(.shift) && !model.hotKeyHeld {
            model.selection = index
            model.toggleMark(item)
            return
        }
        paste([item], plain: wantsPlain(flags))
    }

    private func dragItems(for item: ClipItem) -> [ClipItem] {
        model.isMarked(item) ? model.marked : [item]
    }

    private func contextMenu(for item: ClipItem) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ActionMenuItem("Вставити", symbol: "arrow.down.doc") { [weak self] in
            self?.paste([item], plain: false)
        })
        if item.kind == .text {
            menu.addItem(ActionMenuItem("Вставити простим текстом", symbol: "textformat") { [weak self] in
                self?.paste([item], plain: true)
            })
        }
        menu.addItem(ActionMenuItem("Скопіювати", symbol: "doc.on.doc") { [weak self] in
            self?.paste([item], plain: false, pasteAfter: false)
        })
        menu.addItem(ActionMenuItem("Переглянути", symbol: "eye") { [weak self] in
            guard let self, let index = self.model.items.firstIndex(where: { $0.id == item.id }) else { return }
            self.model.selection = index
            self.model.previewing = true
        })
        menu.addItem(ActionMenuItem(item.pinned ? "Відкріпити" : "Закріпити", symbol: "pin") { [weak self] in
            self?.model.togglePin(item)
        })
        if item.category == .link,
           let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: text) {
            menu.addItem(ActionMenuItem("Відкрити посилання", symbol: "safari") { [weak self] in
                self?.hide()
                NSWorkspace.shared.open(url)
            })
        }
        let fileURLs: [URL]
        switch item.kind {
        case .image: fileURLs = item.imagePath.map { [URL(fileURLWithPath: $0)] } ?? []
        case .files: fileURLs = item.files.map { URL(fileURLWithPath: $0) }
        case .text: fileURLs = []
        }
        if !fileURLs.isEmpty {
            menu.addItem(ActionMenuItem("Показати у Finder", symbol: "folder") { [weak self] in
                self?.hide()
                NSWorkspace.shared.activateFileViewerSelecting(fileURLs)
            })
        }
        menu.addItem(.separator())
        if let appID = item.appID {
            let name = item.appName ?? appID
            menu.addItem(ActionMenuItem("Не записувати з «\(name)»", symbol: "nosign") {
                if !Prefs.excludedApps.contains(appID) {
                    Prefs.excludedApps.append(appID)
                }
            })
        }
        menu.addItem(ActionMenuItem("Видалити", symbol: "trash") { [weak self] in
            self?.model.delete(item)
        })
        return menu
    }

    /// Returns true when the key was consumed; everything else goes to the search field.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard panel.isKeyWindow else { return false }
        let flags = event.modifierFlags
        let command = flags.contains(.command)
        let shift = flags.contains(.shift) && !model.hotKeyHeld

        switch Int(event.keyCode) {
        case kVK_Escape:
            if model.previewing {
                model.previewing = false
            } else if !model.marked.isEmpty {
                model.marked = []
            } else {
                hide()
            }
        case kVK_DownArrow:
            if shift { model.markSelected() }
            model.move(1)
            if shift { model.markSelected() }
        case kVK_UpArrow:
            if shift { model.markSelected() }
            model.move(-1)
            if shift { model.markSelected() }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            paste(chosenItems, plain: wantsPlain(flags))
        case kVK_Tab:
            model.cycleScope(flags.contains(.shift) ? -1 : 1)
        case kVK_Space where model.query.isEmpty && !command:
            model.previewing.toggle()
        case kVK_ANSI_Y where command:
            model.previewing.toggle()
        case kVK_ANSI_C where command && model.query.isEmpty:
            paste(chosenItems, plain: false, pasteAfter: false)
        case kVK_ANSI_Comma where command:
            hide()
            onOpenSettings()
        case kVK_ANSI_P where command:
            if let item = model.selected { model.togglePin(item) }
        case kVK_Delete where command:
            if let item = model.selected { model.delete(item) }
        default:
            // ⌘1…⌘9 pastes the n-th visible item.
            if command, let chars = event.charactersIgnoringModifiers,
               let n = Int(chars), (1...9).contains(n), model.items.indices.contains(n - 1) {
                paste([model.items[n - 1]], plain: wantsPlain(flags))
                return true
            }
            return false
        }
        return true
    }
}
