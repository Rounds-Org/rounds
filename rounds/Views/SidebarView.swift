//
//  SidebarView.swift
//  rounds
//
//  Left rail: search (chats by content, documents, next steps — typo-tolerant), and every chat grouped
//  by the person it's about, with a live progress dot and an orange "new answer, not viewed" dot.
//  Documents live on Home (DocumentsSection).
//

import SwiftUI
import UniformTypeIdentifiers

enum GroupBy: String, CaseIterable, Identifiable {
    case person, type, date
    var id: String { rawValue }
    var title: String {
        switch self { case .person: "Person"; case .type: "Type"; case .date: "Date" }
    }
    var subtitle: String {
        switch self {
        case .person: "You and your family"
        case .type: "Blood work, imaging, reports…"
        case .date: "When the test was taken"
        }
    }
    var icon: String {
        switch self { case .person: "person.2"; case .type: "doc.on.doc"; case .date: "calendar" }
    }
}

struct SidebarView: View {
    @Environment(AppState.self) private var app
    @State private var importing = false
    @State private var sidebarHeight: CGFloat = 600     // measured, to cap the in-progress tray
    @State private var queueContentHeight: CGFloat = 0  // measured in-progress content height
    @State private var collapsedPeople: Set<String> = []
    @State private var expandedPeople: Set<String> = []  // groups showing ALL their chats (not just the latest few)
    @State private var query = ""
    @State private var results: [SearchHit] = []
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    private let perGroup = 6

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Rounds").zfont(.headline)
                Spacer()
                Button { app.showSettings = true } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Settings")
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)

            searchField

            Button { app.selectHome() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "house").frame(width: 16)
                    Text("Home")
                    Spacer()
                }
                .padding(.vertical, 6).padding(.horizontal, 10).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(app.isHomeActive ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(app.isHomeActive ? Theme.accent : .primary)
            .padding(.horizontal, 10).padding(.bottom, 8)

            HStack(spacing: 8) {
                Button { _ = app.startNewChat() } label: {
                    Label("New chat", systemImage: "square.and.pencil").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                Button { importing = true } label: { Image(systemName: "plus.rectangle.on.folder") }
                    .buttonStyle(.bordered)
                    .help("Add files")
            }
            .controlSize(.large)
            .padding(.horizontal, 12).padding(.bottom, 10)

            Group {
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    SearchResultsList(results: results, query: query)
                } else if app.chats.isEmpty {
                    emptyChats
                } else {
                    chatsByPerson
                }
            }
            .frame(maxHeight: .infinity)

            // UNPROCESSED — the import tray on the bottom, its OWN scroll: sizes to content when
            // small, caps + scrolls internally when large, so it can never push the rest off-screen.
            if !app.processingFiles.isEmpty { processingTray }

            if let update = app.updateAvailable, !app.updateDismissed {
                UpdateChip(update: update)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onHeightChange { sidebarHeight = $0 }
        .background(Theme.panel.opacity(0.5))
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .image, .plainText, .item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { app.beginImport(urls) }
        }
        .background(Theme.bg)   // opaque sidebar (not the translucent default material)
        .onChange(of: app.searchFocusRequest) { _, _ in searchFocused = true }
        .onChange(of: query) { _, _ in runSearch() }
        .onChange(of: app.searchIndex.map(ObjectIdentifier.init)) { _, _ in runSearch() }   // index rebuilt → refresh hits
    }

    // MARK: search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").zfont(.caption).foregroundStyle(.secondary)
            TextField("Search chats, documents… ⌘K", text: $query)
                .textFieldStyle(.plain).zfont(.callout)
                .focused($searchFocused)
                .onKeyPress(.escape) { query = ""; searchFocused = false; return .handled }
                .onSubmit { if let first = results.first { SearchResultsList.open(first, app: app) } }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").zfont(.caption) }
                    .buttonStyle(.borderless).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(searchFocused ? Theme.accent.opacity(0.6) : Theme.hairline))
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    /// Debounced, off-main search over the prebuilt index (typo-tolerant, full chat content).
    private func runSearch() {
        searchTask?.cancel()
        let q = query
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty, let idx = app.searchIndex else { results = []; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            let hits = await Task.detached(priority: .userInitiated) { idx.search(q) }.value
            guard !Task.isCancelled else { return }
            results = hits
        }
    }

    // MARK: chats grouped by person

    /// People with at least one chat, ordered by their most recent chat.
    private var groups: [(person: Person, chats: [ChatSummary])] {
        let byPerson = Dictionary(grouping: app.chats) { app.personForChat($0.id) }
        var out: [(Person, [ChatSummary])] = []
        for (slug, list) in byPerson {
            let p = app.people.first { $0.slug == slug } ?? Person(slug: slug, displayName: slug.capitalized)
            out.append((p, list.sorted { $0.updatedAt > $1.updatedAt }))
        }
        return out.sorted { ($0.1.first?.updatedAt ?? .distantPast) > ($1.1.first?.updatedAt ?? .distantPast) }
    }

    private var chatsByPerson: some View {
        List {
            ForEach(groups, id: \.person.slug) { group in
                let key = group.person.slug
                let collapsed = collapsedPeople.contains(key)
                Section {
                    if !collapsed {
                        let showAll = expandedPeople.contains(key)
                        // Keep a running/unread chat visible even when it's beyond the first few.
                        let visible = showAll ? group.chats : group.chats.enumerated().filter { i, c in
                            i < perGroup || app.isChatStreaming(c.id) || app.isChatUnread(c.id)
                        }.map(\.element)
                        ForEach(visible) { chat in ChatRow(chat: chat) }
                        if group.chats.count > visible.count || showAll && group.chats.count > perGroup {
                            Button(showAll ? "Show less" : "Show \(group.chats.count - visible.count) more") {
                                if showAll { expandedPeople.remove(key) } else { expandedPeople.insert(key) }
                            }
                            .buttonStyle(.plain).zfont(.caption).foregroundStyle(.secondary)
                            .padding(.leading, 22)
                        }
                    }
                } header: {
                    Button {
                        if collapsed { collapsedPeople.remove(key) } else { collapsedPeople.insert(key) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                                .zfont(size: 9).foregroundStyle(.secondary)
                            Text(group.person.slug == "_self" ? "You" : group.person.displayName).lineLimit(1)
                            Spacer()
                            // Collapsed group still signals activity inside it.
                            if collapsed, group.chats.contains(where: { app.isChatStreaming($0.id) }) { PulsingDot() }
                            else if collapsed, group.chats.contains(where: { app.isChatUnread($0.id) }) { UnreadDot() }
                            Text("\(group.chats.count)").zfont(.caption2).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)   // drop the translucent sidebar material…
        .background(Theme.bg)                // …for a solid, opaque panel
    }

    private var emptyChats: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Image(systemName: "bubble.left.and.bubble.right").zfont(size: 24).foregroundStyle(.secondary)
            Text("Your chats will appear here").zfont(.callout).foregroundStyle(.secondary)
            Text("Grouped by who they're about.").zfont(.caption2).foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
    }

    /// The in-progress import tray (bottom region) with its own bounded, independent scroll.
    private var processingTray: some View {
        // Cap proportional to the sidebar height (≥ ~3 rows), but never taller than the content.
        let cap = max(132, sidebarHeight * 0.42)
        let estimate = queueContentHeight > 0 ? queueContentHeight : CGFloat(app.processingFiles.count) * 46
        let height = min(estimate, cap)
        return VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.horizontal, 12).padding(.top, 2)
            HStack(spacing: 6) {
                SectionHeader(title: "Files in progress")
                Spacer()
                Text("\(app.processingFiles.count)")
                    .zfont(.caption2, .medium).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Theme.bg, in: Capsule())
            }
            .padding(.horizontal, 12)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(app.processingFiles) { pf in ProcessingRow(pf: pf) }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                .onHeightChange { queueContentHeight = $0 }
            }
            .frame(height: height)
            .scrollIndicators(.automatic)
        }
        .padding(.bottom, 8)
    }
}

