import SwiftUI

@main
struct ReadApp: App {
    @StateObject private var store: LibraryStore
    @StateObject private var notes: HighlightStore

    init() {
        CrashLog.install()
        let s = LibraryStore()
        _store = StateObject(wrappedValue: s)
        _notes = StateObject(wrappedValue: HighlightStore(store: s))
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(store)
                .environmentObject(notes)
                .onOpenURL { url in
                    Task { await store.importFromURL(url) }
                }
        }
    }
}
