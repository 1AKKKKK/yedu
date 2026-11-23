import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var backups: [URL] = []
    @State private var message = ""
    @State private var busy = false
    @State private var showRestorePicker = false
    @State private var settings = ReaderSettings.load()

    private var manager: BackupManager { BackupManager(store: store) }

    var body: some View {
        NavigationView {
            Form {
                Section("阅读默认") {
                    HStack {
                        Text("字号")
                        Slider(value: Binding(
                            get: { settings.fontSize },
                            set: { settings.fontSize = $0.rounded() }
                        ), in: 13...30, step: 1)
                        Text("\(Int(settings.fontSize))").monospacedDigit()
                    }
                    HStack {
                        Text("行距")
                        Slider(value: $settings.lineHeight, in: 1.3...2.4, step: 0.05)
                        Text(String(format: "%.2f", settings.lineHeight)).monospacedDigit()
                    }
                    Picker("字体", selection: $settings.fontFamily) {
                        Text("宋体").tag("Songti SC")
                        Text("楷体").tag("Kaiti SC")
                        Text("系统").tag("-apple-system")
                    }
                    Toggle("翻页模式（关闭为滚动）", isOn: $settings.paged)
                    Toggle("中西文自动间距", isOn: $settings.autospace)
                    Toggle("避头尾", isOn: $settings.kinsoku)
                }

                Section("备份") {
                    Button {
                        runBackup()
                    } label: {
                        HStack {
                            Text("立即备份")
                            Spacer()
                            if busy { ProgressView() }
                        }
                    }
                    .disabled(busy)

                    ForEach(backups, id: \.self) { url in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.lastPathComponent).font(.footnote)
                                Text(fileSize(url)).font(.caption2).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("恢复") { restore(url) }
                                .buttonStyle(.borderless)
                                .font(.footnote)
                        }
                    }
                    .onDelete { idx in
                        for i in idx where backups.indices.contains(i) {
                            try? FileManager.default.removeItem(at: backups[i])
                        }
                        refresh()
                    }

                    Button("从文件恢复…") { showRestorePicker = true }
                }

                Section("说明") {
                    Text("书放在「文件 → 我的 iPhone → 夜读 → Books」，备份在 Backup 目录，最多保留 5 份。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    if !message.isEmpty {
                        Text(message).font(.footnote).foregroundColor(.accentColor)
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        settings.save()
                        dismiss()
                    }
                }
            }
            .onAppear(perform: refresh)
            .fileImporter(isPresented: $showRestorePicker,
                          allowedContentTypes: [.zip],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    restore(url)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func refresh() {
        backups = manager.existing()
    }

    private func runBackup() {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            var msg = ""
            do {
                let url = try manager.create()
                msg = "已备份 " + url.lastPathComponent
            } catch {
                msg = "备份失败：" + error.localizedDescription
            }
            DispatchQueue.main.async {
                busy = false
                message = msg
                refresh()
            }
        }
    }

    private func restore(_ url: URL) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            var msg = ""
            do {
                try manager.restore(from: url)
                msg = "已从备份恢复，请重启 App 完成刷新"
            } catch {
                msg = "恢复失败：" + error.localizedDescription
            }
            DispatchQueue.main.async {
                busy = false
                message = msg
                store.load()
            }
        }
    }

    private func fileSize(_ url: URL) -> String {
        let n = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}
