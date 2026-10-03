//
//  ContentView.swift
//  rounds
//
//  Root layout: the sidebar (also the tab strip) on the window canvas · the center page as a rounded
//  card (Home / chat / document / what's new) with sources inside it when there are any · the ⌘K
//  palette, onboarding / intake / settings overlays.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppState.self) private var app
    @State private var dropTargeted = false
    @State private var leftTargeted = false    // "add to this chat" drop zone
    @State private var rightTargeted = false   // "process generally" drop zone
    // Latched visibility: with two zones, the outer target and a zone hand the drag back and forth,
    // so `dropTargeted` alone flickers. Show while ANY target has the drag, and hide only after a
    // short debounce so the hand-off gap never collapses (and re-shows) the overlay.
    @State private var showDropZones = false
    @State private var dragHideWork: DispatchWorkItem?

    private var showSources: Bool {
        app.activeChatTab != nil && (!app.currentSources.isEmpty || app.sourcesWarning != nil)
    }

    @State private var shortcutMonitor: Any?

    var body: some View {
        // ⌘+/⌘− text zoom: every `.zfont(...)` reads this scale and renders a REAL scaled font, so
        // the layout reflows naturally and — because there's no transform — clicks always land
        // exactly where controls are drawn.
        scaledContent
            .environment(\.zoomScale, app.uiScale)
            .preferredColorScheme(app.preferredColorScheme)
            .onAppear {
                // ⌘K must work while a text editor has focus (the menu shortcut alone doesn't reach
                // through the chat input), so catch it at the window's event stream.
                guard shortcutMonitor == nil else { return }
                shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                    let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    if mods == .command, e.charactersIgnoringModifiers?.lowercased() == "k" || e.keyCode == 40 {
                        app.showPalette.toggle(); return nil
                    }
                    return e
                }
            }
    }

    private var scaledContent: some View {
        Group {
            if app.booted { mainView } else { BootSkeleton() }
        }
        .overlay { dropOverlay }
        .overlay(alignment: .bottom) { ToastBanner() }
        .sheet(isPresented: Binding(get: { app.showOnboarding }, set: { app.showOnboarding = $0 })) {
            OnboardingView()
        }
        .sheet(isPresented: Binding(get: { app.showSettings }, set: { app.showSettings = $0 })) {
            SettingsView()
        }
        .sheet(isPresented: Binding(get: { app.showOpenAIKeySheet }, set: { app.showOpenAIKeySheet = $0 })) {
            OpenAIKeySheet()
        }
        .sheet(item: Binding(get: { app.intake.map { IntakeBox($0) } }, set: { if $0 == nil { app.cancelIntake() } })) { box in
            IntakeSheet(state: box.value).id(box.id)   // fresh fields per grouped question
        }
        .sheet(item: Binding(get: { app.pendingPermission }, set: { if $0 == nil, let p = app.pendingPermission { app.respondPermission(p, allow: false, always: false) } })) { pp in
            PermissionDialog(request: pp).interactiveDismissDisabled()
        }
        // The whole window detects a file drag (drives the overlay). When a chat is open the overlay
        // splits into two zones with their own onDrop; this outer one is the fallback (no chat open,
        // or a drop before the overlay's halves registered) → today's general filing.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers, toChat: false); return true
        }
        .onChange(of: dropTargeted) { _, _ in recomputeDragOverlay() }
        .onChange(of: leftTargeted) { _, _ in recomputeDragOverlay() }
        .onChange(of: rightTargeted) { _, _ in recomputeDragOverlay() }
    }

    /// Drive `showDropZones` from the combined targeting state, debouncing the OFF transition so the
    /// outer↔zone hand-off (which momentarily reports "no target") can't flicker the overlay.
    private func recomputeDragOverlay() {
        let any = dropTargeted || leftTargeted || rightTargeted
        if any {
            dragHideWork?.cancel(); dragHideWork = nil
            if !showDropZones { showDropZones = true }
        } else if showDropZones, dragHideWork == nil {
            let work = DispatchWorkItem {
                if !(dropTargeted || leftTargeted || rightTargeted) { showDropZones = false }
                dragHideWork = nil
            }
            dragHideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        }
    }

    /// While dragging a file: if a chat is open, offer TWO zones — left = attach to the open chat,
    /// right = process generally (today's behavior). Otherwise the single general overlay.
    @ViewBuilder private var dropOverlay: some View {
        if showDropZones && app.booted {
            let inChat = app.activeChatTab != nil
            HStack(spacing: 0) {
                DropZone(icon: "bubble.left.fill",
                         title: inChat ? "Add to this chat" : "Attach to a new chat",
                         subtitle: inChat ? "Attach to the open conversation" : "Start a new chat from Home with this file",
                         active: leftTargeted)
                    .onDrop(of: [.fileURL], isTargeted: $leftTargeted) { handleDrop($0, toChat: true); return true }
                DropZone(icon: "tray.and.arrow.down.fill", title: "Add to Rounds",
                         subtitle: "Read on-device and file it", active: rightTargeted)
                    .onDrop(of: [.fileURL], isTargeted: $rightTargeted) { handleDrop($0, toChat: false); return true }
            }
            .ignoresSafeArea()
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

    @AppStorage("rounds.sidebarWidth") private var sidebarWidth: Double = 280

    /// Yab-style window: the sidebar sits on the canvas (it IS the tab strip — there's no top tab bar),
    /// and the page floats beside it as a rounded card. Sources lives INSIDE the card (not as another
    /// pane) so showing/hiding it never resizes the sidebar — only the chat gives up width.
    private var mainView: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: sidebarWidth)
                .overlay(alignment: .trailing) { resizeHandle }
            VStack(spacing: 0) {
                engineNoticeBar
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
                .frame(maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.18), value: showSources)
                DisclaimerChin()
            }
            .background(Theme.bg)
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .shadow(color: .black.opacity(0.06), radius: 1, y: 0.5)
            .shadow(color: .black.opacity(0.06), radius: 14, y: 4)
            .padding(.vertical, 8).padding(.trailing, 8)
            .frame(minWidth: 460)
        }
        .background(Theme.canvas)
        .ignoresSafeArea(.container, edges: .top)   // the sidebar runs up under the hidden title bar
        .overlay { if app.showPalette { CommandPalette() } }
        .fileImporter(isPresented: Binding(get: { app.showImporter }, set: { app.showImporter = $0 }),
                      allowedContentTypes: [.pdf, .image, .plainText, .item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { app.beginImport(urls) }
        }
        .sheet(isPresented: Binding(get: { app.showShortcuts }, set: { app.showShortcuts = $0 })) { ShortcutsSheet() }
    }

    /// Drag the sidebar's right edge to resize it.
    private var resizeHandle: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                sidebarWidth = min(400, max(220, sidebarWidth + v.translation.width))
            })
            .offset(x: 4)
    }

    private func handleDrop(_ providers: [NSItemProvider], toChat: Bool) {
        var urls: [URL] = []
        let lock = NSLock()   // loadObject callbacks fire on arbitrary queues concurrently
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            if toChat {
                if let cid = app.activeChatTab { app.attachFilesToChat(urls, chatId: cid) }
                else { app.selectHome(); app.attachFilesToHomeDraft(urls) }   // no chat open → a new chat from Home
            } else {
                app.beginImport(urls)
            }
        }
    }
}

/// One half of the two-zone drag overlay.
private struct DropZone: View {
    let icon: String
    let title: String
    let subtitle: String
    let active: Bool
    var body: some View {
        ZStack {
            Theme.accent.opacity(active ? 0.18 : 0.06)
            VStack(spacing: 10) {
                Image(systemName: icon).zfont(size: 38).foregroundStyle(Theme.accent)
                Text(title).zfont(.title3, .semibold).multilineTextAlignment(.center)
                Text(subtitle).zfont(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(22)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Theme.accent.opacity(active ? 1 : 0.5),
                              style: StrokeStyle(lineWidth: active ? 3 : 2, dash: [8])))
            .scaleEffect(active ? 1.03 : 1)
            .padding(18)
            .animation(.easeOut(duration: 0.12), value: active)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
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
        Group {
            switch app.activeTab {
            case .home: DashboardView()
            case .chat: ChatView()
            case .whatsNew: WhatsNewView()
            case .file(let p):
                if let doc = app.openFileDocs[p] { FileTabContent(doc: doc) }
                else { DashboardView() }
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
