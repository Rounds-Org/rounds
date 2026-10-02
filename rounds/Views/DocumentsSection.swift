//
//  DocumentsSection.swift
//  rounds
//
//  Home's "Documents" section: every filed document, grouped by person / type / date (GROUP-BY axes
//  derived from the sidecars), with a person filter. Clicking a file opens it as a tab. Full-text
//  search over documents lives in the sidebar search.
//

import SwiftUI
import UniformTypeIdentifiers

struct DocumentsSection: View {
    @Environment(AppState.self) private var app
    @AppStorage("rounds.docs.groupBy") private var groupByRaw = GroupBy.person.rawValue
    @State private var personFilter: String?          // nil = everyone
    @State private var collapsed: Set<String> = []
    @State private var expanded: Set<String> = []     // groups showing all docs, not just the first few
    @State private var importing = false
    @State private var pendingDelete: MedDocument?

    private let perGroup = 6
    private var groupBy: GroupBy { GroupBy(rawValue: groupByRaw) ?? .person }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionHeader(title: "Documents")
                if !app.documents.isEmpty {
                    Text("\(app.documents.count)").zfont(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                if !app.documents.isEmpty {
                    if app.people.count > 1 { personMenu }
                    groupMenu
                }
                Button { importing = true } label: { Label("Add files", systemImage: "plus") }
                    .zfont(.caption).buttonStyle(.bordered).controlSize(.small)
            }

            if app.documents.isEmpty {
                emptyState
            } else {
                ForEach(groups, id: \.0) { key, docs in group(key, docs) }
            }
        }
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

    private func group(_ key: String, _ docs: [MedDocument]) -> some View {
        let isCollapsed = collapsed.contains(key)
        let showAll = expanded.contains(key)
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                if isCollapsed { collapsed.remove(key) } else { collapsed.insert(key) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .zfont(size: 9).foregroundStyle(.secondary).frame(width: 10)
                    Text(key).zfont(.callout, .medium)
                    Text("\(docs.count)").zfont(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                VStack(spacing: 0) {
                    ForEach(showAll ? docs : Array(docs.prefix(perGroup))) { doc in
                        DocRow(doc: doc, onDelete: { pendingDelete = doc })
                            .padding(.vertical, 6).padding(.horizontal, 10)
                        if doc.id != (showAll ? docs : Array(docs.prefix(perGroup))).last?.id {
                            Divider().padding(.leading, 34)
                        }
                    }
                }
                .background(Theme.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
                if docs.count > perGroup {
                    Button(showAll ? "Show less" : "Show all \(docs.count)") {
                        if showAll { expanded.remove(key) } else { expanded.insert(key) }
                    }
                    .buttonStyle(.plain).zfont(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 10).padding(.top, 4)
                }
            }
        }
    }

    private var personMenu: some View {
        Menu {
            Button { personFilter = nil } label: { Label("Everyone", systemImage: personFilter == nil ? "checkmark" : "") }
            Divider()
            ForEach(app.people) { p in
                Button { personFilter = p.slug } label: {
                    Label(p.displayName, systemImage: personFilter == p.slug ? "checkmark" : "")
                }
            }
        } label: {
            Label(personFilter.flatMap { pf in app.people.first { $0.slug == pf }?.displayName } ?? "Everyone",
                  systemImage: "person.crop.circle")
                .zfont(.caption)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var groupMenu: some View {
        Menu {
            ForEach(GroupBy.allCases) { option in
                Button { groupByRaw = option.rawValue } label: {
                    Label("By \(option.title.lowercased())", systemImage: groupBy == option ? "checkmark" : option.icon)
                }
            }
        } label: {
            Label("By \(groupBy.title.lowercased())", systemImage: groupBy.icon).zfont(.caption)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Group documents by person, type or date")
    }

    private var emptyState: some View {
        Button { importing = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down").zfont(size: 20).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Drop documents anywhere").zfont(.callout)
                    Text("Labs, reports, discharge summaries — Rounds files them by person, type and date.")
                        .zfont(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(Theme.panel.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var groups: [(String, [MedDocument])] {
        let names = Dictionary(app.people.map { ($0.slug, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        var docs = app.documents
        if let pf = personFilter { docs = docs.filter { $0.personId == pf } }
        let dict: [String: [MedDocument]]
        switch groupBy {
        case .person: dict = Dictionary(grouping: docs) { names[$0.personId] ?? $0.personId }
        case .type: dict = Dictionary(grouping: docs) { $0.docType.replacingOccurrences(of: "_", with: " ").capitalized }
        case .date: dict = Dictionary(grouping: docs) { $0.year }
        }
        // Newest test first inside a group; date groups newest year first.
        let sorted = dict.mapValues { $0.sorted { ($0.testDate ?? "") > ($1.testDate ?? "") } }
        return groupBy == .date ? sorted.sorted { $0.key > $1.key } : sorted.sorted { $0.key < $1.key }
    }
}
