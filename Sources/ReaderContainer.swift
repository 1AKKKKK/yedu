import SwiftUI
import UIKit

/// 打开一本书：构建内容 → 渲染 → 回收位置
struct ReaderContainer: View {
    let book: Book

    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var notes: HighlightStore
    @Environment(\.dismiss) private var dismiss

    @State private var content: BookContent?
    @State private var settings: ReaderSettings = ReaderSettings.load()
    @State private var loadError: String?
    @State private var showPanel = false
    @State private var chapterIndex = 0
    @State private var sheet: SheetKind?
    @State private var searchText = ""
    @State private var searchResult: String = ""
    @State private var pendingSelection: Selection?
    @State private var shareItems: [Any] = []
    @State private var showShare = false
    @State private var matchCount = 0
    @State private var matchCursor = 0
    @State private var noteText = ""
    @State private var showNote = false
    @State private var didLoad = false

    private let proxy = ReaderProxy()
    private let volumeWatcher = VolumeKeyWatcher()

    struct Selection: Equatable {
        var start: Int
        var end: Int
        var text: String
    }

    enum SheetKind: String, Identifiable {
        case toc, notes, search
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            Color(UIColor(hex: settings.theme.background)).ignoresSafeArea()

            if let content = content {
                ReaderView(
                    content: content,
                    settings: settings,
                    locator: ReadingLocator(chapterIndex: book.locatorChapter,
                                            fraction: book.locatorFraction),
                    highlights: notes.highlights(bookID: book.id, chapter: chapterIndex),
                    proxy: proxy,
                    onLocatorChange: { loc in
                        chapterIndex = loc.chapterIndex
                        store.updateLocator(loc, for: book,
                                            chapterCount: content.chapters.count)
                    },
                    onTapCenter: { showPanel.toggle() },
                    onSelection: { s, e, t in
                        if s < 0 { searchResult = "没找到"; return }
                        pendingSelection = Selection(start: s, end: e, text: t)
                    },
                    onMatches: { n in
                        matchCount = n
                        matchCursor = n > 0 ? 1 : 0
                        searchResult = n > 0 ? "共 \(n) 条" : "没找到"
                    },
                    onNoteref: { text in
                        noteText = text
                        showNote = true
                    }
                )
                .ignoresSafeArea()
                .background(volumeHost)
            } else if let err = loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(err).font(.footnote).multilineTextAlignment(.center)
                    Button("返回") { dismiss() }.font(.footnote)
                }
                .padding(30)
            } else {
                ProgressView().tint(settings.theme.isDark ? .white : .black)
            }

            VStack {
                if showPanel { panel.transition(.move(edge: .top)) }
                Spacer()
            }
            .animation(.easeInOut(duration: 0.18), value: showPanel)
        }
        .statusBarHidden(true)
        .preferredColorScheme(settings.theme.isDark ? .dark : .light)
        .onAppear {
            chapterIndex = book.locatorChapter
            load()
            volumeWatcher.onStep = { d in proxy.turn(d) }
        }
        .onDisappear {
            settings.save()
            if let c = content {
                store.updateLocator(ReadingLocator(chapterIndex: chapterIndex,
                                                   fraction: book.locatorFraction),
                                    for: book, chapterCount: c.chapters.count)
            }
        }
        .sheet(item: $sheet) { kind in
            switch kind {
            case .toc: tocSheet
            case .notes: notesSheet
            case .search: searchSheet
            }
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(items: shareItems)
        }
        .confirmationDialog("添加高亮", isPresented: selectionBinding, titleVisibility: .visible) {
            ForEach(HighlightColor.allCases) { c in
                Button(c.title) { addHighlight(c) }
            }
            Button("取消", role: .cancel) { pendingSelection = nil }
        } message: {
            Text(pendingSelection.map { String($0.text.prefix(60)) } ?? "")
        }
        .alert("注释", isPresented: $showNote) {
            Button("好", role: .cancel) { showNote = false }
        } message: {
            Text(noteText)
        }
    }

    private var selectionBinding: Binding<Bool> {
        Binding(get: { pendingSelection != nil },
                set: { if !$0 { pendingSelection = nil } })
    }

    // MARK: 音量键（默认关闭，见 ReaderSettings.volumeKeys）

    @ViewBuilder
    private var volumeHost: some View {
        if settings.volumeKeys {
            VolumeKeyHost(watcher: volumeWatcher)
                .frame(width: 0, height: 0)
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    // MARK: 顶部面板

    private var panel: some View {
        VStack(spacing: 14) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.title3)
                }
                Spacer()
                Text(book.title).font(.subheadline).lineLimit(1)
                Spacer()
                Button { showPanel = false } label: {
                    Image(systemName: "xmark").font(.footnote)
                }
            }
            .padding(.horizontal, 20)

            HStack(spacing: 20) {
                Button { sheet = .toc } label: { Image(systemName: "list.bullet") }
                Button { sheet = .search } label: { Image(systemName: "magnifyingglass") }
                Button { sheet = .notes } label: { Image(systemName: "highlighter") }
                Button { toggleBookmark() } label: {
                    Image(systemName: "bookmark")
                }
                Spacer()
                Button {
                    settings.fontSize = max(13, settings.fontSize - 1)
                    settings.save()
                } label: { Image(systemName: "textformat.size.smaller") }
                Button {
                    settings.fontSize = min(30, settings.fontSize + 1)
                    settings.save()
                } label: { Image(systemName: "textformat.size.larger") }
                Button {
                    settings.paged.toggle()
                    settings.save()
                } label: { Image(systemName: settings.paged ? "book" : "list.bullet.rectangle") }
            }
            .font(.title3)
            .foregroundColor(settings.theme.isDark ? .white : .black)
            .padding(.horizontal, 20)

            HStack(spacing: 14) {
                ForEach(ReaderTheme.allCases, id: \.self) { t in
                    Button {
                        settings.theme = t
                        settings.save()
                    } label: {
                        Circle()
                            .fill(Color(UIColor(hex: t.background)))
                            .frame(width: 24, height: 24)
                            .overlay(Circle().stroke(Color.secondary.opacity(0.5), lineWidth: 1))
                    }
                }
                Spacer()
                Text("\(chapterIndex + 1)/\(content?.chapters.count ?? 0)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .padding(.top, 8)
        .background((settings.theme.isDark ? Color.black : Color.white)
                        .opacity(0.94)
                        .ignoresSafeArea(edges: .top))
    }

    // MARK: 目录 / 搜索 / 笔记

    private var tocSheet: some View {
        NavigationView {
            List {
                if let c = content {
                    ForEach(Array(c.chapters.enumerated()), id: \.offset) { idx, ch in
                        Button {
                            chapterIndex = idx
                            proxy.jump(to: idx)
                            sheet = nil
                        } label: {
                            HStack {
                                Text(ch.title).lineLimit(2)
                                Spacer()
                                if idx == chapterIndex {
                                    Image(systemName: "arrowtriangle.left.fill")
                                        .font(.caption2).foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
    }

    private var searchSheet: some View {
        NavigationView {
            VStack(spacing: 16) {
                HStack {
                    TextField("本章内搜索", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                    Button("搜索") {
                        searchResult = ""
                        matchCount = 0
                        proxy.search(searchText)
                    }
                    .disabled(searchText.isEmpty)
                }
                .padding(.horizontal)
                if matchCount > 0 {
                    HStack(spacing: 16) {
                        Button {
                            proxy.step(-1)
                            matchCursor = matchCursor > 1 ? matchCursor - 1 : matchCount
                        } label: { Image(systemName: "chevron.up") }
                        Text("\(matchCursor)/\(matchCount)")
                            .font(.footnote).monospacedDigit()
                        Button {
                            proxy.step(1)
                            matchCursor = matchCursor < matchCount ? matchCursor + 1 : 1
                        } label: { Image(systemName: "chevron.down") }
                    }
                } else if !searchResult.isEmpty {
                    Text(searchResult).font(.footnote).foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.top, 12)
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { sheet = nil }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var notesSheet: some View {
        NavigationView {
            List {
                let hs = notes.highlights(for: book.id)
                if hs.isEmpty {
                    Text("还没有笔记。在正文里长按选中文字即可高亮。")
                        .font(.footnote).foregroundColor(.secondary)
                }
                ForEach(hs) { h in
                    Button {
                        chapterIndex = h.chapterIndex
                        proxy.jump(to: h.chapterIndex)
                        sheet = nil
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(h.text).font(.callout).lineLimit(3)
                            if !h.note.isEmpty {
                                Text(h.note).font(.caption).foregroundColor(.secondary)
                            }
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color(UIColor(hex: h.color.hex)))
                                    .frame(width: 8, height: 8)
                                Text("第 \(h.chapterIndex + 1) 章")
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .onDelete { idx in
                    let list = notes.highlights(for: book.id)
                    for i in idx where list.indices.contains(i) {
                        notes.delete(list[i])
                    }
                }
            }
            .navigationTitle("笔记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("导出 Markdown") { export(true) }
                        Button("导出纯文本") { export(false) }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { sheet = nil }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: 动作

    private func addHighlight(_ color: HighlightColor) {
        guard let sel = pendingSelection else { return }
        let chapter = content?.chapters.indices.contains(chapterIndex) == true
            ? content!.chapters[chapterIndex].title : ""
        notes.add(Highlight(bookID: book.id,
                            chapterIndex: chapterIndex,
                            start: sel.start,
                            end: sel.end,
                            text: sel.text,
                            color: color,
                            note: chapter.isEmpty ? "" : ""))
        pendingSelection = nil
    }

    private func toggleBookmark() {
        let preview = content?.chapters.indices.contains(chapterIndex) == true
            ? content!.chapters[chapterIndex].title : ""
        notes.toggleBookmark(bookID: book.id,
                             chapter: chapterIndex,
                             fraction: book.locatorFraction,
                             preview: preview)
    }

    private func export(_ markdown: Bool) {
        guard let url = notes.export(book: book, markdown: markdown) else { return }
        shareItems = [url]
        showShare = true
    }

    // MARK: 加载

    private func load() {
        guard !didLoad else { return }
        didLoad = true

        let url = store.fileURL(for: book)
        let cache = store.extractDir
        let title = book.title
        let format = book.format

        CrashLog.append("reader load begin: \(title) format=\(format.rawValue)")

        // 解包一整本书（EPUB 动辄上百兆条目）必须离开主线程，
        // 否则 onAppear 里同步解压会被看门狗杀掉 —— 表现就是「点开就闪退」且没有崩溃日志
        DispatchQueue.global(qos: .userInitiated).async {
            var built: BookContent?
            var failure: String?

            switch format {
            case .epub:
                built = EPUBContent(url: url, title: title, cacheRoot: cache)
            case .txt:
                do {
                    let text = try TextFile.text(at: url)
                    built = TXTContent(text: text, title: title)
                } catch {
                    // 注意：catch 里的 error 是捕获到的 Error（不可变），
                    // 不能拿来做局部变量名，否则编译器报 "cannot assign to value: 'error' is immutable"
                    let reason = error.localizedDescription
                    failure = "读取失败：" + reason
                }
            }

            if let c = built, c.chapters.isEmpty {
                failure = "这本书解析出 0 个章节，可能文件损坏"
                built = nil
            }

            DispatchQueue.main.async {
                CrashLog.append("reader load done: chapters=\(built?.chapters.count ?? -1) err=\(failure ?? "-")")
                content = built
                loadError = failure
            }
        }
    }
}

// MARK: - 分享

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
