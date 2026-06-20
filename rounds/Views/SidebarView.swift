//
//  SidebarView.swift
//  rounds
//
//  Document tree. Folders are GROUP-BY axes (person / type / test-date), derived from the
//  sidecars. Clicking a file opens it as a tab in the center pane.
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
    @State private var groupBy: GroupBy = .person
    @State private var importing = false
    @State private var showGroupPicker = false
    @State private var pendingDelete: MedDocument?
    @State private var sidebarHeight: CGFloat = 600     // measured, to cap the in-progress tray
    @State private var queueContentHeight: CGFloat = 0  // measured in-progress content height

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Rounds").font(.headline)
                Spacer()
                Button { app.showSettings = true } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Settings")
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)

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

            Button { importing = true } label: {
                Label("Add File", systemImage: "plus.rectangle.on.folder")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent).tint(Theme.accent)
            .padding(.horizontal, 12).padding(.bottom, 10)

            // PROCESSED — your filed library on top, fills remaining space, scrolls via its List.
            documentsRegion
                .frame(maxHeight: .infinity)

            // UNPROCESSED — the import tray on the bottom, its OWN scroll: sizes to content when
            // small, caps + scrolls internally when large, so it can never push the rest off-screen.
            if !app.processingFiles.isEmpty { processingTray }

            if let update = app.updateAvailable, !app.updateDismissed {
                UpdateChip(update: update)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sidebarHeight = $0 }
        .background(Theme.panel.opacity(0.5))
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .image, .plainText, .item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { app.beginImport(urls) }
        }
        .confirmationDialog("Delete this document?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { doc in
            Button("Delete \(doc.docType.replacingOccurrences(of: "_", with: " "))", role: .destructive) {
                app.deleteDocument(doc); pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("It moves to the Rounds trash. This won't affect your other records.")
        }
    }

    /// The filed-documents area (top region). Compact placeholder while nothing is filed yet.
    @ViewBuilder private var documentsRegion: some View {
        if app.documents.isEmpty {
            if app.processingFiles.isEmpty {
                emptyState                       // full drop-zone only when nothing is happening
            } else {
                compactDocsPlaceholder           // slim hint while files are still being added
            }
        } else {
            VStack(spacing: 0) {
                groupByControl
                List {
                    ForEach(groups, id: \.0) { (key, docs) in
                        Section(header: Text(key)) {
                            ForEach(docs) { doc in DocRow(doc: doc, onDelete: { pendingDelete = doc }) }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var compactDocsPlaceholder: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            Image(systemName: "tray.and.arrow.down").font(.system(size: 22)).foregroundStyle(.secondary)
            Text("Your filed documents will appear here").font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Grouped by person, type and date.").font(.caption2).foregroundStyle(.tertiary)
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
                    .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
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
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { queueContentHeight = $0 }
            }
            .frame(height: height)
            .scrollIndicators(.automatic)
        }
        .padding(.bottom, 8)
    }

    private var groupByControl: some View {
        Button { showGroupPicker = true } label: {
            HStack(spacing: 6) {
                Image(systemName: groupBy.icon).font(.caption)
                Text("Grouped by \(groupBy.title.lowercased())").font(.caption)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12).padding(.bottom, 8)
        .popover(isPresented: $showGroupPicker, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Group your artifacts by")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                ForEach(GroupBy.allCases) { option in
                    Button { groupBy = option; showGroupPicker = false } label: {
                        HStack(spacing: 10) {
                            Image(systemName: groupBy == option ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(groupBy == option ? Theme.accent : .secondary)
                            Image(systemName: option.icon).foregroundStyle(.secondary).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(option.title).font(.callout)
                                Text(option.subtitle).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 6).padding(.horizontal, 8)
                        .contentShape(Rectangle())
                        .background(groupBy == option ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .frame(width: 260)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 30)).foregroundStyle(.secondary)
            Text("Drop documents here")
                .font(.callout).foregroundStyle(.secondary)
            Text("Labs, reports, discharge summaries — Rounds files them by person, type and date.")
                .font(.caption).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Button("Choose files…") { importing = true }
                .buttonStyle(.bordered)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var groups: [(String, [MedDocument])] {
        let docs = app.documents
        let dict: [String: [MedDocument]]
        switch groupBy {
        case .person:
            let names = Dictionary(uniqueKeysWithValues: app.people.map { ($0.slug, $0.displayName) })
            dict = Dictionary(grouping: docs) { names[$0.personId] ?? $0.personId }
        case .type:
            dict = Dictionary(grouping: docs) { $0.docType.replacingOccurrences(of: "_", with: " ").capitalized }
        case .date:
            dict = Dictionary(grouping: docs) { $0.year }
        }
        return dict.sorted { $0.key < $1.key }
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
                Text(pf.fileName).font(.caption).lineLimit(1)
                Text(pf.label).font(.caption2).foregroundStyle(pf.status == .error ? Theme.warn : .secondary)
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

private struct DocRow: View {
    @Environment(AppState.self) private var app
    let doc: MedDocument
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: doc.isImaging ? "photo" : "doc.text")
                .foregroundStyle(doc.isImaging ? Theme.warn : Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(doc.displayName)
                    .font(.callout).lineLimit(1)
                HStack(spacing: 6) {
                    if let d = doc.testDate { Text(d).font(.caption2).foregroundStyle(.secondary) }
                    if let lab = doc.sourceLab { Text(lab).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
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
