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
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers); return true
        }
    }

    private var mainView: some View {
        VStack(spacing: 0) {
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
                Text(text).font(.callout).foregroundStyle(.white)
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
                    .font(.system(size: 44)).foregroundStyle(Theme.accent)
                Text("Release to add to Rounds").font(.title2.weight(.semibold))
                Text("Rounds will read it on-device and ask whose it is before filing.")
                    .font(.callout).foregroundStyle(.secondary)
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
    @State private var dragging: AppState.CenterItem?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(app.openTabs) { item in
                    TabView(item: item)
                        .onDrag {
                            dragging = item
                            return NSItemProvider(object: item.id as NSString)
                        }
                        .onDrop(of: [.text], delegate: TabDropDelegate(item: item, app: app, dragging: $dragging))
                }
            }
        }
        .background(Theme.panel.opacity(0.6))
        .overlay(Divider(), alignment: .bottom)
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
                    Image(systemName: icon).font(.caption2)
                }
                Text(title).font(.caption).lineLimit(1)
                if item != .home {
                    Button { app.closeTab(item) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
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

private struct TabDropDelegate: DropDelegate {
    let item: AppState.CenterItem
    let app: AppState
    @Binding var dragging: AppState.CenterItem?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != item,
              let from = app.openTabs.firstIndex(of: dragging),
              let to = app.openTabs.firstIndex(of: item) else { return }
        app.moveTab(from: from, to: to)
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

/// Compact update chip shown at the bottom of the sidebar.
struct UpdateChip: View {
    @Environment(AppState.self) private var app
    let update: UpdateInfo

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text("Update available").font(.caption.weight(.medium))
                Text("Version \(update.latestVersion)").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Get") {
                Analytics.track(.updateBannerClicked)
                NSWorkspace.shared.open(update.downloadURL)
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
            if !update.mandatory {
                Button { app.dismissUpdate() } label: { Image(systemName: "xmark").font(.caption2) }
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