/// Orange "the AI finished here and you haven't looked yet" dot.
struct UnreadDot: View {
    var body: some View {
        Circle().fill(Color.orange).frame(width: 7, height: 7)
            .help("New answer — not viewed yet")
    }
}

private struct ChatRow: View {
    @Environment(AppState.self) private var app
    let chat: ChatSummary

    private var isActive: Bool { app.activeTab == .chat(chat.id) }
    private var unread: Bool { app.isChatUnread(chat.id) }

    var body: some View {
        HStack(spacing: 7) {
            Group {
                if app.isChatStreaming(chat.id) { PulsingDot() }
                else if unread { UnreadDot() }
                else { Circle().fill(Color.clear).frame(width: 7, height: 7) }
            }
            .frame(width: 9)
            Text(app.chatTitle(chat.id))
                .zfont(.callout, unread ? .semibold : .regular)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(Self.short(chat.updatedAt)).zfont(.caption2).foregroundStyle(.tertiary).monospacedDigit()
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture { app.openChat(chat) }
        .listRowBackground(isActive ? Theme.accentSoft : Color.clear)
        .contextMenu {
            Button("Open") { app.openChat(chat) }
            Menu("Move to") {
                ForEach(app.people) { p in
                    Button { app.setChatPerson(chat.id, p.slug) } label: {
                        Label(p.slug == "_self" ? "You" : p.displayName,
                              systemImage: app.personForChat(chat.id) == p.slug ? "checkmark" : "")
                    }
                }
            }
            if unread { Button("Mark as read") { app.markChatSeen(chat.id) } }
            Divider()
            Button("Delete", role: .destructive) { app.deleteChat(chat.id) }
        }
        .help(app.chatTitle(chat.id))
    }

    /// "now", "5m", "3h", "2d", then a date.
    static func short(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        if s < 7 * 86400 { return "\(Int(s / 86400))d" }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// Search results: chats (by content), documents, next steps — each with a snippet, hits in bold.
private struct SearchResultsList: View {
    @Environment(AppState.self) private var app
    let results: [SearchHit]
    let query: String

    var body: some View {
        if results.isEmpty {
            VStack(spacing: 5) {
                Spacer(minLength: 0)
                Image(systemName: "magnifyingglass").zfont(.title3).foregroundStyle(.tertiary)
                Text(app.searchIndex == nil ? "Indexing…" : "Nothing found").zfont(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(results) { hit in
                        Button { Self.open(hit, app: app) } label: { row(hit) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
        }
    }

    private func row(_ hit: SearchHit) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: hit.kind == .chat ? "bubble.left" : (hit.kind == .document ? "doc.text" : "checklist"))
                .zfont(.caption).foregroundStyle(hit.kind == .document ? Theme.accent : .secondary)
                .frame(width: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Self.highlight(hit.kind == .chat ? app.chatTitle(hit.refId) : hit.title, hit.terms))
                        .zfont(.callout).lineLimit(1)
                    if hit.kind == .chat, app.isChatStreaming(hit.refId) { PulsingDot() }
                    else if hit.kind == .chat, app.isChatUnread(hit.refId) { UnreadDot() }
                }
                if !hit.snippet.isEmpty {
                    Text(Self.highlight(hit.snippet, hit.terms))
                        .zfont(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(kindLabel(hit)).zfont(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel.opacity(0.001)))
    }

    private func kindLabel(_ hit: SearchHit) -> String {
        switch hit.kind {
        case .chat:
            let p = app.personForChat(hit.refId)
            let who = p == "_self" ? "You" : (app.people.first { $0.slug == p }?.displayName ?? p)
            return "Chat · \(who)"
        case .document: return "Document"
        case .step: return "Next step"
        }
    }

    static func open(_ hit: SearchHit, app: AppState) {
        switch hit.kind {
        case .chat: app.selectTab(.chat(hit.refId))
        case .document: if let d = app.documents.first(where: { $0.relativePath == hit.refId }) { app.openFile(d) }
        case .step: app.selectHome()
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

private struct ProcessingRow: View {
    @Environment(AppState.self) private var app
    let pf: ProcessingFile

    var body: some View {
        HStack(spacing: 8) {
            if pf.isActive {
                ProgressView().controlSize(.mini).frame(width: 16)
            } else if pf.status == .error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn).frame(width: 16)
            } else {
                Image(systemName: "clock").foregroundStyle(.secondary).frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(pf.fileName).zfont(.caption).lineLimit(1)
                Text(pf.label).zfont(.caption2).foregroundStyle(pf.status == .error ? Theme.warn : .secondary)
            }
            Spacer()
            if pf.status == .error {
                Button { app.retryProcessing(pf) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Retry")
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(Theme.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { if let c = pf.chatId { app.selectTab(.chat(c)) } }
        .contextMenu {
            Button("Open in Preview") { NSWorkspace.shared.open(pf.url) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([pf.url]) }
        }
    }
}

struct DocRow: View {
    @Environment(AppState.self) private var app
    let doc: MedDocument
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: doc.isImaging ? "photo" : "doc.text")
                .foregroundStyle(doc.isImaging ? Theme.warn : Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(doc.displayName)
                    .zfont(.callout).lineLimit(1)
                HStack(spacing: 6) {
                    if let d = doc.testDate { Text(d).zfont(.caption2).foregroundStyle(.secondary) }
                    if let lab = doc.sourceLab { Text(lab).zfont(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                }
            }
            Spacer()
            if doc.isImaging && !doc.hasTextReport {
                Pill(text: "image only", color: Theme.warn)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { app.openFile(doc) }
        .background(app.activeTab == .file(doc.relativePath) ? Theme.accentSoft : .clear)
        .contextMenu {
            Button("Open") { app.openFile(doc) }
            Button("Open in Preview app") { app.openInExternalPreview(doc) }
            Button("Reveal in Finder") { app.revealInFinder(doc) }
            Divider()
            Button("Delete…", role: .destructive) { onDelete() }
        }
        .help(doc.summary ?? doc.fileName)
    }
}
