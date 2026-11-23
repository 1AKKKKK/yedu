import Foundation
import SwiftUI
import UIKit

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

    static func exists() -> Bool {
        FileManager.default.fileExists(atPath: url.path)
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
    @State private var copied = false
    @State private var showShare = false

    private var bodyText: String {
        content.isEmpty ? "还没有日志。\n\n（如果刚点开书就闪退，重启 App 后再回来这里看。）" : content
    }

    var body: some View {
        ScrollView {
            Text(bodyText)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .navigationTitle("崩溃日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button(copied ? "已复制" : "复制") {
                    UIPasteboard.general.string = bodyText
                    copied = true
                }
                .disabled(content.isEmpty)

                Menu {
                    Button {
                        showShare = true
                    } label: {
                        Label("导出为文件 / 分享", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        CrashLog.clear()
                        content = ""
                        copied = false
                    } label: {
                        Label("清空日志", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(items: shareItems)
        }
        .onAppear { content = CrashLog.text() }
    }

    private var shareItems: [Any] {
        if CrashLog.exists() { return [CrashLog.url] }
        return [bodyText.isEmpty ? "no log" : bodyText]
    }
}
