//
//  ContentView.swift
//  rounds
//
//  Root layout: file tree (left) · tabbed center (Home/Chat + open file tabs) · sources
//  (right, only when there are sources), with the update banner, disclaimer chin, and the
//  onboarding / intake / settings overlays.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppState.self) private var app
    @State private var dropTargeted = false

    private var showSources: Bool {
        app.activeChatTab != nil && (!app.currentSources.isEmpty || app.sourcesWarning != nil)
    }

    var body: some View {
        // ⌘+/⌘− text zoom: every `.zfont(...)` reads this scale and renders a REAL scaled font, so
        // the layout reflows naturally and — because there's no transform — clicks always land
        // exactly where controls are drawn.
        scaledContent
            .environment(\.zoomScale, app.uiScale)
            .preferredColorScheme(app.preferredColorScheme)
    }

    private var scaledContent: some View {
        Group {
            if app.booted { mainView } else { BootSkeleton() }
        }
        .overlay { if dropTargeted && app.booted { DropOverlay() } }
        .overlay(alignment: .bottom) { ToastBanner() }
        .sheet(isPresented: Binding(get: { app.showOnboarding }, set: { app.showOnboarding = $0 })) {
            OnboardingView()
        }
        .sheet(isPresented: Binding(get: { app.showSettings }, set: { app.showSettings = $0 })) {
            SettingsView()
        }
        .sheet(item: Binding(get: { app.intake.map { IntakeBox($0) } }, set: { if $0 == nil { app.cancelIntake() } })) { box in
            IntakeSheet(state: box.value).id(box.id)   // fresh fields per grouped question
        }
        .sheet(item: Binding(get: { app.pendingPermission }, set: { if $0 == nil, let p = app.pendingPermission { app.respondPermission(p, allow: false, always: false) } })) { pp in
            PermissionDialog(request: pp).interactiveDismissDisabled()
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers); return true
        }
    }

    @ViewBuilder private var engineNoticeBar: some View {
        if let notice = app.engineNotice {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "creditcard.trianglebadge.exclamationmark").foregroundStyle(.white)
                Text(notice).zfont(.callout).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button { app.engineNotice = nil } label: { Image(systemName: "xmark").foregroundStyle(.white.opacity(0.9)) }
                    .buttonStyle(.borderless)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.warn)
        }
    }

    private var mainView: some View {
        VStack(spacing: 0) {
            engineNoticeBar
            // Two top-level panes only: the sidebar, and the center region. Sources lives INSIDE
            // the center region (not as a third pane) so showing/hiding it can never resize the
            // sidebar — only the chat area gives up width to the sources column.
            HSplitView {
                SidebarView()
                    .frame(minWidth: 250, idealWidth: 290, maxWidth: 380)
                HStack(spacing: 0) {
                    CenterPane()
                        .frame(minWidth: 420, maxWidth: .infinity)
                    if showSources {
                        Divider()
                        SourcesPanel()
                            .frame(width: 320)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(minWidth: 460)
                .animation(.easeInOut(duration: 0.18), value: showSources)
            }
            .frame(maxHeight: .infinity)
            DisclaimerChin()
        }
        .background(Theme.bg)
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { if !urls.isEmpty { app.beginImport(urls) } }
    }
}

private struct ToastBanner: View {
    @Environment(AppState.self) private var app
    var body: some View {
        if let text = app.toast {
            HStack(spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.white)
                Text(text).zfont(.callout).foregroundStyle(.white)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color.black.opacity(0.82), in: Capsule())
            .padding(.bottom, 48)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: text) {
                try? await Task.sleep(for: .seconds(3.5))
                withAnimation { app.toast = nil }
            }
        }
    }
}

private struct BootSkeleton: View {
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                shimmer(width: 90, height: 16)
                shimmer(width: .infinity, height: 34)
                ForEach(0..<5, id: \.self) { _ in shimmer(width: .infinity, height: 30) }
                Spacer()
            }
            .padding(16)
            .frame(width: 280)
            .background(Theme.panel.opacity(0.5))
            VStack(alignment: .leading, spacing: 16) {
                shimmer(width: 220, height: 34)
                shimmer(width: .infinity, height: 54)
                ForEach(0..<3, id: \.self) { _ in shimmer(width: .infinity, height: 80) }
                Spacer()
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
        .onAppear { pulse = true }
    }

    private func shimmer(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.primary.opacity(pulse ? 0.10 : 0.05))
            .frame(maxWidth: width == .infinity ? .infinity : width)
            .frame(height: height)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
    }
}

