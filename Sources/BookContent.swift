import Foundation
import ZIPFoundation

// MARK: - 统一的书籍内容

protocol BookContent {
    var displayTitle: String { get }
    var chapters: [Chapter] { get }
    var baseDirectory: URL? { get }
    func locator(forChapter index: Int, fraction: Double) -> ReadingLocator
}

// MARK: - EPUB

final class EPUBContent: BookContent {
    let displayTitle: String
    private(set) var chapters: [Chapter] = []
    private(set) var baseDirectory: URL?

    init(url: URL, title: String, cacheRoot: URL) {
        displayTitle = title
        let dir = cacheRoot.appendingPathComponent(url.deletingPathExtension().lastPathComponent,
                                                   isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let archive = try? Archive(url: url, accessMode: .read) {
                for entry in archive where entry.type == .file {
                    _ = try? archive.extract(entry) { data in
                        let target = dir.appendingPathComponent(entry.path)
                        try? FileManager.default.createDirectory(
                            at: target.deletingLastPathComponent(),
                            withIntermediateDirectories: true)
                        try? data.write(to: target)
                    }
                }
            }
        }
        baseDirectory = dir
        parse(containerDir: dir)
    }

    private func parse(containerDir dir: URL) {
        let container = dir.appendingPathComponent("META-INF/container.xml")
        guard let xml = try? String(contentsOf: container, encoding: .utf8),
              let opfRel = Self.firstMatch(in: xml, #"full-path\s*=\s*"([^"]+)""#) else { return }

        let opfURL = dir.appendingPathComponent(opfRel)
        guard let opf = try? String(contentsOf: opfURL, encoding: .utf8) else { return }
        let opfDir = opfURL.deletingLastPathComponent()

        // manifest: id -> (href, mediaType, properties)
        var manifest: [String: (href: String, type: String, props: String)] = [:]
        let itemPattern = #"<item\s+[^>]*>"#
        for tag in Self.matches(in: opf, itemPattern) {
            guard let id = Self.firstMatch(in: tag, #"id\s*=\s*"([^"]+)""#),
                  let href = Self.firstMatch(in: tag, #"href\s*=\s*"([^"]+)""#) else { continue }
            let type = Self.firstMatch(in: tag, #"media-type\s*=\s*"([^"]+)""#) ?? ""
            let props = Self.firstMatch(in: tag, #"properties\s*=\s*"([^"]+)""#) ?? ""
            manifest[id] = (href, type, props)
        }

        // spine 顺序
        var order: [String] = []
        if let spineBlock = Self.firstMatch(in: opf, #"(?s)<spine[^>]*>(.*?)</spine>"#) {
            for tag in Self.matches(in: spineBlock, #"<itemref\s+[^>]*>"#) {
                if let idref = Self.firstMatch(in: tag, #"idref\s*=\s*"([^"]+)""#) {
                    order.append(idref)
                }
            }
        }

        // 目录标题：EPUB3 nav 或 EPUB2 ncx
        var titles: [String: String] = [:]
        if let navItem = manifest.values.first(where: { $0.props.contains("nav") }),
           let navText = try? String(contentsOf: opfDir.appendingPathComponent(navItem.href),
                                     encoding: .utf8) {
            let anchors = Self.matches(in: navText, #"(?s)<a[^>]*href\s*=\s*"([^"#]*)(?:#[^"]*)?"[^>]*>(.*?)</a>"#)
            for a in anchors {
                guard let file = Self.firstMatch(in: a, #"href\s*=\s*"([^"#]*)"#),
                      let text = Self.firstMatch(in: a, #">([^<]*)</a>"#) else { continue }
                let key = (file as NSString).lastPathComponent
                if titles[key] == nil { titles[key] = Self.clean(text) }
            }
        } else if let ncxItem = manifest.values.first(where: { $0.type.contains("ncx") }),
                  let ncx = try? String(contentsOf: opfDir.appendingPathComponent(ncxItem.href),
                                        encoding: .utf8) {
            let points = Self.matches(in: ncx, #"(?s)<navPoint[^>]*>(.*?)</navPoint>"#)
            for p in points {
                guard let src = Self.firstMatch(in: p, #"src\s*=\s*"([^"#]*)"#),
                      let text = Self.firstMatch(in: p, #"<text[^>]*>([^<]*)</text>"#) else { continue }
                let key = (src as NSString).lastPathComponent
                if titles[key] == nil { titles[key] = Self.clean(text) }
            }
        }

        chapters = order.compactMap { idref in
            guard let item = manifest[idref] else { return nil }
            let fileURL = opfDir.appendingPathComponent(item.href)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            let name = (item.href as NSString).lastPathComponent
            let title = titles[name] ?? ""
            return Chapter(title: title, fileURL: fileURL, html: "", charOffset: 0)
        }
    }

    func locator(forChapter index: Int, fraction: Double) -> ReadingLocator {
        ReadingLocator(chapterIndex: index, fraction: fraction, charOffset: 0)
    }

    // MARK: 正则小工具

    static func matches(in text: String, _ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).compactMap { m in
            Range(m.range, in: text).map { String(text[$0]) }
        }
    }

    static func firstMatch(in text: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#160;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - TXT

final class TXTContent: BookContent {
    let displayTitle: String
    private(set) var chapters: [Chapter] = []
    var baseDirectory: URL? { nil }

    /// 单章最大字符数，没有章节标记时按此切块
    private let chunkSize = 6000

    init(text: String, title: String) {
        displayTitle = title
        chapters = Self.split(text)
    }

    static func split(_ text: String) -> [Chapter] {
        let ns = text as NSString
        let pattern = #"(?m)^[ \t　]*第[0-9零一二三四五六七八九十百千两]{1,8}[章节回卷篇][^\n]{0,40}$"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))

        var marks: [(title: String, offset: Int)] = []
        for m in matches {
            let offset = m.range.location
            let line = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
            marks.append((line, offset))
        }

        var result: [Chapter] = []
        if marks.isEmpty {
            // 无章节标记：按固定字数切块
            var start = 0
            var index = 1
            while start < ns.length {
                let len = min(6000, ns.length - start)
                let body = ns.substring(with: NSRange(location: start, length: len))
                result.append(Chapter(title: "第 \(index) 部分",
                                      fileURL: nil,
                                      html: Self.toHTML(body),
                                      charOffset: start))
                start += len
                index += 1
            }
            return result
        }

        // 第一个章节标记之前的内容
        if marks[0].offset > 0 {
            let head = ns.substring(with: NSRange(location: 0, length: marks[0].offset))
            if head.trimmingCharacters(in: .whitespacesAndNewlines).count > 0 {
                result.append(Chapter(title: "前言",
                                      fileURL: nil,
                                      html: Self.toHTML(head),
                                      charOffset: 0))
            }
        }

        for (i, m) in marks.enumerated() {
            let end = i + 1 < marks.count ? marks[i + 1].offset : ns.length
            let len = max(0, end - m.offset)
            let body = ns.substring(with: NSRange(location: m.offset, length: len))
            result.append(Chapter(title: m.title,
                                  fileURL: nil,
                                  html: Self.toHTML(body),
                                  charOffset: m.offset))
        }
        return result
    }

    /// 纯文本 → 段落 HTML
    static func toHTML(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var out: [String] = []
        var buffer: [String] = []
        func flush() {
            guard !buffer.isEmpty else { return }
            let joined = buffer.joined()
            if !joined.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append("<p>" + Self.escape(joined) + "</p>")
            }
            buffer.removeAll()
        }
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty {
                flush()
            } else {
                buffer.append(t)
            }
        }
        flush()
        return out.joined(separator: "\n")
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    func locator(forChapter index: Int, fraction: Double) -> ReadingLocator {
        let base = chapters.indices.contains(index) ? chapters[index].charOffset : 0
        let length = chapters.indices.contains(index) ? chapters[index].html.count : 0
        return ReadingLocator(chapterIndex: index,
                              fraction: fraction,
                              charOffset: base + Int(Double(length) * fraction))
    }
}
