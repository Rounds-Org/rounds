//
//  SidebarView.swift
//  rounds
//
//  The left rail IS the tab strip (Yab-style; there's no top tab bar): ← →, the "where you are" pill
//  (⌘K palette), the Rounds menu, Home + open documents, then every chat — most recent activity first,
//  filterable by person — with a live progress dot and an orange "new answer, not viewed" dot.
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
    @State private var sidebarHeight: CGFloat = 600     // measured, to cap the in-progress tray
    @State private var queueContentHeight: CGFloat = 0  // measured in-progress content height
    @AppStorage("rounds.sidebar.personFilter") private var personFilter = ""   // "" = everyone

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            chrome
            WherePill()
                .padding(.horizontal, 10).padding(.bottom, 8)
            RoundsMenu()
                .padding(.horizontal, 6)

            SidebarRow(icon: "house", title: "Home", active: app.isHomeActive) { app.selectHome() }
                .padding(.horizontal, 6)
            // Open documents and "What's new" are tabs too — they live here (no top tab bar).
            ForEach(app.openTabs.filter { $0 != .home && !isChat($0) }, id: \.id) { item in
                OpenItemRow(item: item).padding(.horizontal, 6)
            }

            Divider().padding(.horizontal, 14).padding(.vertical, 8)

            chatsHeader
            chatList
                .frame(maxHeight: .infinity)

            SidebarRow(icon: "plus", title: "New chat", active: false, muted: true) { _ = app.startNewChat() }
                .padding(.horizontal, 6).padding(.top, 2)

            if !app.processingFiles.isEmpty { processingTray }

            if let update = app.updateAvailable, !app.updateDismissed {
                UpdateNudge(update: update)
            }
        }
        .padding(.bottom, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .onHeightChange { sidebarHeight = $0 }
        .background(Theme.canvas)
    }

    private func isChat(_ item: AppState.CenterItem) -> Bool { if case .chat = item { return true }; return false }

    /// Top row in the (hidden) title bar: room for the traffic lights, then ← →.
    private var chrome: some View {
        HStack(spacing: 2) {
            Spacer()
            navButton("chevron.left", enabled: app.canGoBack, help: "Back (⌘[)") { app.goBack() }
            navButton("chevron.right", enabled: app.canGoForward, help: "Forward (⌘])") { app.goForward() }
        }
        .padding(.leading, 78)          // traffic lights
        .padding(.trailing, 8)
        .frame(height: 38)
    }

    private func navButton(_ icon: String, enabled: Bool, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).zfont(size: 13, weight: .medium)
                .frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(HoverFillStyle())
        .foregroundStyle(.secondary)
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled)
        .help(help)
    }

    // MARK: chats — one flat list, most recent activity first

    private var chatsHeader: some View {
        HStack(spacing: 6) {
            Text("Chats").zfont(.caption, .semibold).foregroundStyle(.tertiary)
            Spacer()
            if app.people.count > 1 {
                Menu {
                    Button { personFilter = "" } label: { Label("Everyone", systemImage: personFilter.isEmpty ? "checkmark" : "") }
                    Divider()
                    ForEach(app.people) { p in
                        Button { personFilter = p.slug } label: {
                            Label(name(p), systemImage: personFilter == p.slug ? "checkmark" : "")
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(personFilter.isEmpty ? "Everyone" : (app.people.first { $0.slug == personFilter }.map(name) ?? "Everyone"))
                        Image(systemName: "chevron.down").zfont(size: 8, weight: .semibold)
                    }
                    .zfont(.caption).foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Show chats about one person")
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 4)
    }

    private func name(_ p: Person) -> String { p.slug == "_self" ? "You" : p.displayName }

    /// Every chat (plus any brand-new, not-yet-saved one), newest activity on top. A running chat
    /// counts as "active now", so it rises to the top while it works.
    private var sortedChats: [(id: String, date: Date)] {
        var rows: [String: Date] = [:]
        for c in app.chats { rows[c.id] = c.updatedAt }
        for case .chat(let id) in app.openTabs where rows[id] == nil { rows[id] = .now }   // new, unsaved
        var out = rows.map { (id: $0.key, date: app.isChatStreaming($0.key) ? Date.distantFuture : $0.value) }
        if !personFilter.isEmpty { out = out.filter { app.personForChat($0.id) == personFilter } }
        return out.sorted { $0.date > $1.date }
    }

    private var chatList: some View {
        let rows = sortedChats
        return ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(rows, id: \.id) { row in ChatRow(id: row.id) }
                if rows.isEmpty {
                    Text(app.chats.isEmpty ? "Your chats will appear here" : "No chats about this person yet")
                        .zfont(.caption).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity).padding(.top, 20)
                }
            }
            .padding(.horizontal, 6)
            .animation(.easeInOut(duration: 0.2), value: rows.map(\.id))
        }
        .scrollIndicators(.never)
    }

    /// The in-progress import tray (bottom region) with its own bounded, independent scroll.
    private var processingTray: some View {
        // Cap proportional to the sidebar height (≥ ~3 rows), but never taller than the content.
        let cap = max(132, sidebarHeight * 0.42)
        let estimate = queueContentHeight > 0 ? queueContentHeight : CGFloat(app.processingFiles.count) * 46
        let height = min(estimate, cap)
        return VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.horizontal, 12).padding(.top, 6)
            HStack(spacing: 6) {
                Text("Files in progress").zfont(.caption, .semibold).foregroundStyle(.tertiary)
                Spacer()
                Text("\(app.processingFiles.count)").zfont(.caption2, .medium).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(app.processingFiles) { pf in ProcessingRow(pf: pf) }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
                .onHeightChange { queueContentHeight = $0 }
            }
            .frame(height: height)
            .scrollIndicators(.automatic)
        }
    }
}