private struct DropOverlay: View {
    var body: some View {
        ZStack {
            Theme.accent.opacity(0.10)
            VStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .zfont(size: 44).foregroundStyle(Theme.accent)
                Text("Release to add to Rounds").zfont(.title2, .semibold)
                Text("Rounds will read it on-device and ask whose it is before filing.")
                    .zfont(.callout).foregroundStyle(.secondary)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8])))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Identifiable wrapper so IntakeState can drive a `.sheet(item:)`.
struct IntakeBox: Identifiable, Equatable {
    let value: IntakeState
    var id: String { value.id }
    init(_ v: IntakeState) { value = v }
    static func == (l: IntakeBox, r: IntakeBox) -> Bool { l.id == r.id }
}

private struct CenterPane: View {
    @Environment(AppState.self) private var app
    var body: some View {
        VStack(spacing: 0) {
            if app.openTabs.count > 1 { CenterTabBar() }
            Group {
                switch app.activeTab {
                case .home: DashboardView()
                case .chat: ChatView()
                case .file(let p):
                    if let doc = app.openFileDocs[p] { FileTabContent(doc: doc) }
                    else { DashboardView() }
                }
            }
        }
    }
}

private struct CenterTabBar: View {
    @Environment(AppState.self) private var app
    @State private var draggingId: String?
    @State private var dragDX: CGFloat = 0
    @State private var startMid: [String: CGFloat] = [:]   // tab centers snapshotted at drag start
    @State private var liveMid: [String: CGFloat] = [:]    // live tab centers

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(displayOrder, id: \.id) { item in
                        TabView(item: item)
                            .id(item.id)
                            .opacity(draggingId == item.id ? 0.55 : 1)   // translucent while dragging
                            .scaleEffect(draggingId == item.id ? 1.04 : 1)
                            .zIndex(draggingId == item.id ? 1 : 0)
                            .background(GeometryReader { g in
                                let m = g.frame(in: .named("tabbar")).midX
                                Color.clear.onAppear { liveMid[item.id] = m }
                                    .onChange(of: m) { _, v in liveMid[item.id] = v }
                            })
                            .gesture(dragGesture(item))
                    }
                }
                .coordinateSpace(name: "tabbar")
                .animation(.easeInOut(duration: 0.18), value: displayOrder.map(\.id))
            }
            .onChange(of: app.activeTab) { _, tab in
                if draggingId == nil { withAnimation { proxy.scrollTo(tab.id, anchor: .center) } }
            }
            .onAppear { proxy.scrollTo(app.activeTab.id, anchor: .center) }
        }
        .background(Theme.panel.opacity(0.6))
        .overlay(Divider(), alignment: .bottom)
    }

    /// Lowest index a tab may land at (after a pinned Home).
    private var lowBound: Int { app.openTabs.first == .home ? 1 : 0 }

    private var targetIndex: Int? {
        guard let id = draggingId, let sm = startMid[id] else { return nil }
        let center = sm + dragDX
        let n = app.openTabs.filter { $0.id != id }.filter { (startMid[$0.id] ?? .infinity) < center }.count
        return max(lowBound, min(n, app.openTabs.count - 1))
    }

    private var displayOrder: [AppState.CenterItem] {
        guard let id = draggingId, let t = targetIndex,
              let from = app.openTabs.firstIndex(where: { $0.id == id }) else { return app.openTabs }
        var arr = app.openTabs
        let it = arr.remove(at: from)
        arr.insert(it, at: max(0, min(t, arr.count)))
        return arr
    }

    private func dragGesture(_ item: AppState.CenterItem) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("tabbar"))
            .onChanged { v in
                guard item != .home else { return }   // Home is pinned
                if draggingId == nil { draggingId = item.id; startMid = liveMid }
                if draggingId == item.id { dragDX = v.translation.width }
            }
            .onEnded { _ in
                if let id = draggingId, let t = targetIndex,
                   let from = app.openTabs.firstIndex(where: { $0.id == id }), from != t {
                    app.moveTab(from: from, to: t)
                }
                draggingId = nil; dragDX = 0
            }
    }

    private struct TabView: View {
        @Environment(AppState.self) private var app
        let item: AppState.CenterItem
        @State private var hover = false

        var body: some View {
            HStack(spacing: 6) {
                if app.tabIsStreaming(item) {
                    PulsingDot()
                } else {
                    Image(systemName: icon).zfont(.caption2)
                }
                Text(title).zfont(.caption).lineLimit(1)
                if item != .home {
                    Button { app.closeTab(item) } label: { Image(systemName: "xmark").zfont(size: 9) }
                        .buttonStyle(.borderless)
                        .opacity(hover || isActive ? 1 : 0)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .frame(maxWidth: 190)
            .background(isActive ? Theme.bg : .clear)
            .overlay(alignment: .bottom) { if isActive { Rectangle().fill(Theme.accent).frame(height: 2) } }
            .foregroundStyle(isActive ? .primary : .secondary)
            .contentShape(Rectangle())
            .onTapGesture { app.selectTab(item) }
            .onHover { hover = $0 }
            .overlay(Divider(), alignment: .trailing)
            .contextMenu { contextMenu }
        }

        private var isActive: Bool { app.activeTab == item }

        @ViewBuilder private var contextMenu: some View {
            if case .file(let p) = item, let doc = app.openFileDocs[p] {
                Button("Open in Preview app") { app.openInExternalPreview(doc) }
                Button("Reveal in Finder") { app.revealInFinder(doc) }
                Divider()
                Button("Close Tab") { app.closeTab(item) }
            } else if item != .home {
                Button("Close Tab") { app.closeTab(item) }
            }
        }

        private var title: String {
            switch item {
            case .home: "Home"
            case .chat(let id): app.chatTitle(id)
            case .file(let p): app.openFileDocs[p]?.displayName ?? "File"
            }
        }
        private var icon: String {
            switch item {
            case .home: "house"
            case .chat: "bubble.left"
            case .file(let p): (app.openFileDocs[p]?.isImaging ?? false) ? "photo" : "doc.text"
            }
        }
    }
}

struct PulsingDot: View {
    @State private var on = false
    var body: some View {
        Circle().fill(Theme.accent).frame(width: 7, height: 7)
            .opacity(on ? 1 : 0.3)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// Compact update chip shown at the bottom of the sidebar.
struct UpdateChip: View {
    @Environment(AppState.self) private var app
    let update: UpdateInfo

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text("Update available").zfont(.caption, .medium)
                Text("Version \(update.latestVersion)").zfont(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Get") {
                Analytics.track(.updateBannerClicked)
                NSWorkspace.shared.open(update.downloadURL)
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
            if !update.mandatory {
                Button { app.dismissUpdate() } label: { Image(systemName: "xmark").zfont(.caption2) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 10).padding(.bottom, 10)
        .onAppear { Analytics.track(.updateBannerShown) }
    }
}

#Preview {
    ContentView().environment(AppState())
}

/// Allow/Deny prompt for a gated Claude Code tool (Bash, web search, sub-agent…) in full-power mode.
struct PermissionDialog: View {
    @Environment(AppState.self) private var app
    let request: PendingPermission

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "hand.raised.fill").zfont(.title2).foregroundStyle(Theme.warn)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude wants to use \(friendly)").zfont(.headline)
                    Text("Approve this action on your Mac?").zfont(.caption).foregroundStyle(.secondary)
                }
            }
            if !request.inputSummary.isEmpty {
                ScrollView {
                    Text(request.inputSummary)
                        .zfont(.caption, design: .monospaced).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .padding(10)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
            }
            HStack(spacing: 10) {
                Button("Deny", role: .cancel) { app.respondPermission(request, allow: false, always: false) }
                Spacer()
                Button("Always allow \(request.toolName)") { app.respondPermission(request, allow: true, always: true) }
                    .buttonStyle(.bordered)
                Button("Allow once") { app.respondPermission(request, allow: true, always: false) }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var friendly: String {
        switch request.toolName {
        case "Bash": "the terminal (Bash)"
        case "WebSearch": "web search"
        case "Task": "a sub-agent"
        default: request.toolName
        }
    }
}
