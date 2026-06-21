//
//  SourcesPanel.swift
//  rounds
//
//  Right rail. The brain never concludes from memory — so this panel shows the
//  trust-ranked sources behind the current answer, numbered to match the [S#] markers in
//  the text. An empty panel on a clinical answer is itself a signal.
//

import SwiftUI

struct SourcesPanel: View {
    @Environment(AppState.self) private var app
    @State private var showLegend = true   // tier guide is shown by default; the "?" collapses it

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sources").zfont(.headline)
                if !app.currentSources.isEmpty {
                    Text("\(app.currentSources.count)")
                        .zfont(.caption, .medium)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Theme.accentSoft, in: Capsule()).foregroundStyle(Theme.accent)
                }
                Spacer()
                Button { withAnimation { showLegend.toggle() } } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("What do the trust tiers mean?")
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            Divider()

            if showLegend { TierLegend() }

            if let warning = app.sourcesWarning {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warn)
                    Text(warning).zfont(.caption).foregroundStyle(Theme.warn)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.warn.opacity(0.1))
            }

            if app.currentSources.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("The numbers match the [n] marks in the answer. Ranked by evidence strength.")
                            .zfont(.caption2).foregroundStyle(.tertiary)
                        ForEach(app.currentSources) { SourceCard(source: $0) }
                    }
                    .padding(12)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel.opacity(0.5))
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical")
                .zfont(size: 28).foregroundStyle(.secondary)
            Text("Sources appear here")
                .zfont(.callout).foregroundStyle(.secondary)
            Text("Rounds backs every clinical statement with trust-ranked sources — guidelines and systematic reviews rank above case reports and preprints.")
                .zfont(.caption).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct TierLegend: View {
    private let rows: [(badge: String, label: String, desc: String)] = [
        ("PRIMARY", "Your records", "Your own uploaded results"),
        ("T1", "Guidelines", "Clinical guidelines · Cochrane · systematic reviews"),
        ("T2", "Trials", "Meta-analyses · randomized trials"),
        ("T4", "Observational", "Cohort studies · case reports"),
        ("T6", "Preprints", "Preprints · low-confidence")
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trust tiers").zfont(.caption, .semibold).foregroundStyle(.secondary)
            // A simple vertical list (not a fixed-column table) so nothing clips in the narrow rail.
            ForEach(rows, id: \.badge) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TierBadge(tier: row.badge)
                    Text(row.desc)
                        .zfont(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg)
        .overlay(Divider(), alignment: .bottom)
    }
}

struct SourceCard: View {
    let source: Source
    private var number: String { source.id.hasPrefix("S") ? String(source.id.dropFirst()) : source.id }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(number).")
                    .zfont(.caption, .medium).monospacedDigit()
                    .foregroundStyle(.secondary)
                TierBadge(tier: source.trustTier)
                Spacer()
                if let y = source.year { Text(String(y)).zfont(.caption2).foregroundStyle(.secondary) }
            }
            Text(source.title).zfont(.callout, .medium).lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            if let why = source.whyTrusted {
                Text(why).zfont(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if let j = source.journal { Text(j).zfont(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                if let c = source.citedBy, c > 0 { Text("· \(c) cited").zfont(.caption2).foregroundStyle(.tertiary) }
                Spacer()
                if let urlStr = source.url, let url = URL(string: urlStr) {
                    Link(destination: url) {
                        HStack(spacing: 3) { Text("Open"); Image(systemName: "arrow.up.right") }
                            .zfont(.caption2, .medium)
                    }
                    .foregroundStyle(Theme.accent)
                }
            }
        }
        .padding(11)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }
}
