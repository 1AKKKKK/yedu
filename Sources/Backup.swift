import Foundation
import ZIPFoundation

/// 沙盒备份：Documents 下的书、封面、书库索引、笔记打包成一个 zip，保留最近 N 份
struct BackupManager {
    let store: LibraryStore

    private var fm: FileManager { .default }
    var backupDir: URL { store.backupDir }

    func existing() -> [URL] {
        let items = (try? fm.contentsOfDirectory(at: backupDir,
                                                includingPropertiesForKeys: [.creationDateKey],
                                                options: [.skipsHiddenFiles])) ?? []
        return items.filter { $0.pathExtension == "zip" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return da > db
            }
    }

    @discardableResult
    func create(keep: Int = 5) throws -> URL {
        let staging = fm.temporaryDirectory
            .appendingPathComponent("yedu-backup-\(UUID().uuidString)", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // 书库索引 + 笔记
        for name in ["library.json", "notes.json"] {
            let src = store.docs.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path) {
                try fm.copyItem(at: src, to: staging.appendingPathComponent(name))
            }
        }
        // 书与封面
        for (name, dir) in [("Books", store.booksDir), ("Covers", store.coversDir)] {
            guard fm.fileExists(atPath: dir.path) else { continue }
            let dst = staging.appendingPathComponent(name, isDirectory: true)
            try fm.copyItem(at: dir, to: dst)
        }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let name = "backup-\(stamp.string(from: Date())).zip"
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let dest = backupDir.appendingPathComponent(name)
        try? fm.removeItem(at: dest)
        try fm.zipItem(at: staging, to: dest, shouldKeepParent: false)
        prune(keep: keep)
        return dest
    }

    func prune(keep: Int) {
        let all = existing()
        for url in all.dropFirst(max(1, keep)) {
            try? fm.removeItem(at: url)
        }
    }

    /// 从备份恢复：覆盖书库/笔记后，由调用方重新 load 索引
    func restore(from zipURL: URL) throws {
        let staging = fm.temporaryDirectory
            .appendingPathComponent("yedu-restore-\(UUID().uuidString)", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        guard let archive = Archive(url: zipURL, accessMode: .read) else {
            throw NSError(domain: "yedu.backup", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "备份文件打不开"])
        }
        for entry in archive {
            _ = try archive.extract(entry, to: staging.appendingPathComponent(entry.path))
        }

        for name in ["library.json", "notes.json"] {
            let src = staging.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = store.docs.appendingPathComponent(name)
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: src, to: dst)
        }
        for (name, dir) in [("Books", store.booksDir), ("Covers", store.coversDir)] {
            let src = staging.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: src.path) else { continue }
            try? fm.removeItem(at: dir)
            try fm.copyItem(at: src, to: dir)
        }
    }
}
