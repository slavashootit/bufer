import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// What to do with the chosen items.
struct PasteRequest {
    let items: [ClipItem]
    /// Drop formatting and paste plain text.
    let plain: Bool
    /// false: only put on the clipboard, do not press ⌘V.
    var pasteAfter = true
}

/// Puts items back on the pasteboard and presses ⌘V in the frontmost app.
@MainActor
enum Paster {
    /// Accessibility permission is required to post key events to other apps.
    static func hasAccess(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func write(_ items: [ClipItem], plain: Bool, store: Store) {
        guard let first = items.first else { return }
        let pb = NSPasteboard.general
        pb.clearContents()

        if items.count > 1 {
            // Several screenshots or files go as a list of files: one ⌘V inserts them all,
            // oldest first, so a series lands in the order it was taken.
            let urls = items.sorted { $0.created < $1.created }.flatMap { item -> [URL] in
                switch item.kind {
                case .image: return item.imagePath.map { [URL(fileURLWithPath: $0)] } ?? []
                case .files: return item.files.map { URL(fileURLWithPath: $0) }
                case .text: return []
                }
            }.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !urls.isEmpty, !plain {
                pb.writeObjects(urls.map { $0 as NSURL })
                return
            }
            // Otherwise several items paste as one text, one item per line.
            let text = items.compactMap { item -> String? in
                switch item.kind {
                case .text: return item.text
                case .files: return item.files.joined(separator: "\n")
                case .image: return nil
                }
            }.joined(separator: "\n")
            pb.setString(text, forType: .string)
            return
        }

        switch first.kind {
        case .text:
            pb.setString(first.text ?? "", forType: .string)
            if !plain && first.hasRichText {
                let rich = store.richText(first.id)
                if let rtf = rich.rtf { pb.setData(rtf, forType: .rtf) }
                if let html = rich.html { pb.setData(html, forType: .html) }
            }
        case .image:
            guard let path = first.imagePath,
                  let png = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
            pb.setData(png, forType: .png)
            if let tiff = NSImage(data: png)?.tiffRepresentation {
                pb.setData(tiff, forType: .tiff)
            }
        case .files:
            pb.writeObjects(first.files.map { URL(fileURLWithPath: $0) as NSURL })
        }
    }

    /// Key code of the physical V key. Cyrillic layouts route ⌘-shortcuts through
    /// the Latin layout, so this works with Ukrainian; Dvorak would need UCKeyTranslate.
    static func pressCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
