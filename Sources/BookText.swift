import Foundation

/// 章节文本读取：永远不返回 nil，也永远不返回空白页。
///
/// 中文 EPUB 常见的坑：XHTML 里声明 `encoding="utf-8"` 但真实字节是 GBK/GB18030；
/// 或者带 UTF-16 BOM；或者夹着非法字节导致 `String(contentsOf:encoding:.utf8)` 直接抛错。
/// 以前这里用 `try? … encoding: .utf8`，失败就静默变成空字符串 —— 表现就是「打开书一片空白，
/// 但章节数正常」。所以这里按 BOM → UTF-8 → HTML charset 声明 → GB18030 → 有损 UTF-8 逐级降级。
enum BookText {

    static func read(_ url: URL?) -> String? {
        guard let url, let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> String {
        if data.count >= 3, data[data.startIndex] == 0xEF,
           data[data.startIndex + 1] == 0xBB, data[data.startIndex + 2] == 0xBF {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        if data.count >= 2, data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xFE,
           let s = String(data: data, encoding: .utf16LittleEndian) { return s }
        if data.count >= 2, data[data.startIndex] == 0xFE, data[data.startIndex + 1] == 0xFF,
           let s = String(data: data, encoding: .utf16BigEndian) { return s }

        if let s = String(data: data, encoding: .utf8) { return s }

        let head = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
        if head.contains("gb2312") || head.contains("gbk") || head.contains("gb18030"),
           let s = String(data: data, encoding: gb18030) { return s }

        if let s = String(data: data, encoding: gb18030) { return s }

        return String(decoding: data, as: UTF8.self)
    }

    private static var gb18030: String.Encoding {
        let cf = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String.Encoding(rawValue: cf)
    }
}
