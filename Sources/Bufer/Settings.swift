import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// State behind the settings window; every change is written to Prefs right away.
@MainActor
final class SettingsModel: ObservableObject {
    /// True while reload() copies Prefs in, so side effects do not fire.
    private var loading = false

    @Published var launchAtLogin = false {
        didSet {
            guard !loading, launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                Log.info("launch at login failed: \(error)")
            }
        }
    }
    @Published var panelAtCursor = true { didSet { Prefs.panelAtCursor = panelAtCursor } }
    @Published var showStatusIcon = true {
        didSet { Prefs.showStatusIcon = showStatusIcon; if !loading { onStatusIconChanged() } }
    }
    @Published var plainTextByDefault = false { didSet { Prefs.plainTextByDefault = plainTextByDefault } }
    @Published var recognizeText = true { didSet { Prefs.recognizeText = recognizeText } }
    @Published var fetchLinkTitles = true { didSet { Prefs.fetchLinkTitles = fetchLinkTitles } }
    @Published var historyLimit = 20_000 {
        didSet { Prefs.historyLimit = historyLimit; if !loading { onHistoryRulesChanged() } }
    }
    @Published var maxAgeDays = 0 {
        didSet { Prefs.maxAgeDays = maxAgeDays; if !loading { onHistoryRulesChanged() } }
    }
    @Published var pollInterval = 0.5 {
        didSet { Prefs.pollInterval = pollInterval; if !loading { onPollIntervalChanged() } }
    }
    @Published var showShortcut = Shortcut.showDefault {
        didSet { Prefs.showShortcut = showShortcut; if !loading { onShortcutsChanged() } }
    }
    @Published var plainShortcut = Shortcut.plainDefault {
        didSet { Prefs.plainShortcut = plainShortcut; if !loading { onShortcutsChanged() } }
    }
    @Published var excludedApps: [String] = [] { didSet { Prefs.excludedApps = excludedApps } }
    /// Set by AppDelegate when a shortcut could not be registered.
    @Published var shortcutProblem: String?

    var onHistoryRulesChanged: () -> Void = {}
    var onPollIntervalChanged: () -> Void = {}
    var onStatusIconChanged: () -> Void = {}
    var onShortcutsChanged: () -> Void = {}
    var onOpenDataFolder: () -> Void = {}
    var onClearHistory: () -> Void = {}

    /// Re-read everything, e.g. after the context menu excluded an app.
    func reload() {
        loading = true
        defer { loading = false }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        panelAtCursor = Prefs.panelAtCursor
        showStatusIcon = Prefs.showStatusIcon
        plainTextByDefault = Prefs.plainTextByDefault
        recognizeText = Prefs.recognizeText
        fetchLinkTitles = Prefs.fetchLinkTitles
        historyLimit = Prefs.historyLimit
        maxAgeDays = Prefs.maxAgeDays
        pollInterval = Prefs.pollInterval
        showShortcut = Prefs.showShortcut
        plainShortcut = Prefs.plainShortcut
        excludedApps = Prefs.excludedApps
    }

    func addExcludedApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.prompt = "Не записувати"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !excludedApps.contains(id) {
                excludedApps.append(id)
            }
        }
    }
}

@MainActor
final class SettingsWindowController {
    let model: SettingsModel
    private var window: NSWindow?

    init(model: SettingsModel) {
        self.model = model
    }