/// Yab-style row hover: a soft rounded fill under the pointer.
struct HoverFillStyle: ButtonStyle {
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        HoverFill(active: active, pressed: configuration.isPressed) { configuration.label }
    }
}

private struct HoverFill<Content: View>: View {
    let active: Bool
    let pressed: Bool
    @ViewBuilder let content: () -> Content
    @State private var hover = false
    var body: some View {
        content()
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(active ? Theme.rowActive : (hover || pressed ? Theme.rowHover : .clear)))
            .onHover { hover = $0 }
    }
}

/// A plain sidebar row (Home, New chat).
struct SidebarRow: View {
    let icon: String
    let title: String
    let active: Bool
    var muted = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).zfont(size: 14).frame(width: 18).foregroundStyle(.secondary)
                Text(title).zfont(.body).foregroundStyle(muted ? .secondary : .primary)
                Spacer()
            }
            .padding(.vertical, 7).padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverFillStyle(active: active))
    }
}

/// An open document (or "What's new") — a tab that lives in the sidebar; × on hover closes it.
private struct OpenItemRow: View {
    @Environment(AppState.self) private var app
    let item: AppState.CenterItem
    @State private var hover = false

    var body: some View {
        Button { app.selectTab(item) } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).zfont(size: 14).frame(width: 18).foregroundStyle(.secondary)
                Text(title).zfont(.body).lineLimit(1)
                Spacer(minLength: 4)
                if hover {
                    Button { app.closeTab(item) } label: { Image(systemName: "xmark").zfont(size: 10, weight: .semibold) }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Close (⌘W)")
                }
            }
            .padding(.vertical, 7).padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverFillStyle(active: app.activeTab == item))
        .onHover { hover = $0 }
        .contextMenu {
            if case .file(let p) = item, let doc = app.openFileDocs[p] {
                Button("Open in Preview app") { app.openInExternalPreview(doc) }
                Button("Reveal in Finder") { app.revealInFinder(doc) }
                Divider()
            }
            Button("Close") { app.closeTab(item) }
        }
    }

    private var title: String {
        switch item {
        case .file(let p): app.openFileDocs[p]?.displayName ?? "File"
        case .whatsNew: "What's new"
        default: ""
        }
    }
    private var icon: String {
        switch item {
        case .file(let p): (app.openFileDocs[p]?.isImaging ?? false) ? "photo" : "doc.text"
        case .whatsNew: "sparkles"
        default: "doc"
        }
    }
}

/// Orange "the AI finished here and you haven't looked yet" dot.
struct UnreadDot: View {
    var body: some View {
        Circle().fill(Theme.unread).frame(width: 7, height: 7)
            .help("New answer — not viewed yet")
    }
}

private struct ChatRow: View {
    @Environment(AppState.self) private var app
    let id: String

    private var isActive: Bool { app.activeTab == .chat(id) }
    private var unread: Bool { app.isChatUnread(id) }
    private var summary: ChatSummary? { app.chats.first { $0.id == id } }

