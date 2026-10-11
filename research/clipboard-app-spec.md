# Свій clipboard-менеджер за зразком PasteNow — специфікація

Дата: 2026-10-10
Референс: PasteNow (macOS + iOS, iCloud sync, разова покупка ~$7).

## 1. Що робить PasteNow (розбір функцій)

| Блок | Що є в PasteNow |
|---|---|
| Історія | Автоматично збирає все скопійоване: текст, посилання, картинки, код, файли |
| Smart Lists | Автосортування за правилами: застосунок-джерело, дата, тип контенту, свій текст-фільтр |
| Ручні списки | Свої колекції кліпів (аналог pinboards) |
| Вигляд | 3 режими: Simple List, Rich List, Grid |
| Вставка | З оригінальним форматуванням або plain text |
| Виклик | Глобальний хоткей; панель біля текстового курсора або біля миші |
| Клавіатура | Повне керування з клавіатури, свої шорткати |
| Preview / Edit | Space — прев'ю, правий клік — редагування кліпу |
| Drag & Drop | Перетягнути кліп у будь-який застосунок |
| Розпізнавання | HEX-кольори показує плашкою кольору, посилання, код |
| Exclusion Rules | Не зберігати з певних застосунків (менеджери паролів) і за іншими правилами |
| Sync | iCloud між Mac і iPhone/iPad |
| Платформи | macOS 15+, iOS 18+ |

## 2. Рекомендація по стеку

**Нативний Swift + SwiftUI (AppKit там, де треба), спершу лише macOS.**

- Electron/Tauri не підходять: clipboard-менеджер має жити у фоні, стартувати миттєво й їсти мінімум пам'яті.
- Сховище: **SwiftData** (або GRDB/SQLite, якщо треба повнотекстовий пошук FTS5 — рекомендую GRDB).
- Sync: **CloudKit** (private database) — безкоштовно для користувача й розробника, без свого бекенду.
- iOS — другим етапом, на тій самій моделі даних (спільний Swift package).

## 3. Архітектура (macOS)

```
ClipboardApp/
├── App/                    # MenuBarExtra, AppDelegate, lifecycle
├── Core/ (Swift package, shared with iOS later)
│   ├── Models/             # Clip, ClipList, SmartListRule, ExclusionRule
│   ├── Storage/            # GRDB + FTS5, blob storage for images
│   ├── Sync/               # CloudKit (CKSyncEngine)
│   └── Detectors/          # URL, HEX color, code, email, phone
├── Monitor/
│   └── PasteboardMonitor   # polls NSPasteboard.changeCount every ~0.3s
├── Paste/
│   └── PasteService        # writes to pasteboard + simulates ⌘V via CGEvent
├── UI/
│   ├── Panel/              # NSPanel (non-activating) near caret / mouse
│   ├── ListView, GridView, RichListView
│   ├── QuickLookPreview    # Space preview
│   └── Settings/
└── Hotkeys/                # global shortcuts (KeyboardShortcuts lib)
```

### Ключові технічні моменти
1. **Моніторинг буфера.** У macOS немає події «буфер змінився» — опитуємо `NSPasteboard.general.changeCount` таймером. Це стандартний підхід (так роблять Maccy, Paste, PasteNow).
2. **Приватність.** Пропускати записи з типами `org.nspasteboard.ConcealedType` і `org.nspasteboard.TransientType` (так менеджери паролів позначають секрети) + exclusion-список застосунків за `bundleIdentifier` активного застосунку.
3. **Вставка в чужий застосунок.** Кладемо кліп у pasteboard і шлемо ⌘V через `CGEvent`. Потрібен дозвіл **Accessibility** — без нього лише копіювання.
4. **Панель біля курсора.** Позиція текстового курсора — через Accessibility API (`kAXSelectedTextRangeAttribute` → `kAXBoundsForRangeParameterizedAttribute`); якщо не вийшло — біля миші.
5. **Панель не краде фокус:** `NSPanel` з `.nonactivatingPanel`.
6. **Картинки:** оригінал — файлом на диску, у БД — шлях + мініатюра.
7. **App Store vs direct.** Симуляція ⌘V і Accessibility у sandbox працюють обмежено. PasteNow є і в App Store, і direct download — для MVP раджу **direct-дистрибуцію (notarized DMG)**, App Store потім.

## 4. Моделі даних

```swift
Clip {
  id: UUID
  createdAt, lastUsedAt: Date
  sourceAppBundleID: String?
  kind: text | richText | url | image | file | color | code
  plainText: String?          // for search (FTS5)
  representations: [UTType: Data/fileURL]  // RTF, HTML, PNG...
  isPinned: Bool
  listIDs: [UUID]
  useCount: Int
}
ClipList { id, name, icon, order }
SmartList { id, name, rules: [Rule], match: all|any }
Rule { field: app|kind|date|text, op: is|contains|before|after, value }
ExclusionRule { appBundleID? , regex? }
```

## 5. Роадмап

**MVP (v0.1)** — 2–3 тижні роботи
- Menu bar застосунок, моніторинг буфера, історія (текст, посилання, картинки)
- Глобальний хоткей → панель, пошук, стрілки + Enter = вставка
- Plain text paste (⇧Enter)
- Exclusion: concealed-типи + список застосунків
- Ліміт історії й автоочищення

**v0.2**
- Ручні списки, pin, drag & drop
- Space-прев'ю, редагування кліпу
- Детектори: HEX-колір, URL з favicon, код
- Grid / Rich List режими

**v0.3**
- Smart Lists з правилами
- Панель біля текстового курсора
- iCloud sync (CKSyncEngine)

**v1.0**
- iOS-застосунок + віджет/Share Extension (на iOS читати буфер у фоні не можна — лише при відкритті застосунку чи через Share/Shortcuts)
- Ліцензування, App Store

## 6. Чим можна обійти PasteNow (ідеї для своєї переваги)
- **Paste Stack / послідовна вставка:** скопіював 5 речей → вставляєш по черзі (є в Paste, нема в PasteNow).
- **Трансформації при вставці:** UPPER/lower, обрізати пробіли, JSON pretty, прибрати трекінг з URL.
- **OCR з картинок** (Vision framework) — шукати текст на скрінах.
- **Сніпети з плейсхолдерами** для промптів і шаблонних текстів — під робочі задачі зі скілами.
- Локальний AI-пошук за змістом (embeddings на пристрої).

## 7. Обмеження хмарної сесії
Збирати й запускати macOS-застосунок можна лише на Маку з Xcode. Тут можна писати код,
структуру проєкту й тести бізнес-логіки, але компіляцію AppKit/SwiftUI і перевірку — тільки локально.
