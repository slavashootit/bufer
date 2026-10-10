import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum ClipKind: Int {
    case text = 0
    case image = 1
    case files = 2
}

/// What the sidebar groups by. Links and colors are text with a recognizable shape.
enum ClipCategory: Int, CaseIterable {
    case text = 0
    case link = 1
    case image = 2
    case files = 3
    case color = 4

    var title: String {
        switch self {
        case .text: return "Текст"
        case .link: return "Посилання"
        case .image: return "Зображення"
        case .files: return "Файли"
        case .color: return "Кольори"
        }
    }

    var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .image: return "photo"
        case .files: return "doc.on.doc"
        case .color: return "paintpalette"
        }
    }

    static func of(text: String) -> ClipCategory {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if HexColor.parse(t) != nil { return .color }
        if !t.contains(where: { $0.isWhitespace }),
           let url = URL(string: t), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https", url.host != nil {
            return .link
        }
        return .text
    }
}

/// `#RGB`, `#RRGGBB` or `#RRGGBBAA`.
enum HexColor {
    static func parse(_ string: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("#") else { return nil }
        var hex = String(s.dropFirst())
        guard [3, 6, 8].contains(hex.count), hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard let value = UInt64(hex, radix: 16) else { return nil }
        if hex.count == 8 {
            return (Double((value >> 24) & 0xFF) / 255, Double((value >> 16) & 0xFF) / 255,
                    Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
        }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255,
                Double(value & 0xFF) / 255, 1)
    }
}

/// Sidebar selection.
enum ClipScope: Hashable {
    case all
    case pinned
    case category(ClipCategory)
    case app(String)
}

struct AppGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let count: Int
}

/// Fresh clipboard content read by the monitor, not yet stored.
struct Capture {
    let kind: ClipKind
    let category: ClipCategory
    var text: String? = nil
    var rtf: Data? = nil
    var html: Data? = nil
    var imageData: Data? = nil
    var files: [String] = []
    let appID: String?
    let appName: String?
    let hash: String
}

struct SaveResult {
    let id: Int64
    let isNew: Bool
    let imagePath: String?
}

/// Stored history row. Rich text data is loaded only when pasting.
struct ClipItem: Identifiable {
    let id: Int64
    let kind: ClipKind
    let category: ClipCategory
    let text: String?
    let imagePath: String?
    let files: [String]
    let appID: String?
    let appName: String?
    let created: Date
    let pinned: Bool
    let linkTitle: String?
    let ocr: String?
    let hasRichText: Bool

