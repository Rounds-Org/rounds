//
//  CommandPalette.swift
//  rounds
//
//  ⌘K — one box for everything (Yab-style): recent chats, typo-tolerant full-text search over chats /
//  documents / next steps (SearchIndex), app actions, and — when you just type a question — "Ask",
//  which starts a new chat with it. ↑↓ move, ↵ opens, esc closes.
//

import SwiftUI

struct CommandPalette: View {
    @Environment(AppState.self) private var app
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var selection = 0
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focused: Bool
    @State private var keyMonitor: Any?

    private struct Item: Identifiable {
        enum Kind { case recent(String), hit(SearchHit), ask(String), action(PaletteAction) }
        let id: String
        let kind: Kind
    }

    private struct PaletteAction {
        let title: String
        let icon: String
        var shortcut = ""
        var keywords = ""
        let run: (AppState) -> Void
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.16).ignoresSafeArea()
                .onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").zfont(size: 18, weight: .medium).foregroundStyle(.tertiary)
                    TextField("Search or ask anything", text: $query)
                        .textFieldStyle(.plain)
                        .zfont(size: 20)
                        .focused($focused)
                        .onSubmit { run(selection) }
                }
                .padding(.horizontal, 20).padding(.vertical, 17)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(sections, id: \.title) { section in
                                Text(section.title).zfont(.caption, .semibold).foregroundStyle(.tertiary)
                                    .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 3)
                                ForEach(section.items) { item in
                                    let i = index(of: item)
                                    row(item, selected: i == selection)
                                        .id(item.id)
                                        .onTapGesture { run(i) }
                                        .onHover { if $0 { selection = i } }
                                }
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 440)
                    .onChange(of: selection) { _, s in
                        if s < flat.count { proxy.scrollTo(flat[s].id) }
                    }
                }
                Divider()
                HStack(spacing: 14) {
                    Text("↑↓ to move"); Text("↵ to open")
                    Spacer()
                    Text("esc")
                }
                .zfont(.caption).foregroundStyle(.tertiary)
                .padding(.horizontal, 20).padding(.vertical, 9)
            }
            .frame(width: 640)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.hairline))
            .shadow(color: .black.opacity(0.25), radius: 40, y: 20)
            .padding(.top, 90)
        }
        .onAppear {
            focused = true
            // The text field's editor swallows ↑ ↓ esc before SwiftUI sees them — catch them first.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                switch e.keyCode {
                case 125: move(1); return nil        // ↓
                case 126: move(-1); return nil       // ↑
                case 53: close(); return nil         // esc
                default: return e
                }
            }
        }
        .onDisappear { if let m = keyMonitor { NSEvent.removeMonitor(m) }; keyMonitor = nil }
        .onChange(of: query) { _, _ in selection = 0; runSearch() }
    }

    // MARK: content

    private struct Section { let title: String; let items: [Item] }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var sections: [Section] {
        var out: [Section] = []
        if trimmed.isEmpty {
            let recent = app.chats.prefix(5).map { Item(id: "r:" + $0.id, kind: .recent($0.id)) }
            if !recent.isEmpty { out.append(Section(title: "Recent", items: recent)) }
            out.append(Section(title: "Actions", items: actions(filter: "").map { Item(id: "a:" + $0.title, kind: .action($0)) }))
        } else {
            let results = hits.prefix(8).map { Item(id: "h:" + $0.id, kind: .hit($0)) }
            if !results.isEmpty { out.append(Section(title: "Results", items: Array(results))) }
            out.append(Section(title: results.isEmpty ? "Nothing found" : "Or",
                               items: [Item(id: "ask", kind: .ask(trimmed))]))
            let acts = actions(filter: trimmed)
            if !acts.isEmpty { out.append(Section(title: "Actions", items: acts.map { Item(id: "a:" + $0.title, kind: .action($0)) })) }
        }
        return out
    }

    private var flat: [Item] { sections.flatMap(\.items) }
    private func index(of item: Item) -> Int { flat.firstIndex { $0.id == item.id } ?? 0 }

    private func actions(filter: String) -> [PaletteAction] {
        var all: [PaletteAction] = [
            PaletteAction(title: "New chat", icon: "square.and.pencil", shortcut: "⌘N") { _ = $0.startNewChat() },
            PaletteAction(title: "Add files…", icon: "plus.rectangle.on.folder", keywords: "import upload document") { $0.showImporter = true },
            PaletteAction(title: "Go Home", icon: "house") { $0.selectHome() },
            PaletteAction(title: "What's new", icon: "sparkles", keywords: "changelog release") { $0.selectTab(.whatsNew) },
            PaletteAction(title: "Check for updates", icon: "arrow.clockwise", keywords: "update upgrade") { $0.checkForUpdate() },
            PaletteAction(title: "Keyboard shortcuts", icon: "command", keywords: "keys hotkeys") { $0.showShortcuts = true },
            PaletteAction(title: "Settings", icon: "gearshape", shortcut: "⌘,", keywords: "preferences language") { $0.showSettings = true },
        ]
        // Model switching shows up when you type (e.g. "opus", "model").
        if !filter.isEmpty {
            for m in app.availableModels + app.olderModels {
                all.append(PaletteAction(title: "Use \(m.short)", icon: app.selectedModel == m ? "checkmark" : "cpu",
                                         keywords: "model switch \(m.rawValue)") { $0.selectedModel = m })
            }
        }
        guard !filter.isEmpty else { return all.filter { !$0.title.hasPrefix("Use ") } }
        let f = SearchIndex.normalize(filter)
        return all.filter { SearchIndex.normalize($0.title + " " + $0.keywords).contains(f) }
    }

    @ViewBuilder private func row(_ item: Item, selected: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            switch item.kind {
            case .recent(let id):
                status(id).frame(width: 18).padding(.top, 6)
                Text(app.chatTitle(id)).zfont(.body).lineLimit(1)
                Spacer(minLength: 8)
                Text(personName(app.personForChat(id))).zfont(.caption).foregroundStyle(.tertiary)
            case .hit(let h):
                Image(systemName: h.kind == .chat ? "bubble.left" : (h.kind == .document ? "doc.text" : "checklist"))
                    .zfont(size: 13).foregroundStyle(.secondary).frame(width: 18).padding(.top, 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.highlight(h.kind == .chat ? app.chatTitle(h.refId) : h.title, h.terms))
                        .zfont(.body).lineLimit(1)
                    if !h.snippet.isEmpty {
                        Text(Self.highlight(h.snippet, h.terms)).zfont(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Text(kindLabel(h)).zfont(.caption).foregroundStyle(.tertiary).padding(.top, 2)
            case .ask(let q):
                Image(systemName: "sparkle").zfont(size: 13).foregroundStyle(Theme.accent).frame(width: 18).padding(.top, 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ask: «\(q)»").zfont(.body, .medium).lineLimit(1)
                    Text("Starts a new chat with this question").zfont(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text("↵").zfont(.caption).foregroundStyle(.tertiary).padding(.top, 2)
            case .action(let a):
                Image(systemName: a.icon).zfont(size: 13).foregroundStyle(.secondary).frame(width: 18).padding(.top, 2)
                Text(a.title).zfont(.body)
                Spacer(minLength: 8)
                Text(a.shortcut).zfont(.caption).foregroundStyle(.tertiary).padding(.top, 2)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Theme.rowActive : .clear))
        .contentShape(Rectangle())
    }

    @ViewBuilder private func status(_ id: String) -> some View {
        if app.isChatStreaming(id) { PulsingDot() }
        else if app.isChatUnread(id) { UnreadDot() }
        else { Image(systemName: "bubble.left").zfont(size: 12).foregroundStyle(.secondary) }
    }

    private func personName(_ slug: String) -> String {
        slug == "_self" ? "You" : (app.people.first { $0.slug == slug }?.displayName ?? slug)
    }

    private func kindLabel(_ h: SearchHit) -> String {
        switch h.kind {
        case .chat: return personName(app.personForChat(h.refId))
        case .document: return "Document"
        case .step: return "Next step"
        }
    }

    // MARK: behavior

    private func move(_ d: Int) {
        let n = flat.count
        guard n > 0 else { return }
        selection = (selection + d + n) % n
    }

    private func run(_ i: Int) {
        guard i < flat.count else { return }
        let item = flat[i]
        close()
        switch item.kind {
        case .recent(let id): app.selectTab(.chat(id))
        case .hit(let h):
            switch h.kind {
            case .chat: app.selectTab(.chat(h.refId))
            case .document: if let d = app.documents.first(where: { $0.relativePath == h.refId }) { app.openFile(d) }
            case .step: app.selectHome()
            }
        case .ask(let q):
            let id = app.startNewChat()
            app.runtime(id).send(q, references: [])
        case .action(let a): a.run(app)
        }
    }

    private func close() { app.showPalette = false }

    /// Debounced, off-main search over the prebuilt index.
    private func runSearch() {
        searchTask?.cancel()
        let q = trimmed
        guard !q.isEmpty, let idx = app.searchIndex else { hits = []; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 70_000_000)
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) { idx.search(q) }.value
            guard !Task.isCancelled else { return }
            hits = found
        }
    }

    /// Bold every occurrence of the matched words (case/diacritic-insensitive).
    static func highlight(_ text: String, _ terms: [String]) -> AttributedString {
        var a = AttributedString(text)
        for t in terms where t.count >= 2 {
            var search = a.startIndex..<a.endIndex
            while let r = a[search].range(of: t, options: [.caseInsensitive, .diacriticInsensitive]) {
                a[r].inlinePresentationIntent = .stronglyEmphasized
                a[r].foregroundColor = .primary
                search = r.upperBound..<a.endIndex
            }
        }
        return a
    }
}

/// ⌘/ — the keyboard shortcuts sheet (from the Rounds menu / palette).
struct ShortcutsSheet: View {
    @Environment(AppState.self) private var app
    private let rows: [(String, String)] = [
        ("⌘K", "Search, ask, or run a command"), ("⌘N", "New chat"), ("⌘W", "Close the open chat or document"),
        ("⌘[  ⌘]", "Back / forward"), ("⌃⇥", "Switch to the previous tab"), ("⌘,", "Settings"),
        ("⌘+  ⌘−  ⌘0", "Text size"),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keyboard shortcuts").zfont(.headline)
            ForEach(rows, id: \.0) { k, v in
                HStack {
                    Text(v).zfont(.body)
                    Spacer()
                    Text(k).zfont(.callout, design: .monospaced).foregroundStyle(.secondary)
                }
            }
            HStack { Spacer(); Button("Done") { app.showShortcuts = false }.keyboardShortcut(.defaultAction) }
        }
        .padding(22).frame(width: 380)
    }
}
