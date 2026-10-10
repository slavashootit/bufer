import AppKit
import ImageIO
import SwiftUI

struct PanelView: View {
    @ObservedObject var model: PanelModel
    let onPick: (Int, NSEvent.ModifierFlags) -> Void
    let menuFor: (ClipItem) -> NSMenu
    let dragItems: (ClipItem) -> [ClipItem]
    let onSettings: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(model: model, onSettings: onSettings)
            Divider()
            VStack(spacing: 0) {
                searchBar
                Divider()
                ZStack {
                    list
                    if model.previewing, let item = model.selected {
                        PreviewView(item: item)
                    }
                }
                Divider()
                Text("↩ вставити · ⌥↩ простим текстом · ⇧клік позначити · пробіл перегляд · ⇥ розділи · правий клік — ще")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(8)
            }
        }
        .frame(width: 720, height: 540)
        .background(.regularMaterial)
        .onAppear { searchFocused = true }
        .onChange(of: model.focusToken) { _, _ in searchFocused = true }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(model.searchPlaceholder, text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($searchFocused)
            if !model.marked.isEmpty {
                Text("позначено: \(model.marked.count)")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.25)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var list: some View {
        if model.items.isEmpty {
            VStack {
                Spacer()
                Text(model.query.isEmpty ? "Тут поки порожньо" : "Нічого не знайдено")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            ClipRow(item: item, index: index,
                                    isSelected: index == model.selection,
                                    isMarked: model.isMarked(item))
                                .id(item.id)
                                .overlay(DragClickArea(
                                    onClick: { flags in onPick(index, flags) },
                                    menu: { menuFor(item) },
                                    payload: { dragItems(item) }
                                ))
                        }
                    }
                    .padding(6)
                }
                .onChange(of: model.selection) { _, newValue in
                    if model.items.indices.contains(newValue) {
                        proxy.scrollTo(model.items[newValue].id)
                    }
                }
            }
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var model: PanelModel
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            entries
            Divider()
            Button(action: onSettings) {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                    Text("Налаштування")
                    Spacer()
                    Text("⌘,").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 180)
    }

    private var entries: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                SidebarRow(title: "Усе", symbol: "tray.full", count: nil,
                           isSelected: model.scope == .all) { model.scope = .all }
                SidebarRow(title: "Закріплені", symbol: "pin", count: model.pinnedCount,
                           isSelected: model.scope == .pinned) { model.scope = .pinned }

                header("Типи")
                ForEach(ClipCategory.allCases, id: \.self) { category in
                    if let count = model.counts[category], count > 0 {
                        SidebarRow(title: category.title, symbol: category.symbol, count: count,
                                   isSelected: model.scope == .category(category)) {
                            model.scope = .category(category)
                        }
                    }
                }

                if !model.apps.isEmpty {
                    header("Програми")
                    ForEach(model.apps) { app in
                        SidebarRow(title: app.name, appID: app.id, count: app.count,
                                   isSelected: model.scope == .app(app.id)) {
                            model.scope = .app(app.id)
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 12)
            .padding(.leading, 8)
            .padding(.bottom, 2)
    }
}

struct SidebarRow: View {
    let title: String
    var symbol: String? = nil
    var appID: String? = nil
    let count: Int?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Group {
                    if let appID {
                        AppIconView(bundleID: appID)
                    } else {
                        Image(systemName: symbol ?? "circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 16, height: 16)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let count {
                    Text("\(count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Rows

struct ClipRow: View {
    let item: ClipItem
    let index: Int
    let isSelected: Bool
    let isMarked: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AppIconView(bundleID: item.appID)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 4) {
                content
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 4) {
                if isMarked {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
                if item.pinned {
                    Image(systemName: "pin.fill").font(.caption)
                }
                if index < 9 {
                    Text("⌘\(index + 1)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
        )
    }

    @ViewBuilder private var content: some View {
        switch item.category {
        case .color:
            HStack(spacing: 8) {
                if let c = HexColor.parse(item.text ?? "") {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a))
                        .frame(width: 28, height: 18)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
                }
                Text(item.preview)
                    .font(.system(size: 13, design: .monospaced))
            }
        case .link:
            VStack(alignment: .leading, spacing: 2) {
                if let title = item.linkTitle, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                Text(item.preview)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.blue)
                    .lineLimit(2)
            }
        case .image:
            if let thumb = item.imagePath.flatMap(Thumbnails.thumb) {
                Image(nsImage: thumb.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 90, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Text("Зображення")
            }
        case .files:
            Label(item.preview, systemImage: "doc.on.doc")
                .font(.system(size: 13))
                .lineLimit(2)
        case .text:
            Text(item.preview)
                .font(.system(size: 13))
                .lineLimit(3)
        }
    }

    private var meta: String {
        var parts: [String] = []
        if let app = item.appName { parts.append(app) }
        switch item.kind {
        case .text:
            if item.category == .link,
               let host = URL(string: (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))?.host {
                parts.append(host)
            } else {
                parts.append("\((item.text ?? "").count) симв.")
            }
            if item.hasRichText { parts.append("з форматуванням") }
        case .image:
            if let size = item.imagePath.flatMap(Thumbnails.thumb)?.pixelSize {
                parts.append("\(Int(size.width))×\(Int(size.height))")
            }
            if let ocr = item.ocr, !ocr.isEmpty { parts.append("є текст") }
        case .files:
            parts.append("файлів: \(item.files.count)")
        }
        parts.append(Self.relative.localizedString(for: item.created, relativeTo: Date()))
        return parts.joined(separator: " · ")
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "uk_UA")
        f.unitsStyle = .short
        return f
    }()
}

// MARK: - Preview

/// Full view of the selected item over the list (Space or ⌘Y).
struct PreviewView: View {
    let item: ClipItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Перегляд").font(.headline)
                Spacer()
                Text("пробіл або Esc — закрити")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch item.kind {
                    case .text:
                        if item.category == .link, let title = item.linkTitle, !title.isEmpty {
                            Text(title).font(.title3.weight(.semibold))
                        }
                        Text(item.text ?? "")
                            .font(.system(size: 13, design: item.category == .color ? .monospaced : .default))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .image:
                        if let path = item.imagePath, let image = NSImage(contentsOfFile: path) {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity)
                        }
                        if let ocr = item.ocr, !ocr.isEmpty {
                            Text("Текст на зображенні")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(ocr)
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    case .files:
                        ForEach(item.files, id: \.self) { path in
                            Text(path)
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}

// MARK: - Icons and thumbnails

struct AppIconView: View {
    let bundleID: String?

    var body: some View {
        if let icon = bundleID.flatMap(AppIcons.icon) {
            Image(nsImage: icon).resizable()
        } else {
            Image(systemName: "doc.on.clipboard").foregroundStyle(.secondary)
        }
    }
}

/// Small decoded thumbnails, so big screenshots are not decoded at full size for the list.
enum Thumbnails {
    final class Thumb {
        let image: NSImage
        let pixelSize: CGSize
        init(image: NSImage, pixelSize: CGSize) {
            self.image = image
            self.pixelSize = pixelSize
        }
    }

    private static let cache = NSCache<NSString, Thumb>()

    static func thumb(_ path: String) -> Thumb? {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
            return nil
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 360,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let thumb = Thumb(image: NSImage(cgImage: cg, size: .zero),
                          pixelSize: CGSize(width: width, height: height))
        cache.setObject(thumb, forKey: path as NSString)
        return thumb
    }
}

enum AppIcons {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(_ bundleID: String) -> NSImage? {
        if let cached = cache.object(forKey: bundleID as NSString) { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: bundleID as NSString)
        return icon
    }
}
