import AppKit
import Carbon.HIToolbox
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var store: Store!
    private var monitor: ClipboardMonitor!
    private var panel: PanelController!
    private var enricher: Enricher!
    private var settings: SettingsWindowController!
    private var showHotKey: HotKey?
    private var plainHotKey: HotKey?
    private var retentionTimer: Timer?
    private var statusItem: NSStatusItem!
    private var pauseItem: NSMenuItem!
    private var showItem: NSMenuItem?
    private var savesSinceCleanup = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            store = try Store()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Bufer не зміг відкрити базу історії"
            alert.informativeText = String(describing: error)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        applyRetention()

        let model = PanelModel(store: store)
        panel = PanelController(model: model) { [weak self] request in
            guard let self else { return }
            self.execute(request, target: self.panel.targetApp)
        }
        panel.onOpenSettings = { [weak self] in self?.settings.show() }

        enricher = Enricher(store: store) { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.panel.model.reload()
        }

        monitor = ClipboardMonitor { [weak self] capture in
            self?.didCapture(capture)
        }
        monitor.start(interval: Prefs.pollInterval)

        setUpSettings()
        setUpStatusItem()
        registerHotKeys(warnIfTaken: true)
        _ = Paster.hasAccess(prompt: true)

        // Age-based cleanup also has to run while Bufer just sits in the menu bar.
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyRetention() }
        }
        RunLoop.main.add(timer, forMode: .common)
        retentionTimer = timer
    }

    // MARK: - Settings

    private func setUpSettings() {
        let model = SettingsModel()
        model.onHistoryRulesChanged = { [weak self] in
            self?.applyRetention()
            self?.panel.model.reload()
        }
        model.onStatusIconChanged = { [weak self] in
            self?.statusItem.isVisible = Prefs.showStatusIcon
        }
        model.onPollIntervalChanged = { [weak self] in
            self?.monitor.start(interval: Prefs.pollInterval)
        }
        model.onShortcutsChanged = { [weak self] in
            self?.registerHotKeys(warnIfTaken: false)
        }
        model.onOpenDataFolder = { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.store.baseURL)
        }
        model.onClearHistory = { [weak self] in
            self?.clearHistory()
        }
        settings = SettingsWindowController(model: model)
    }

    /// Unpinned items beyond the limit or older than the max age are removed.
    private func applyRetention() {
        if Prefs.historyLimit > 0 {
            store.prune(keep: Prefs.historyLimit)
        }
        if Prefs.maxAgeDays > 0 {
            store.prune(olderThan: Date().addingTimeInterval(-Double(Prefs.maxAgeDays) * 86_400))
        }
    }

    // MARK: - Hotkeys

    private func registerHotKeys(warnIfTaken: Bool) {
        showHotKey?.unregister()
        plainHotKey?.unregister()

        // Show: tap keeps the panel open (click pastes), hold keeps it open only while held.
        let show = Prefs.showShortcut
        showHotKey = HotKey(
            keyCode: show.keyCode, modifiers: show.modifiers, id: 1,
            onPress: { [weak self] in self?.hotKeyPressed() },
            onRelease: { [weak self] in self?.hotKeyReleased() }
        )
        // Plain paste of the latest item, no panel. Fires on release so the held
        // modifiers do not mix into the posted ⌘V.
        let plain = Prefs.plainShortcut
        plainHotKey = HotKey(
            keyCode: plain.keyCode, modifiers: plain.modifiers, id: 2,
            onPress: {},
            onRelease: { [weak self] in self?.pasteLatestPlain() }
        )

        var problems: [String] = []
        if showHotKey?.isRegistered != true {
            problems.append("\(show.label) уже зайняте іншою програмою")
        }
        if plainHotKey?.isRegistered != true {
            problems.append("\(plain.label) уже зайняте іншою програмою")
        }
        settings.model.shortcutProblem = problems.isEmpty ? nil : problems.joined(separator: "\n")
        showItem?.title = "Показати історію (\(show.label))"

        if warnIfTaken && showHotKey?.isRegistered != true {
            warnHotKeyTaken(show.label)
        }
    }

    /// Shorter than this counts as a tap, longer as a hold.
    private static let holdThreshold: TimeInterval = 0.35
    private var hotKeyPressDate: Date?

    private func hotKeyPressed() {
        // Key auto-repeat while holding sends extra presses: ignore them.
        guard hotKeyPressDate == nil else { return }
        if panel.isVisible {
            panel.hide()
            return
        }
        hotKeyPressDate = Date()
        panel.show()
        panel.model.hotKeyHeld = true
    }

    private func hotKeyReleased() {
        panel.model.hotKeyHeld = false
        guard let pressed = hotKeyPressDate else { return }
        hotKeyPressDate = nil
        if Date().timeIntervalSince(pressed) >= Self.holdThreshold {
            panel.hideWhenDragEnds()
        }
    }

    // MARK: - Capture and paste

    private func didCapture(_ capture: Capture) {
        guard let saved = store.save(capture) else { return }
        if saved.isNew {
            switch capture.category {
            case .image:
                if let path = saved.imagePath {
                    enricher.recognizeText(id: saved.id, imageURL: URL(fileURLWithPath: path))
                }
            case .link:
                if let text = capture.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                   let url = URL(string: text) {
                    enricher.fetchTitle(id: saved.id, url: url)
                }
            case .text, .files, .color:
                break
            }
        }
        if panel.isVisible { panel.model.reload() }
        savesSinceCleanup += 1
        if savesSinceCleanup >= 200 {
            savesSinceCleanup = 0
            applyRetention()
        }
    }

    private func pasteLatestPlain() {
        guard let latest = store.fetch(query: "", scope: .all, limit: 1).first else { return }
        execute(PasteRequest(items: [latest], plain: true),
                target: NSWorkspace.shared.frontmostApplication)
    }

    private func execute(_ request: PasteRequest, target: NSRunningApplication?) {
        Paster.write(request.items, plain: request.plain, store: store)
        monitor.skipCurrentChange()
        for item in request.items { store.touch(item.id) }
        guard request.pasteAfter else { return }
        let trusted = Paster.hasAccess(prompt: false)
        Log.info("paste \(request.items.count) item(s), plain \(request.plain), accessibility \(trusted ? "yes" : "no"), target \(target?.bundleIdentifier ?? "none")")
        // Without Accessibility the item is just copied; ⌘V by hand still works.
        guard trusted else {
            warnNoAccessibility()
            return
        }
        // The panel is already hidden and Bufer deactivated, so focus is on its way back
        // to the app you were typing in. Nudge it, wait for the switch, then press ⌘V there.
        if NSApp.isActive { NSApp.hide(nil) }
        target?.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
            Log.info("posting Cmd+V, frontmost \(front)")
            Paster.pressCommandV()
        }
    }

    // MARK: - Alerts

    private var warnedNoAccessibility = false

    /// Once per launch: explain why the click only copied.
    private func warnNoAccessibility() {
        guard !warnedNoAccessibility else { return }
        warnedNoAccessibility = true
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Запис скопійовано, але не вставлено"
        alert.informativeText = "Для вставки по кліку Bufer потрібен дозвіл Accessibility. "
            + "Якщо Bufer уже є в списку, видали його кнопкою «−» і додай знову: "
            + "після перескладання macOS вважає його новою програмою. "
            + "Поки що натисни ⌘V сам."
        alert.addButton(withTitle: "Відкрити налаштування")
        alert.addButton(withTitle: "Пізніше")
        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    private func warnHotKeyTaken(_ label: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "\(label) уже зайняте іншою програмою"
        alert.informativeText = "Найчастіше це інший менеджер буфера (Pasta, PasteNow, Paste, Raycast). "
            + "Вимкни в ньому це сполучення або вибери інше в налаштуваннях Bufer. "
            + "Історію можна відкрити й з іконки в меню-барі."
        alert.addButton(withTitle: "Налаштування")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            settings.show()
        }
    }

    private func clearHistory() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Очистити історію?"
        alert.informativeText = "Закріплені записи залишаться. Скасувати це не можна."
        alert.addButton(withTitle: "Очистити")
        alert.addButton(withTitle: "Скасувати")
        if alert.runModal() == .alertFirstButtonReturn {
            store.clearUnpinned()
            panel.model.reload()
        }
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard",
                                           accessibilityDescription: "Bufer")

        let menu = NSMenu()
        menu.delegate = self
        let show = item("Показати історію (\(Prefs.showShortcut.label))", #selector(showPanel))
        showItem = show
        menu.addItem(show)
        pauseItem = item("Пауза запису", #selector(togglePause))
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        let settingsItem = item("Налаштування…", #selector(openSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(item("Дозвіл на вставку (Accessibility)…", #selector(openAccessibilitySettings)))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Вийти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.isVisible = Prefs.showStatusIcon
    }

    /// Launching Bufer again (Spotlight, Finder) opens settings: the way back in
    /// when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return true
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        pauseItem.state = monitor.isPaused ? .on : .off
    }

    @objc private func showPanel() {
        panel.show()
    }

    @objc private func openSettings() {
        settings.show()
    }

    @objc private func togglePause() {
        monitor.isPaused.toggle()
        statusItem.button?.appearsDisabled = monitor.isPaused
    }

    @objc private func openAccessibilitySettings() {
        _ = Paster.hasAccess(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
