import Foundation
import ZIPFoundation

// MARK: - 数据模型

struct Book: Identifiable, Codable, Equatable {
    enum Format: String, Codable { case epub, txt }
    enum ReadState: String, Codable, CaseIterable {
        case want, reading, finished
        var title: String {
            switch self {
            case .want: return "想读"
            case .reading: return "在读"
            case .finished: return "读完"
            }
        }
    }

    var id: UUID = UUID()
    var title: String
    var author: String = ""
    var fileName: String
    var format: Format
    var coverName: String?
    var progress: Double = 0
    var state: ReadState = .want
    var addedAt: Date = Date()
    var lastReadAt: Date?
    var charCount: Int = 0
    var locatorChapter: Int = 0
    var locatorFraction: Double = 0
}

// MARK: - 存储

final class LibraryStore: ObservableObject {
    @Published private(set) var books: [Book] = []
    @Published var importing = false
    @Published var lastError: String?

    let fm = FileManager.default

    // Documents/Books   书文件
    // Documents/Covers  封面
    // Documents/Backup  备份（在「文件」App 里可见）
    var docs: URL { fm.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    var booksDir: URL { docs.appendingPathComponent("Books", isDirectory: true) }
    var coversDir: URL { docs.appendingPathComponent("Covers", isDirectory: true) }
    var backupDir: URL { docs.appendingPathComponent("Backup", isDirectory: true) }
    var stateURL: URL {
        docs.appendingPathComponent("library.json")
    }

    init() {
        try? fm.createDirectory(at: booksDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: coversDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        load()
        seedFromInboxIfNeeded()
    }

    // MARK: 持久化

    func load() {
        guard let data = try? Data(contentsOf: stateURL),
              let list = try? JSONDecoder().decode([Book].self, from: data) else { return }
        books = list
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(books) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    // MARK: 导入

    /// 首次启动时，把通过「文件」App 放进 Documents/Inbox 或根目录的书收进来
    func seedFromInboxIfNeeded() {
        let inbox = docs.appendingPathComponent("Inbox", isDirectory: true)
        var candidates: [URL] = []
        if let items = try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil) {
            candidates += items
        }
        if let items = try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) {
            candidates += items.filter { ["epub", "txt"].contains($0.pathExtension.lowercased()) }
        }
        guard !candidates.isEmpty else { return }
        Task {
            for url in candidates { await importFromURL(url) }
            try? fm.removeItem(at: inbox)
        }
    }

    func importFromURL(_ url: URL) async {
        importing = true
        defer { importing = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let book = try ingest(url)
            books.insert(book, at: 0)
            save()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func ingest(_ url: URL) throws -> Book {
        let ext = url.pathExtension.lowercased()
        guard let format = Book.Format(rawValue: ext) else {
            throw NSError(domain: "Yedu", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "不支持的格式：.\(ext)"])
        }
        let id = UUID()
        let destName = "\(id.uuidString).\(ext)"
        let dest = booksDir.appendingPathComponent(destName)
        if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
        try fm.copyItem(at: url, to: dest)

        var book = Book(title: url.deletingPathExtension().lastPathComponent,
                        fileName: destName,
                        format: format)

        switch format {
        case .epub:
            let meta = EPUBMetadata.read(at: dest)
            if let t = meta.title, !t.isEmpty { book.title = t }
            if let a = meta.author, !a.isEmpty { book.author = a }
            if let coverURL = meta.coverURL {
                let coverName = "\(id.uuidString).jpg"
                let target = coversDir.appendingPathComponent(coverName)
                if (try? fm.copyItem(at: coverURL, to: target)) != nil {
                    book.coverName = coverName
                }
                try? fm.removeItem(at: coverURL.deletingLastPathComponent())
            }
        case .txt:
            book.charCount = (try? TextFile.text(at: dest).count) ?? 0
        }

        if book.state == .want { book.state = .want }
        return book
    }

    // MARK: 查询

    func coverURL(for book: Book) -> URL? {
        guard let name = book.coverName else { return nil }
        let url = coversDir.appendingPathComponent(name)
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    func fileURL(for book: Book) -> URL {
        booksDir.appendingPathComponent(book.fileName)
    }

    func delete(_ book: Book) {
        try? fm.removeItem(at: fileURL(for: book))
        if let name = book.coverName {
            try? fm.removeItem(at: coversDir.appendingPathComponent(name))
        }
        books.removeAll { $0.id == book.id }
        save()
    }

    func setState(_ state: Book.ReadState, for book: Book) {
        guard let i = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[i].state = state
        if state == .reading && books[i].lastReadAt == nil { books[i].lastReadAt = Date() }
        save()
    }

    /// 阅读器回报位置：写回 book，顺便刷新总进度与状态
    func updateLocator(_ loc: ReadingLocator, for book: Book, chapterCount: Int) {
        guard let i = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[i].locatorChapter = loc.chapterIndex
        books[i].locatorFraction = loc.fraction
        books[i].lastReadAt = Date()
        if books[i].state == .want { books[i].state = .reading }
        let total = max(1, chapterCount)
        let p = (Double(loc.chapterIndex) + loc.fraction) / Double(total)
        books[i].progress = min(1, max(0, p))
        save()
    }

    /// 阅读内容的解包缓存目录
    var extractDir: URL {
        let d = docs.appendingPathComponent("Extracted", isDirectory: true)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}

// MARK: - EPUB 元数据

enum EPUBMetadata {
    struct Result {
        var title: String?
        var author: String?
        var coverURL: URL?
    }

    static func read(at url: URL) -> Result {
        var result = Result()
        guard let archive = try? Archive(url: url, accessMode: .read) else { return result }

        // 1. META-INF/container.xml → OPF 路径
        guard let containerData = extract("META-INF/container.xml", from: archive),
              let containerXML = String(data: containerData, encoding: .utf8),
              let opfPath = firstMatch(in: containerXML,
                                       pattern: #"full-path\s*=\s*"([^"]+)""#) else {
            return result
        }

        // 2. 解析 OPF
        guard let opfData = extract(opfPath, from: archive),
              let opf = String(data: opfData, encoding: .utf8) else { return result }

        result.title = firstMatch(in: opf, pattern: #"<dc:title[^>]*>([^<]+)</dc:title>"#)
        result.author = firstMatch(in: opf, pattern: #"<dc:creator[^>]*>([^<]+)</dc:creator>"#)

        // 3. 封面：优先 properties="cover-image"，其次 meta name="cover"
        var coverHref = firstMatch(in: opf,
                                   pattern: #"<item[^>]*properties\s*=\s*"[^"]*cover-image[^"]*"[^>]*href\s*=\s*"([^"]+)""#)
        if coverHref == nil,
           let coverID = firstMatch(in: opf, pattern: #"<meta[^>]*name\s*=\s*"cover"[^>]*content\s*=\s*"([^"]+)""#) {
            coverHref = firstMatch(in: opf,
                                   pattern: #"<item[^>]*id\s*=\s*"\#(coverID)"[^>]*href\s*=\s*"([^"]+)""#)
        }
        guard let href = coverHref else { return result }

        let opfDir = (opfPath as NSString).deletingLastPathComponent
        let innerPath = opfDir.isEmpty ? href : opfDir + "/" + href
        guard let coverData = extract(innerPath, from: archive) else { return result }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let tmpFile = tmpDir.appendingPathComponent("cover.jpg")
        try? coverData.write(to: tmpFile)
        result.coverURL = tmpFile
        return result
    }

    private static func extract(_ path: String, from archive: Archive) -> Data? {
        guard let entry = archive[path] else { return nil }
        var data = Data()
        _ = try? archive.extract(entry) { data.append($0) }
        return data.isEmpty ? nil : data
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern,
                                               options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - TXT 编码识别

enum TextFile {
    enum Encoding {
        case utf8, utf16, gb18030
    }

    static func detect(_ data: Data) -> Encoding {
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF { return .utf8 }
        if data.count >= 2 {
            let b0 = data[0], b1 = data[1]
            if (b0 == 0xFF && b1 == 0xFE) || (b0 == 0xFE && b1 == 0xFF) { return .utf16 }
        }
        if String(data: data, encoding: .utf8) != nil { return .utf8 }
        return .gb18030
    }

    static func text(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        switch detect(data) {
        case .utf8:
            return String(data: data, encoding: .utf8) ?? ""
        case .utf16:
            return String(data: data, encoding: .utf16) ?? ""
        case .gb18030:
            let cfEnc = CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            return String(data: data, encoding: String.Encoding(rawValue: cfEnc))
                ?? String(data: data, encoding: .isoLatin1) ?? ""
        }
    }
}
