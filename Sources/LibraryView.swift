import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var notes: HighlightStore
    @State private var showImporter = false
    @State private var query = ""
    @State private var filter: Book.ReadState?
    @State private var openBook: Book?
    @State private var showSettings = false

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 18)]

    var filtered: [Book] {
        store.books.filter { book in
            guard filter == nil || book.state == filter! else { return false }
            guard !query.isEmpty else { return true }
            return book.title.localizedCaseInsensitiveContains(query)
                || book.author.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                filterBar
                if filtered.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(filtered) { book in
                            cell(book)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                }
            }
            .navigationTitle("书架")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .searchable(text: $query, prompt: "书名或作者")
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: importerTypes,
                allowsMultipleSelection: true
            ) { result in
                guard case .success(let urls) = result else { return }
                Task {
                    for url in urls { await store.importFromURL(url) }
                }
            }
        }
        .navigationViewStyle(.stack)
        .fullScreenCover(item: $openBook) { book in
            ReaderContainer(book: book)
                .environmentObject(store)
                .environmentObject(notes)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(store)
        }
    }

    private var importerTypes: [UTType] {
        var types: [UTType] = [.plainText]
        if let epub = UTType("org.idpf.epub-container") { types.append(epub) }
        types.append(.data)
        return types
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(nil, "全部")
                ForEach(Book.ReadState.allCases, id: \.self) { s in
                    chip(s, s.title)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
    }

    private func chip(_ state: Book.ReadState?, _ title: String) -> some View {
        let active = filter == state
        return Button {
            filter = state
        } label: {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(active ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10))
                .foregroundColor(active ? .accentColor : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func cell(_ book: Book) -> some View {
        Button {
            CrashLog.append("tap cover: \(book.title) [\(book.format.rawValue)] file=\(book.fileName)")
            openBook = book
        } label: {
            cellBody(book)
        }
        .buttonStyle(.plain)
        .contextMenu {
            ForEach(Book.ReadState.allCases, id: \.self) { s in
                Button(s.title) { store.setState(s, for: book) }
            }
            Button(role: .destructive) {
                store.delete(book)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func cellBody(_ book: Book) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                cover(book)
                    .frame(width: 104, height: 148)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                if book.progress > 0.001 {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.85))
                            .frame(width: geo.size.width * book.progress, height: 3)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            Text(book.title)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(book.author.isEmpty ? book.format.rawValue.uppercased() : book.author)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(width: 104, alignment: .leading)
    }

    @ViewBuilder
    private func cover(_ book: Book) -> some View {
        if let url = store.coverURL(for: book), let ui = UIImage(contentsOfFile: url.path) {
            Image(uiImage: ui).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(colors: [Color.secondary.opacity(0.25), Color.secondary.opacity(0.12)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(String(book.title.prefix(1)))
                    .font(.system(size: 34, weight: .semibold, design: .serif))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "books.vertical")
                .font(.system(size: 46, weight: .light))
                .foregroundColor(.secondary)
            Text("书架还是空的")
                .font(.headline)
            Text("点右上角 ＋ 从「文件」导入 EPUB / TXT\n也可以把书放进「文件」App 的 我的 iPhone → 夜读 → Books")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            if store.importing {
                ProgressView().padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }
}