    var preview: String {
        switch kind {
        case .text:
            return String((text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
        case .image:
            return "Зображення"
        case .files:
            return files.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
        }
    }
}

enum StoreError: Error {
    case sqlite(String)
}

/// SQLite-backed history in ~/Library/Application Support/Bufer.
/// Images live as PNG files next to the database; rows keep only the file name.
final class Store {
    let baseURL: URL
    let imagesURL: URL
    private var db: OpaquePointer?

    init() throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        baseURL = support.appendingPathComponent("Bufer", isDirectory: true)
        imagesURL = baseURL.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)

        let path = baseURL.appendingPathComponent("history.sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        try exec("PRAGMA journal_mode=WAL;")
        // `search` is a lowercased copy of all searchable text: SQLite's own
        // case folding is ASCII-only, Swift's lowercased() handles Cyrillic.
        try exec("""
            CREATE TABLE IF NOT EXISTS items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                kind INTEGER NOT NULL,
                text TEXT,
                image TEXT,
                files TEXT,
                app_id TEXT,
                app_name TEXT,
                search TEXT NOT NULL DEFAULT '',
                created REAL NOT NULL,
                pinned INTEGER NOT NULL DEFAULT 0,
                hash TEXT NOT NULL UNIQUE
            );
            CREATE INDEX IF NOT EXISTS items_created ON items(created);
            """)
        try migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    /// Adds columns introduced after 0.1 to existing databases.
    private func migrate() throws {
        let existing = columns()
        if !existing.contains("category") {
            try exec("ALTER TABLE items ADD COLUMN category INTEGER NOT NULL DEFAULT 0;")
            try exec("""
                UPDATE items SET category = 2 WHERE kind = 1;
                UPDATE items SET category = 3 WHERE kind = 2;
                UPDATE items SET category = 1 WHERE kind = 0
                    AND (text LIKE 'http://%' OR text LIKE 'https://%')
                    AND instr(text, ' ') = 0 AND instr(text, char(10)) = 0;
                """)
        }
        for (name, type) in [("rtf", "BLOB"), ("html", "BLOB"), ("ocr", "TEXT"), ("link_title", "TEXT")]
        where !existing.contains(name) {
            try exec("ALTER TABLE items ADD COLUMN \(name) \(type);")
        }
        try exec("CREATE INDEX IF NOT EXISTS items_app ON items(app_id);")
    }

    private func columns() -> Set<String> {
        guard let stmt = try? prepare("PRAGMA table_info(items)") else { return [] }
        defer { sqlite3_finalize(stmt) }
        var names: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = columnText(stmt, 1) { names.insert(name) }
        }
        return names
    }

    // MARK: - Writes

    /// Inserts a new item, or bumps an existing duplicate to the top.
    @discardableResult
    func save(_ c: Capture) -> SaveResult? {
        let now = Date().timeIntervalSince1970
        do {
            if let existing = try existingID(hash: c.hash) {
                let upd = try prepare("UPDATE items SET created = ?, app_id = ?, app_name = ? WHERE id = ?")
                defer { sqlite3_finalize(upd) }
                sqlite3_bind_double(upd, 1, now)
                bind(upd, 2, c.appID)
                bind(upd, 3, c.appName)
                sqlite3_bind_int64(upd, 4, existing)
                sqlite3_step(upd)
                return SaveResult(id: existing, isNew: false, imagePath: nil)
            }

            var imageName: String?
            if let data = c.imageData {
                let name = "\(c.hash).png"
                try data.write(to: imagesURL.appendingPathComponent(name), options: .atomic)
                imageName = name
            }
            let search = [c.text ?? "", c.files.joined(separator: " "), c.appName ?? ""]
                .joined(separator: " ")
                .lowercased()

            let ins = try prepare("""
                INSERT INTO items (kind, category, text, rtf, html, image, files, app_id, app_name,
                                   search, created, hash)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            defer { sqlite3_finalize(ins) }
            sqlite3_bind_int(ins, 1, Int32(c.kind.rawValue))
            sqlite3_bind_int(ins, 2, Int32(c.category.rawValue))
            bind(ins, 3, c.text)
            bind(ins, 4, c.rtf)
            bind(ins, 5, c.html)
            bind(ins, 6, imageName)
            bind(ins, 7, c.files.isEmpty ? nil : c.files.joined(separator: "\n"))
            bind(ins, 8, c.appID)
            bind(ins, 9, c.appName)
            bind(ins, 10, search)
            sqlite3_bind_double(ins, 11, now)
            bind(ins, 12, c.hash)
            guard sqlite3_step(ins) == SQLITE_DONE else {
                Log.info("insert failed: \(String(cString: sqlite3_errmsg(db)))")
                return nil
            }
            return SaveResult(id: sqlite3_last_insert_rowid(db), isNew: true,
                              imagePath: imageName.map { imagesURL.appendingPathComponent($0).path })
        } catch {
            Log.info("save failed: \(error)")
            return nil
        }
    }

    /// Moves an item to the top of the history.
    func touch(_ id: Int64) {
        guard let stmt = try? prepare("UPDATE items SET created = ? WHERE id = ?") else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 2, id)
        sqlite3_step(stmt)
    }

    func setPinned(_ id: Int64, _ pinned: Bool) {
        guard let stmt = try? prepare("UPDATE items SET pinned = ? WHERE id = ?") else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, pinned ? 1 : 0)
        sqlite3_bind_int64(stmt, 2, id)
        sqlite3_step(stmt)
    }

    /// Text found on an image; also becomes searchable.
    func setOCR(_ id: Int64, _ text: String) {
        setExtra(column: "ocr", id: id, value: text)
    }

    /// Page title of a link; also becomes searchable.
    func setLinkTitle(_ id: Int64, _ title: String) {
        setExtra(column: "link_title", id: id, value: title)
    }

    private func setExtra(column: String, id: Int64, value: String) {
        let sql = "UPDATE items SET \(column) = ?, search = search || ' ' || ? WHERE id = ?"
        guard let stmt = try? prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, value)
        bind(stmt, 2, value.lowercased())
        sqlite3_bind_int64(stmt, 3, id)
        sqlite3_step(stmt)
    }

    func delete(_ id: Int64) {
        removeRows(selecting: "SELECT id, image FROM items WHERE id = ?", bindInt: id)
    }

    /// Removes everything except pinned items.
    func clearUnpinned() {
        removeRows(selecting: "SELECT id, image FROM items WHERE pinned = 0")
    }

    /// Keeps the newest `keep` unpinned items, removes older ones.
    func prune(keep: Int) {
        removeRows(
            selecting: "SELECT id, image FROM items WHERE pinned = 0 ORDER BY created DESC LIMIT -1 OFFSET ?",
            bindInt: Int64(keep)
        )
    }

    /// Removes unpinned items copied before `date`.
    func prune(olderThan date: Date) {
        removeRows(
            selecting: "SELECT id, image FROM items WHERE pinned = 0 AND created < ?",
            bindInt: Int64(date.timeIntervalSince1970)
        )
    }

    // MARK: - Reads

    /// Every whitespace-separated word of `query` must occur somewhere in the item,
    /// including text recognized on images and link titles.
    func fetch(query: String, scope: ClipScope, limit: Int = 300) -> [ClipItem] {
        let tokens = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var conditions: [String] = []
        var binds: [String] = []
        switch scope {
        case .all:
            break
        case .pinned:
            conditions.append("pinned = 1")
        case .category(let category):
            conditions.append("category = \(category.rawValue)")
        case .app(let id):
            conditions.append("app_id = ?")
            binds.append(id)
        }
        for token in tokens {
            conditions.append("instr(search, ?) > 0")
            binds.append(token)
        }
        let whereSQL = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let sql = """
            SELECT id, kind, category, text, image, files, app_id, app_name, created, pinned,
                   link_title, ocr, (rtf IS NOT NULL OR html IS NOT NULL)
            FROM items \(whereSQL) ORDER BY created DESC LIMIT \(limit)
            """
        guard let stmt = try? prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in binds.enumerated() {
            bind(stmt, Int32(i + 1), value)
        }

        var items: [ClipItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let imageName = columnText(stmt, 4)
            items.append(ClipItem(
                id: sqlite3_column_int64(stmt, 0),
                kind: ClipKind(rawValue: Int(sqlite3_column_int(stmt, 1))) ?? .text,
                category: ClipCategory(rawValue: Int(sqlite3_column_int(stmt, 2))) ?? .text,
                text: columnText(stmt, 3),
                imagePath: imageName.map { imagesURL.appendingPathComponent($0).path },
                files: columnText(stmt, 5)?.components(separatedBy: "\n") ?? [],
                appID: columnText(stmt, 6),
                appName: columnText(stmt, 7),
                created: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)),
                pinned: sqlite3_column_int(stmt, 9) != 0,
                linkTitle: columnText(stmt, 10),
                ocr: columnText(stmt, 11),
                hasRichText: sqlite3_column_int(stmt, 12) != 0
            ))
        }
        return items
    }

    /// Formatting kept from the original copy, for pasting "as it was".
    func richText(_ id: Int64) -> (rtf: Data?, html: Data?) {
        guard let stmt = try? prepare("SELECT rtf, html FROM items WHERE id = ?") else { return (nil, nil) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return (nil, nil) }
        return (columnData(stmt, 0), columnData(stmt, 1))
    }

    /// Source apps, most recently used first.
    func apps(limit: Int = 25) -> [AppGroup] {
        let sql = """
            SELECT app_id, MAX(app_name), COUNT(*) FROM items WHERE app_id IS NOT NULL
            GROUP BY app_id ORDER BY MAX(created) DESC LIMIT \(limit)
            """
        guard let stmt = try? prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var groups: [AppGroup] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = columnText(stmt, 0) else { continue }
            groups.append(AppGroup(id: id, name: columnText(stmt, 1) ?? id,
                                   count: Int(sqlite3_column_int(stmt, 2))))
        }
        return groups
    }

    func categoryCounts() -> [ClipCategory: Int] {
        guard let stmt = try? prepare("SELECT category, COUNT(*) FROM items GROUP BY category") else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var counts: [ClipCategory: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let category = ClipCategory(rawValue: Int(sqlite3_column_int(stmt, 0))) {
                counts[category] = Int(sqlite3_column_int(stmt, 1))
            }
        }
        return counts
    }

    func pinnedCount() -> Int {
        guard let stmt = try? prepare("SELECT COUNT(*) FROM items WHERE pinned = 1") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    // MARK: - SQLite helpers

    private func existingID(hash: String) throws -> Int64? {
        let stmt = try prepare("SELECT id FROM items WHERE hash = ?")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, hash)
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : nil
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(err)
            throw StoreError.sqlite(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return s
    }

    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ data: Data?) {
        guard let data, !data.isEmpty else {
            sqlite3_bind_null(stmt, index)
            return
        }
        data.withUnsafeBytes { raw in
            _ = sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
        }
    }

    private func columnText(_ stmt: OpaquePointer, _ column: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: c)
    }

    private func columnData(_ stmt: OpaquePointer, _ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(stmt, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, column)))
    }

    /// Deletes rows returned by a `SELECT id, image ...` query, with their image files.
    private func removeRows(selecting sql: String, bindInt: Int64? = nil) {
        guard let stmt = try? prepare(sql) else { return }
        if let bindInt { sqlite3_bind_int64(stmt, 1, bindInt) }
        var ids: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.append(sqlite3_column_int64(stmt, 0))
            if let name = columnText(stmt, 1) {
                try? FileManager.default.removeItem(at: imagesURL.appendingPathComponent(name))
            }
        }
        sqlite3_finalize(stmt)

        guard !ids.isEmpty, let del = try? prepare("DELETE FROM items WHERE id = ?") else { return }
        defer { sqlite3_finalize(del) }
        try? exec("BEGIN")
        for id in ids {
            sqlite3_reset(del)
            sqlite3_bind_int64(del, 1, id)
            sqlite3_step(del)
        }
        try? exec("COMMIT")
    }
}
