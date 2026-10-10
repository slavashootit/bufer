import AppKit

@main
struct BuferMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu bar only: no Dock icon, no main menu.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
