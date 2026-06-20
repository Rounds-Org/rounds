//
//  OnboardingView.swift
//  rounds
//
//  A proper product introduction: what Rounds is, that it runs on the user's own Claude
//  Code, that files stay local and the Rounds team can't see them, that it's grounded in
//  sources, and the install checklist. Name capture happens on the first upload.
//

import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var app
    @State private var page = 0
    @State private var rechecking = false

    // About you
    @State private var name = ""
    @State private var smoking = ""
    @State private var conditions = ""
    @State private var allergies = ""
    @State private var other = ""

    private let lastSlide = 5   // index of the checklist

    private var combinedContext: String {
        var parts: [String] = []
        func add(_ label: String, _ v: String) {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { parts.append("\(label): \(t)") }
        }
        add("Smoking / alcohol", smoking)
        add("Past surgeries & injuries", conditions)
        add("Allergies", allergies)
        add("Other", other)
        return parts.joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                Slide(icon: "stethoscope", accent: true,
                      title: "Clarity about your health",
                      text: "Rounds is your personal health researcher. Drop in your medical documents and it organizes them, explains them in plain language from trusted sources, and proposes the right next steps — for you and your family.",
                      bullets: []).tag(0)

                Slide(icon: "cpu", accent: false,
                      title: "Powered by Claude Code, on your Mac",
                      text: "Rounds doesn't have its own AI servers. It uses the Claude Code you already have installed — running locally on this Mac as the brain that reads and reasons over your documents.",
                      bullets: [
                        ("bolt", "Native and fast — no web app, no lag"),
                        ("arrow.triangle.2.circlepath", "Improves as Claude Code improves")
                      ]).tag(1)

                Slide(icon: "lock.shield", accent: true,
                      title: "Your files never leave your Mac",
                      text: "Everything lives in a plain folder on your computer. There is no Rounds backend — the Rounds team cannot see your documents, your name, or your results.",
                      bullets: [
                        ("externaldrive", "Stored as ordinary files in ~/Rounds"),
                        ("eye.slash", "Only de-identified, concept-only questions ever reach public medical databases"),
                        ("hand.raised", "No account. No upload. No tracking of health data")
                      ]).tag(2)

                Slide(icon: "doc.text.magnifyingglass", accent: false,
                      title: "Grounded in sources, never guesses",
                      text: "Rounds never draws conclusions from its own memory, and never from a scan image without a written report. Every clinical statement is backed by trust-ranked sources — guidelines and systematic reviews rank above case reports — shown right next to the answer.",
                      bullets: [
                        ("checkmark.seal", "Real citations you can open and check"),
                        ("exclamationmark.bubble", "If there's no good source, it says so")
                      ]).tag(3)

                aboutSlide.tag(4)
                checklistSlide.tag(5)
            }
            .tabViewStyle(.automatic)
            .frame(height: 440)

            footer
        }
        .frame(width: 600)
        .background(Theme.bg)
    }

    private var footer: some View {
        HStack {
            if page > 0 {
                Button("Back") { withAnimation { page -= 1 } }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Spacer()
            PageDots(count: lastSlide + 1, index: page)
            Spacer()
            if page < lastSlide {
                Button("Next") { withAnimation { page += 1 } }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
            } else {
                Button(app.checklistComplete ? "Start" : "Start anyway") {
                    app.finishOnboarding(name: name, context: combinedContext)
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
        }
        .padding(18)
    }

    private var checklistSlide: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("One-time setup").font(.title2.weight(.semibold))
                Text("Rounds' brain is Claude Code, which runs on Node.js. You fund your own Claude usage — Rounds adds no cost of its own.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ChecklistRow(done: app.toolPaths.claudeInstalled, title: "Claude Code",
                         detail: app.toolPaths.claude ?? "Not found — install from claude.com/code",
                         link: app.toolPaths.claudeInstalled ? nil : "https://claude.com/code")
            ChecklistRow(done: app.toolPaths.nodeInstalled, title: "Node.js",
                         detail: app.toolPaths.node ?? "Not found — install from nodejs.org",
                         link: app.toolPaths.nodeInstalled ? nil : "https://nodejs.org")
            ChecklistRow(done: app.brainInstalled, title: "Rounds brain",
                         detail: app.brainInstalled ? "Installed in ~/Rounds" : "Installs automatically once the tools are found")

            HStack {
                Button {
                    rechecking = true
                    Task { await app.refreshTools(); rechecking = false }
                } label: {
                    Label(rechecking ? "Checking…" : "Re-check", systemImage: "arrow.clockwise")
                }
                .disabled(rechecking)
                Spacer()
                HStack(spacing: 6) {
                    Text("Model").font(.caption).foregroundStyle(.secondary)
                    ModelPicker()
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 30).padding(.vertical, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var aboutSlide: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("About you").font(.title2.weight(.semibold))
                Text("This sets up your profile and gives Rounds useful background. Everything is optional except your name, and you can edit it later in Settings.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                field("Your name", required: true) { TextField("e.g. Mikhail", text: $name).textFieldStyle(.roundedBorder) }

                HStack(spacing: 8) {
                    Text("Answer language").font(.callout)
                    Spacer()
                    Picker("", selection: Binding(get: { app.language }, set: { app.language = $0 })) {
                        ForEach(["Auto (match the user)", "English", "Russian", "Spanish", "German",
                                 "French", "Portuguese", "Ukrainian", "Hindi", "Chinese (Simplified)"], id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(maxWidth: 220)
                }

                multiField("Smoking / alcohol", $smoking, "e.g. non-smoker, occasional wine")
                multiField("Past surgeries & injuries", $conditions, "e.g. appendectomy 2018")
                multiField("Allergies", $allergies, "e.g. penicillin")
                multiField("Anything else useful", $other, "chronic conditions, family history, where you live now…")

                Divider()
                Toggle(isOn: Binding(get: { !app.analyticsOptOut }, set: { app.analyticsOptOut = !$0 })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Share anonymous usage stats").font(.caption)
                        Text("Counts and feature events only — never your documents, names, or health data.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }.toggleStyle(.switch).tint(Theme.accent)
            }
            .padding(.horizontal, 30).padding(.vertical, 18)
        }
    }

    @ViewBuilder private func field(_ label: String, required: Bool = false, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label + (required ? "" : " (optional)")).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
    private func multiField(_ label: String, _ binding: Binding<String>, _ placeholder: String) -> some View {
        field(label) {
            TextField(placeholder, text: binding, axis: .vertical)
                .lineLimit(1...3).textFieldStyle(.roundedBorder)
        }
    }
}

private struct Slide: View {
    let icon: String
    var accent: Bool
    let title: String
    let text: String
    let bullets: [(String, String)]

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 8)
            ZStack {
                Circle().fill(accent ? Theme.accentSoft : Theme.panel)
                    .frame(width: 92, height: 92)
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(Theme.accent)
            }
            Text(title).font(.title.weight(.semibold)).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(LocalizedStringKey(text))
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 44)
                .fixedSize(horizontal: false, vertical: true)
            if !bullets.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(bullets, id: \.1) { b in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: b.0).font(.callout).foregroundStyle(Theme.accent).frame(width: 18)
                            Text(b.1).font(.callout).foregroundStyle(.primary.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 50).padding(.top, 2)
            }
            Spacer(minLength: 8)
        }
        .padding(.top, 8)
    }
}

struct ChecklistRow: View {
    let done: Bool
    let title: String
    let detail: String
    var link: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Theme.accent : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                if let link, let url = URL(string: link) {
                    Link(detail, destination: url).font(.caption)
                } else {
                    Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct PageDots: View {
    let count: Int
    let index: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Circle().fill(i == index ? Theme.accent : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
    }
}
