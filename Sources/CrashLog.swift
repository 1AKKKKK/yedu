import Foundation
import SwiftUI

/// 把闪退信息写进沙盒，方便在「设置 → 诊断」里看到
enum CrashLog {
    static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("crash.log")
    }

    static func append(_ text: String) {
        let line = "\n===== \(Date()) =====\n" + text + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    static func text() -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    /// 在 App 启动时安装：Objective-C 异常 + 常见信号
    static func install() {
        NSSetUncaughtExceptionHandler { ex in
            let symbols = ex.callStackSymbols.joined(separator: "\n")
            CrashLog.append("EXCEPTION \(ex.name.rawValue): \(ex.reason ?? "-")\n\(symbols)")
        }
        let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]
        for sig in signals {
            signal(sig) { s in
                let symbols = Thread.callStackSymbols.joined(separator: "\n")
                CrashLog.append("SIGNAL \(s)\n\(symbols)")
                exit(1)
            }
        }
    }
}

struct CrashLogView: View {
    @State private var content = ""

    var body: some View {
        ScrollView {
            Text(content.isEmpty ? "还没有崩溃记录" : content)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .navigationTitle("崩溃日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("清空") {
                    CrashLog.clear()
                    content = ""
                }
            }
        }
        .onAppear { content = CrashLog.text() }
    }
}
