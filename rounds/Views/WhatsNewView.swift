//
//  WhatsNewView.swift
//  rounds
//
//  "What's new" — the release notes, Yab-changelog style: handwritten "the latest", the version with a
//  hand-drawn circle, the date, then the notes. Read from the public GitHub releases (the same notes
//  shipped with each update), so there's no second copy to keep in sync. Opens once after an update.
//

import SwiftUI

struct WhatsNewView: View {
    private struct Release: Decodable, Identifiable {
        let tag_name: String
        let name: String?
        let body: String?
        let published_at: String?
        var id: String { tag_name }
        var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
        var date: String {
            guard let s = published_at, let d = ISO8601DateFormatter().date(from: s) else { return "" }
            return d.formatted(.dateTime.month(.wide).day().year())
        }
    }

    @State private var releases: [Release] = []
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let latest = releases.first {
                    header(latest)
                    notes(latest.body ?? "")
                    if releases.count > 1 {
                        Divider().padding(.vertical, 34)
                        Text("Earlier").handwritten(30)
                        ForEach(releases.dropFirst()) { r in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text("Rounds \(r.version)").zfont(.title3, .semibold)
                                    Text(r.date).zfont(.callout).foregroundStyle(.tertiary)
                                }
                                MarkdownText(r.body ?? "")
                            }
                            .padding(.top, 22)
                        }
                    }
                } else if failed {
                    Text("Couldn't load the release notes.").zfont(.body).foregroundStyle(.secondary)
                    Link("Open the releases page", destination: URL(string: "https://github.com/Rounds-Org/rounds/releases")!)
                        .padding(.top, 6)
                } else {
                    ProgressView().controlSize(.small).padding(.top, 40)
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 54)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(DotGrid())
        .background(Theme.bg)
        .task { await load() }
    }

    private func header(_ r: Release) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(r.version == UpdateService.currentAppVersion ? "the latest" : "latest release").handwritten(30)
                .padding(.leading, 2).padding(.bottom, -6)
            HStack(alignment: .center, spacing: 18) {
                HStack(spacing: 0) {
                    Text("Rounds ").zfont(size: 52, weight: .semibold)
                    Text(r.version).zfont(size: 52, weight: .semibold)
                        .overlay(   // the hand-drawn circle
                            Ellipse().stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                                .padding(.horizontal, -12).padding(.vertical, -6)
                                .rotationEffect(.degrees(-3))
                        )
                }
                if let d = r.published_at.flatMap({ ISO8601DateFormatter().date(from: $0) }), Calendar.current.isDateInToday(d) {
                    Text("today").handwritten(26)
                }
            }
            Text(r.date).zfont(.callout).foregroundStyle(.tertiary).padding(.top, 4)
        }
        .padding(.bottom, 18)
    }

    /// Release notes are "- **Lead**: detail" bullets; render each as a paragraph, lead in bold.
    private func notes(_ body: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(body.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty {
                    let text = t.hasPrefix("- ") ? String(t.dropFirst(2)) : t
                    Text(MarkdownText.inline(text)).zfont(size: 16).fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(3)
                }
            }
        }
    }

    private func load() async {
        guard releases.isEmpty,
              let url = URL(string: "https://api.github.com/repos/Rounds-Org/rounds/releases?per_page=6") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            releases = try JSONDecoder().decode([Release].self, from: data)
            failed = releases.isEmpty
        } catch { failed = true }
    }
}
