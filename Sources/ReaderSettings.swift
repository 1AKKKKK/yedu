import UIKit

// MARK: - 阅读设置

enum ReaderTheme: String, Codable, CaseIterable {
    case paper, sepia, dark, black

    var title: String {
        switch self {
        case .paper: return "白纸"
        case .sepia: return "米黄"
        case .dark: return "深灰"
        case .black: return "纯黑"
        }
    }

    var background: String {
        switch self {
        case .paper: return "#FFFFFF"
        case .sepia: return "#F5EFE1"
        case .dark: return "#2B2B2B"
        case .black: return "#000000"
        }
    }

    var foreground: String {
        switch self {
        case .paper, .sepia: return "#222222"
        case .dark: return "#DDDDDD"
        case .black: return "#B8B8B8"
        }
    }

    var isDark: Bool { self == .dark || self == .black }
}

struct ReaderSettings: Codable, Equatable {
    var fontSize: Double = 19
    var lineHeight: Double = 1.8
    /// 系统字体名；内置字体后续以 PostScript 名写入
    var fontFamily: String = "Songti SC"
    var indentEM: Double = 2
    var paragraphSpacingEM: Double = 0.4
    var theme: ReaderTheme = .paper
    var paged: Bool = true
    /// 中文避头尾（JS 补）
    var kinsoku: Bool = true
    /// 中西文自动间距（JS 补）
    var autospace: Bool = true
    /// 音量键翻页：默认关闭。需要给 AVAudioSession 的 outputVolume 装 KVO，
    /// 在未激活会话/部分机型上会直接把进程带走，所以做成显式开关
    var volumeKeys: Bool = false

    init() {}

    /// 手动解码：缺字段就落回默认值，老版本存下来的设置不会因为加字段而整份失效
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = (try? c.decode(Double.self, forKey: .fontSize)) ?? 19
        lineHeight = (try? c.decode(Double.self, forKey: .lineHeight)) ?? 1.8
        fontFamily = (try? c.decode(String.self, forKey: .fontFamily)) ?? "Songti SC"
        indentEM = (try? c.decode(Double.self, forKey: .indentEM)) ?? 2
        paragraphSpacingEM = (try? c.decode(Double.self, forKey: .paragraphSpacingEM)) ?? 0.4
        theme = (try? c.decode(ReaderTheme.self, forKey: .theme)) ?? .paper
        paged = (try? c.decode(Bool.self, forKey: .paged)) ?? true
        kinsoku = (try? c.decode(Bool.self, forKey: .kinsoku)) ?? true
        autospace = (try? c.decode(Bool.self, forKey: .autospace)) ?? true
        volumeKeys = (try? c.decode(Bool.self, forKey: .volumeKeys)) ?? false
    }

    static let storageKey = "reader.settings.v1"

    enum CodingKeys: String, CodingKey {
        case fontSize, lineHeight, fontFamily, indentEM, paragraphSpacingEM
        case theme, paged, kinsoku, autospace, volumeKeys
    }

    static func load() -> ReaderSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let s = try? JSONDecoder().decode(ReaderSettings.self, from: data) else {
            return ReaderSettings()
        }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

// MARK: - 章节

struct Chapter {
    let title: String
    /// EPUB：章节文件 URL；TXT：nil（用 html 直接渲染）
    let fileURL: URL?
    /// TXT / 备用内容
    let html: String
    /// TXT 中本章起始字符偏移，用于精确进度
    let charOffset: Int
}

// MARK: - 阅读位置

struct ReadingLocator: Codable, Equatable {
    var chapterIndex: Int = 0
    /// 章内进度 0...1
    var fraction: Double = 0
    var charOffset: Int = 0

    static let zero = ReadingLocator()
}