    var body: some View {
        Button { app.selectTab(.chat(id)) } label: {
            HStack(spacing: 9) {
                Group {
                    if app.isChatStreaming(id) { PulsingDot() }
                    else if unread { UnreadDot() }
                    else { Color.clear.frame(width: 7, height: 7) }
                }
                .frame(width: 10)
                Text(app.chatTitle(id))
                    .zfont(.body, unread ? .semibold : .regular)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let d = summary?.updatedAt {
                    Text(Self.short(d)).zfont(.caption).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
            .padding(.vertical, 7).padding(.leading, 8).padding(.trailing, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverFillStyle(active: isActive))
        .contextMenu {
            Button("Open") { app.selectTab(.chat(id)) }
            Menu("About") {
                ForEach(app.people) { p in
                    Button { app.setChatPerson(id, p.slug) } label: {
                        Label(p.slug == "_self" ? "You" : p.displayName,
                              systemImage: app.personForChat(id) == p.slug ? "checkmark" : "")
                    }
                }
            }
            if unread { Button("Mark as read") { app.markChatSeen(id) } }
            Divider()
            Button("Delete", role: .destructive) { app.deleteChat(id) }
        }
        .help(app.chatTitle(id))
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

/// "Where you are" — like Yab's address field. Click (or ⌘K) opens the command palette.
private struct WherePill: View {
    @Environment(AppState.self) private var app
    var body: some View {
        Button { app.showPalette = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").zfont(size: 12, weight: .medium).foregroundStyle(.tertiary)
                Text(location).zfont(.body).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text("⌘K").zfont(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(Theme.rowHover.opacity(1.4), in: RoundedRectangle(cornerRadius: 11))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Search everything, ask a question, or run a command (⌘K)")
    }

    private var location: String {
        switch app.activeTab {
        case .home: return "Home"
        case .whatsNew: return "What's new"
        case .chat(let id):
            let slug = app.personForChat(id)
            let who = slug == "_self" ? nil : app.people.first { $0.slug == slug }?.displayName
            return [who, app.chatTitle(id)].compactMap { $0 }.joined(separator: " › ")
        case .file(let p):
            guard let d = app.openFileDocs[p] else { return "Document" }
            let who = d.personId == "_self" ? nil : app.people.first { $0.slug == d.personId }?.displayName
            return [who, d.displayName].compactMap { $0 }.joined(separator: " › ")
        }
    }
}

/// The app menu, Yab-style: click the Rounds name. Replaces the old gear button.
private struct RoundsMenu: View {
    @Environment(AppState.self) private var app
    static let icon: NSImage = {
        let src = NSApp.applicationIconImage ?? NSImage()
        let img = NSImage(size: NSSize(width: 20, height: 20))
        img.lockFocus()
        src.draw(in: NSRect(x: 0, y: 0, width: 20, height: 20))
        img.unlockFocus()
        return img
    }()
    var body: some View {
        Menu {
            Text("Rounds v\(UpdateService.currentAppVersion)")
            Button { if let u = URL(string: "https://github.com/Rounds-Org/rounds/issues/new") { NSWorkspace.shared.open(u) } }
                label: { Label("Send Feedback", systemImage: "text.bubble") }
            Button { app.selectTab(.whatsNew) } label: { Label("What's New", systemImage: "doc.text") }
            Button { app.showShortcuts = true } label: { Label("Keyboard Shortcuts", systemImage: "command") }
            Button { app.checkForUpdate() } label: { Label("Check for Updates", systemImage: "arrow.clockwise") }
            Button { NSApp.orderFrontStandardAboutPanel(nil) } label: { Label("About Rounds", systemImage: "info.circle") }
            Divider()
            Button { app.showSettings = true } label: { Label("Settings…", systemImage: "gearshape") }
        } label: {
            HStack(spacing: 8) {
                Image(nsImage: Self.icon)   // a pre-sized image: Menu labels ignore .frame on images
                Text("Rounds").zfont(.body, .semibold)
                Image(systemName: "chevron.down").zfont(size: 9, weight: .semibold).foregroundStyle(.tertiary)
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .padding(.vertical, 6).padding(.horizontal, 10)
    }
}

/// Yab-style update note: handwritten "is here! restart to update", an arrow, and the Update button.
private struct UpdateNudge: View {
    @Environment(AppState.self) private var app
    let update: UpdateInfo

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Rounds \(update.latestVersion) is here! ♡").handwritten(23)
                Text("restart to update").handwritten(20).padding(.leading, 22)
                if !update.mandatory {
                    Button("not now") { app.dismissUpdate() }
                        .buttonStyle(.plain).handwritten(17, color: Theme.accent.opacity(0.75))
                        .padding(.top, 12).padding(.leading, 2)
                }
            }
            .padding(.horizontal, 14).padding(.top, 10)

            // Arrow from "update" down to the button.
            Path { p in
                p.move(to: CGPoint(x: 176, y: 40))
                p.addCurve(to: CGPoint(x: 206, y: 70), control1: CGPoint(x: 204, y: 38), control2: CGPoint(x: 212, y: 52))
                p.move(to: CGPoint(x: 197, y: 63)); p.addLine(to: CGPoint(x: 206, y: 72)); p.addLine(to: CGPoint(x: 212, y: 61))
            }
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .overlay(alignment: .bottomTrailing) {
            Button {
                Analytics.track(.updateBannerClicked)
                SparkleUpdater.shared.checkForUpdates()
            } label: {
                Text("Update").zfont(.callout).padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Theme.rowActive, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .overlay(   // hand-drawn circle around the button
                Ellipse().stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .padding(-7).rotationEffect(.degrees(-4)).allowsHitTesting(false)
            )
            .padding(.trailing, 20).padding(.bottom, 8)
        }
        .onAppear { Analytics.track(.updateBannerShown) }
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
