import Foundation

// MARK: - 模型

enum HighlightColor: String, Codable, CaseIterable, Identifiable {
    case yellow, green, blue, pink
    var id: String { rawValue }

    var title: String {
        switch self {
        case .yellow: return "黄"
        case .green: return "绿"
        case .blue: return "蓝"
        case .pink: return "粉"
        }
    }

    /// 用于 CSS：偏透明，深色主题下也看得清
    var css: String {
        switch self {
        case .yellow: return "rgba(255,214,64,0.42)"
        case .green: return "rgba(88,204,140,0.38)"
        case .blue: return "rgba(90,160,255,0.34)"
        case .pink: return "rgba(255,110,170,0.34)"
        }
    }

    var hex: String {
        switch self {
        case .yellow: return "FFD640"
        case .green: return "58CC8C"
        case .blue: return "5AA0FF"
        case .pink: return "FF6EAA"
        }
    }
}

struct Highlight: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var bookID: UUID
    var chapterIndex: Int
    /// 章内字符偏移（基于纯文本，不含 HTML）
    var start: Int
    var end: Int
    var text: String
    var color: HighlightColor = .yellow
    var note: String = ""
    var createdAt: Date = Date()
}

struct Bookmark: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var bookID: UUID
    var chapterIndex: Int
    var fraction: Double
    var preview: String
    var createdAt: Date = Date()
}

// MARK: - 存储

final class HighlightStore: ObservableObject {
    @Published private(set) var highlights: [Highlight] = []
    @Published private(set) var bookmarks: [Bookmark] = []

    private let store: LibraryStore
    private var url: URL { store.docs.appendingPathComponent("notes.json") }

    private struct Payload: Codable {
        var highlights: [Highlight] = []
        var bookmarks: [Bookmark] = []
    }

    init(store: LibraryStore) {
        self.store = store
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        highlights = p.highlights
        bookmarks = p.bookmarks
    }

    private func save() {
        let p = Payload(highlights: highlights, bookmarks: bookmarks)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(p) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: 高亮

    func highlights(for bookID: UUID) -> [Highlight] {
        highlights.filter { $0.bookID == bookID }
            .sorted { ($0.chapterIndex, $0.start) < ($1.chapterIndex, $1.start) }
    }

    func highlights(bookID: UUID, chapter: Int) -> [Highlight] {
        highlights.filter { $0.bookID == bookID && $0.chapterIndex == chapter }
    }

    @discardableResult
    func add(_ h: Highlight) -> Highlight {
        highlights.append(h)
        save()
        return h
    }

    func update(_ h: Highlight) {
        guard let i = highlights.firstIndex(where: { $0.id == h.id }) else { return }
        highlights[i] = h
        save()
    }

    func delete(_ h: Highlight) {
        highlights.removeAll { $0.id == h.id }
        save()
    }

    // MARK: 书签

    func bookmarks(for bookID: UUID) -> [Bookmark] {
        bookmarks.filter { $0.bookID == bookID }.sorted { $0.createdAt > $1.createdAt }
    }

    func toggleBookmark(bookID: UUID, chapter: Int, fraction: Double, preview: String) {
        if let i = bookmarks.firstIndex(where: {
            $0.bookID == bookID && $0.chapterIndex == chapter && abs($0.fraction - fraction) < 0.02
        }) {
            bookmarks.remove(at: i)
        } else {
            bookmarks.append(Bookmark(bookID: bookID, chapterIndex: chapter,
                                      fraction: fraction,
                                      preview: String(preview.prefix(40))))
        }
        save()
    }

    func deleteBookmark(_ b: Bookmark) {
        bookmarks.removeAll { $0.id == b.id }
        save()
    }

    // MARK: 导出

    func markdown(book: Book) -> String {
        var out = "# \(book.title)\n\n"
        if !book.author.isEmpty { out += "作者：\(book.author)\n\n" }
        let hs = highlights(for: book.id)
        out += "> 共 \(hs.count) 条笔记 / \(bookmarks(for: book.id).count) 个书签\n\n---\n\n"

        let grouped = Dictionary(grouping: hs, by: { $0.chapterIndex })
        for chapter in grouped.keys.sorted() {
            out += "## 第 \(chapter + 1) 章\n\n"
            for h in (grouped[chapter] ?? []).sorted(by: { $0.start < $1.start }) {
                out += "> \(h.text.replacingOccurrences(of: "\n", with: " "))\n\n"
                if !h.note.isEmpty {
                    out += "\(h.note)\n\n"
                }
                out += "`\(h.color.title) · \(h.createdAt.ygString("yyyy-MM-dd HH:mm"))`\n\n"
            }
        }
        return out
    }

    func plainText(book: Book) -> String {
        var out = "\(book.title)\n\n"
        for h in highlights(for: book.id) {
            out += "· \(h.text.replacingOccurrences(of: "\n", with: " "))\n"
            if !h.note.isEmpty { out += "  \(h.note)\n" }
        }
        return out
    }

    /// 写到沙盒 Document，返回文件 URL（供分享）
    func export(book: Book, markdown: Bool) -> URL? {
        let body = markdown ? self.markdown(book: book) : plainText(book: book)
        let name = book.title.replacingOccurrences(of: "/", with: "-")
        let url = store.docs.appendingPathComponent(
            "\(name)-笔记.\(markdown ? "md" : "txt")")
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

private extension Date {
    func ygString(_ fmt: String) -> String {
        let f = DateFormatter()
        f.dateFormat = fmt
        return f.string(from: self)
    }
}
