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
    // Each entry: the marker term + a plain-language definition. Rendered as glossary paragraphs
    // (highlighted term, definition flowing on the same line height) — not floating pill + column.
    private let tiers: [(term: String, def: String, tier: String)] = [
        ("Your record", "your own uploaded results — the primary source about you", "PRIMARY"),
        ("Guideline", "clinical guidelines · Cochrane · systematic reviews — the highest trust", "T1"),
        ("Systematic review", "meta-analyses & randomized trials — very strong evidence", "T2"),
        ("Cohort study", "observational studies & case reports — moderate evidence", "T4"),
        ("Preprint", "preprints & unindexed sources — lowest confidence", "T6"),
    ]
    private let maturities: [(term: String, def: String, key: String)] = [
        ("Established", "settled — guidelines, systematic reviews, drug labels", "established"),
        ("Emerging", "recent trials & observational studies — promising, not yet settled", "emerging"),
        ("Experimental", "preprints, case reports, ongoing trials — early, treat with caution", "experimental"),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Trust tiers").zfont(.caption, .semibold).foregroundStyle(.secondary)
            ForEach(tiers, id: \.tier) { row in
                MarkerParagraph(term: row.term, definition: row.def, color: TierBadge.color(row.tier))
            }

            Divider().padding(.vertical, 2)
            Text("Maturity").zfont(.caption, .semibold).foregroundStyle(.secondary)
            Text("The research-stage slider widens or narrows what appears here. Early evidence is labelled so you know how much to trust it yet.")
                .zfont(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(maturities, id: \.key) { row in
                MarkerParagraph(term: row.term, definition: row.def, color: MaturityBadge.color(row.key))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg)
        .overlay(Divider(), alignment: .bottom)
    }
}

/// Evidence-maturity chip (the research-stage axis): established / emerging / experimental.
/// Hover shows what the band means.
struct MaturityBadge: View {
    let maturity: String
    var body: some View {
        Text(Self.label(maturity))
            .zfont(.caption2, .medium)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Self.color(maturity).opacity(0.14), in: Capsule())
            .foregroundStyle(Self.color(maturity))
            .help(Self.explanation(maturity))
    }
    static func color(_ maturity: String?) -> Color {
        switch (maturity ?? "").lowercased() {
        case "established": return Theme.accent
        case "emerging": return Color(red: 0.72, green: 0.52, blue: 0.10)   // amber
        case "experimental": return Theme.warn
        default: return .secondary
        }
    }
    static func label(_ maturity: String) -> String {
        switch maturity.lowercased() {
        case "established": return "Established"
        case "emerging": return "Emerging"
        case "experimental": return "Experimental"
        default: return maturity.capitalized
        }
    }
    static func explanation(_ maturity: String) -> String {
        switch maturity.lowercased() {
        case "established": return "Settled evidence — guidelines, systematic reviews, drug labels."
        case "emerging": return "Recent trials & observational studies — promising, not yet settled."
        case "experimental": return "Preprints, case reports, ongoing trials — early, treat with caution."
        default: return "Evidence maturity: \(maturity)."
        }
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
                if let m = source.maturity { MaturityBadge(maturity: m) }
                Spacer()
                if let y = source.year { Text(String(y)).zfont(.caption2).foregroundStyle(.secondary) }
            }
            Text(source.title).zfont(.callout, .medium).lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            if let why = source.whyTrusted {
                Text(why).zfont(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // How much to trust this yet — shown for early (emerging/experimental) sources.
            if let caution = source.caution, !caution.isEmpty {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill").zfont(size: 9)
                    Text(caution).zfont(.caption2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(MaturityBadge.color(source.maturity))
                .padding(.horizontal, 7).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MaturityBadge.color(source.maturity).opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
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