    func show() {
        model.reload()
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Налаштування Bufer"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.center()
            self.window = window
        }
        // The panel hides the whole app when it closes; bring it back first.
        NSApp.unhide(nil)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Views

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("Загальні", systemImage: "gearshape") }
            ShortcutSettings(model: model)
                .tabItem { Label("Клавіші", systemImage: "keyboard") }
            HistorySettings(model: model)
                .tabItem { Label("Історія", systemImage: "clock") }
            ExclusionSettings(model: model)
                .tabItem { Label("Виключення", systemImage: "nosign") }
        }
        .padding(16)
        .frame(width: 560, height: 420)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Toggle("Запускати при вході в систему", isOn: $model.launchAtLogin)
            Toggle("Показувати іконку в меню-барі", isOn: $model.showStatusIcon)
            if !model.showStatusIcon {
                Text("Налаштування відкриваються шестернею у вікні історії, ⌘, або повторним запуском Bufer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker("Де показувати вікно", selection: $model.panelAtCursor) {
                Text("Біля курсора").tag(true)
                Text("По центру екрана").tag(false)
            }
            Toggle("Завжди вставляти простим текстом", isOn: $model.plainTextByDefault)
            Text("⌥ під час вставки робить навпаки.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Розпізнавати текст на картинках", isOn: $model.recognizeText)
            Toggle("Підтягувати назви посилань", isOn: $model.fetchLinkTitles)
            Text("Для назви Bufer звертається до сайту за кожним скопійованим посиланням.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutSettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            LabeledContent("Показати історію") {
                ShortcutRecorder(shortcut: $model.showShortcut)
            }
            LabeledContent("Вставити останнє простим текстом") {
                ShortcutRecorder(shortcut: $model.plainShortcut)
            }
            if let problem = model.shortcutProblem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(Color.red)
            }
            Text("Клацни сполучення й натисни нове. Потрібен хоча б один із ⌘ ⌃ ⌥. Esc скасовує.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Повернути стандартні") {
                model.showShortcut = .showDefault
                model.plainShortcut = .plainDefault
            }
        }
        .formStyle(.grouped)
    }
}

private struct HistorySettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Picker("Скільки записів зберігати", selection: $model.historyLimit) {
                Text("1 000").tag(1_000)
                Text("5 000").tag(5_000)
                Text("20 000").tag(20_000)
                Text("50 000").tag(50_000)
                Text("Без обмежень").tag(0)
            }
            Picker("Видаляти старіші за", selection: $model.maxAgeDays) {
                Text("Ніколи").tag(0)
                Text("1 день").tag(1)
                Text("1 тиждень").tag(7)
                Text("1 місяць").tag(30)
                Text("3 місяці").tag(90)
                Text("1 рік").tag(365)
            }
            Text("Закріплені записи не видаляються ніколи.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Перевіряти буфер", selection: $model.pollInterval) {
                Text("4 рази на секунду").tag(0.25)
                Text("2 рази на секунду").tag(0.5)
                Text("Раз на секунду").tag(1.0)
            }
            HStack {
                Button("Відкрити теку з даними") { model.onOpenDataFolder() }
                Spacer()
                Button("Очистити історію…") { model.onClearHistory() }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ExclusionSettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                if model.excludedApps.isEmpty {
                    Text("Порожньо. Додай програму кнопкою нижче або правим кліком по її запису в історії.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.excludedApps, id: \.self) { id in
                    HStack(spacing: 8) {
                        AppIconView(bundleID: id)
                            .frame(width: 18, height: 18)
                        Text(Self.name(for: id))
                        Spacer()
                        Button {
                            model.excludedApps.removeAll { $0 == id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Копіювання з цих програм не записується")
            } footer: {
                Text("Паролі з 1Password, Bitwarden, Keychain і Passwords не записуються ніколи.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Додати програму…") { model.addExcludedApp() }
        }
        .formStyle(.grouped)
    }

    private static func name(for bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
    }
}

/// Click, then press the new combination. Esc cancels.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    @StateObject private var recorder = KeyRecorder()

    var body: some View {
        Button(recorder.isRecording ? "Натисни сполучення…" : shortcut.label) {
            if recorder.isRecording {
                recorder.stop()
            } else {
                recorder.start { new in shortcut = new }
            }
        }
        .frame(minWidth: 150)
        .onDisappear { recorder.stop() }
    }
}

/// Listens for the next key press in the settings window.
@MainActor
final class KeyRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    private var monitor: Any?
    private var onRecord: ((Shortcut) -> Void)?

    func start(onRecord: @escaping (Shortcut) -> Void) {
        stop()
        self.onRecord = onRecord
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onRecord = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape {
            stop()
            return
        }
        if let new = Shortcut(event: event) {
            onRecord?(new)
            stop()
        }
    }
}
