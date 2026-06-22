//
//  OnboardingView.swift
//  rounds
//
//  A short, concrete intro. A welcome with the app mark; a few core feature/value slides, each
//  with a small mock of the real UI so nothing is abstract; an honest note on how data flows
//  (records are analyzed by the user's OWN Claude — there's no Rounds server); then name, a little
//  context, and notification permission. No buzzwords, no real personal names in examples.
//

import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var app
    @State private var page = 0
    @State private var rechecking = false
    @State private var notifGranted = false
    @State private var notifAsked = false

    // About you
    @State private var name = ""
    @State private var smoking = ""
    @State private var conditions = ""
    @State private var allergies = ""
    @State private var other = ""

    private let lastSlide = 8   // checklist

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
                welcomeSlide.tag(0)

                OnboardSlide(
                    title: "From your records to clear next steps",
                    text: "Drop in a lab result or report. Rounds reads it on your Mac, explains it in plain language, and proposes specific things to do next."
                ) { ExampleDocsToSteps() }.tag(1)

                OnboardSlide(
                    title: "It cites sources — it doesn't guess",
                    text: "Every clinical statement is backed by a real source you can open, ranked by trust (guidelines and reviews over case reports). No good source? Rounds says so."
                ) { ExampleSourced() }.tag(2)

                OnboardSlide(
                    title: "Your whole family, in one place",
                    text: "Keep records for your parents, partner, and kids. Rounds reasons across them — a family history can reveal risks worth screening for earlier."
                ) { ExampleFamily() }.tag(3)

                OnboardSlide(
                    title: "Runs on your own Claude Code",
                    text: "Rounds has no servers. It uses the Claude already on your Mac, so your records go to Claude and nowhere else — never to the Rounds team. Originals stay in a folder you control."
                ) { ExampleClaude() }.tag(4)

                nameSlide.tag(5)
                aboutSlide.tag(6)
                notificationsSlide.tag(7)
                checklistSlide.tag(8)
            }
            .tabViewStyle(.automatic)
            .frame(height: 460)

            footer
        }
        .frame(width: 600)
        .background(Theme.bg)
    }

    // MARK: welcome

    private var welcomeSlide: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)
            Image("RoundsIcon")
                .resizable().scaledToFit()
                .frame(width: 108, height: 108)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            VStack(spacing: 8) {
                Text("Welcome to Rounds").zfont(.largeTitle, .bold)
                Text("Your health researcher — on your Mac, powered by Claude Code.")
                    .zfont(.title3).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 50)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle(isOn: Binding(get: { !app.analyticsOptOut }, set: { app.analyticsOptOut = !$0 })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Share anonymous usage stats").zfont(.caption)
                    Text("Counts and feature events only — never your documents, names, or health data.")
                        .zfont(.caption2).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch).tint(Theme.accent)
            .padding(.horizontal, 40)
            Spacer(minLength: 8)
        }
        .padding(.top, 12)
    }

    // MARK: name

    private var nameSlide: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 8)
            Image(systemName: "person.text.rectangle").zfont(size: 38).foregroundStyle(Theme.accent)
            VStack(spacing: 8) {
                Text("What's your name?").zfont(.title2, .semibold)
                Text("Your full name — first and last. Rounds uses it to match the documents you add to the right person.")
                    .zfont(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 44)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("e.g. Mike Smith", text: $name)
                .textFieldStyle(.roundedBorder).zfont(.title3)
                .frame(maxWidth: 300)
            Spacer(minLength: 8)
        }
        .padding(.top, 12)
    }

    // MARK: notifications

    private var notificationsSlide: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 8)
            Image(systemName: notifGranted ? "bell.badge.fill" : "bell").zfont(size: 38).foregroundStyle(Theme.accent)
            VStack(spacing: 8) {
                Text("Stay in the loop").zfont(.title2, .semibold)
                Text("Rounds reviews new documents in the background. Get a notification when it finishes and your next steps change — nothing if nothing changed.")
                    .zfont(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 44)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if notifGranted {
                Label("Notifications on", systemImage: "checkmark.circle.fill")
                    .zfont(.callout).foregroundStyle(Theme.accent)
            } else {
                Button {
                    Task { notifGranted = await app.requestNotificationAuthorization(); notifAsked = true }
                } label: { Label("Turn on notifications", systemImage: "bell.fill") }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                if notifAsked {
                    Text("If nothing happened, enable Rounds in System Settings → Notifications.")
                        .zfont(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.top, 12)
    }

    // MARK: footer

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

    // MARK: checklist

    private var checklistSlide: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("One-time setup").zfont(.title2, .semibold)
                    Text("Rounds is a Mac app. Its brain is Claude Code — the AI — which runs on Node.js. Both live on your own Mac; Rounds has no servers. These two just need to be installed once. Here's what Rounds found on your machine:")
                        .zfont(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ChecklistRow(done: app.toolPaths.claudeInstalled, title: "Claude Code",
                             detail: app.toolPaths.claude ?? "Not found — install from claude.com/code",
                             link: app.toolPaths.claudeInstalled ? nil : "https://claude.com/code")
                ChecklistRow(done: app.toolPaths.nodeInstalled, title: "Node.js",
                             detail: app.toolPaths.node ?? "Not found — install from nodejs.org",
                             link: app.toolPaths.nodeInstalled ? nil : "https://nodejs.org")
                ChecklistRow(done: app.brainInstalled, title: "Rounds brain",
                             detail: app.brainInstalled ? "Installed in ~/Rounds" : "Installs automatically once the tools above are found")

                // Prominent escape hatch for non-technical users: screenshot this window → Claude.
                HStack(alignment: .top, spacing: 13) {
                    Image(systemName: "camera.viewfinder")
                        .zfont(.largeTitle).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Don't want to install this yourself? Let Claude do it.")
                            .zfont(.headline)
                        Text("Take a screenshot of this window — press ⌘⇧4, then Space, then click the window — and send it to Claude (the Claude app, or claude.ai). Claude can see exactly what's missing here and will install it for you, or walk you through it step by step.")
                            .zfont(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.accent.opacity(0.55), lineWidth: 1.5))

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
                        Text("Model").zfont(.caption).foregroundStyle(.secondary)
                        ModelPicker()
                    }
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 30).padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: about

    private var aboutSlide: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("A little about you").zfont(.title2, .semibold)
                Text("Optional background that helps Rounds reason about your records. You can edit it later in Settings.")
                    .zfont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text("Answer language").zfont(.callout)
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
            }
            .padding(.horizontal, 30).padding(.vertical, 18)
        }
    }

    private func multiField(_ label: String, _ binding: Binding<String>, _ placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label + " (optional)").zfont(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: binding, axis: .vertical)
                .lineLimit(1...3).textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - Slide shell (UI example on top, clear title + 1–2 sentences below)

private struct OnboardSlide<Example: View>: View {
    let title: String
    let text: String
    @ViewBuilder var example: () -> Example

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 6)
            example()
                .frame(maxWidth: .infinity)
                .frame(height: 184)
            VStack(spacing: 8) {
                Text(title).zfont(.title2, .semibold)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Text(text).zfont(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
        }
        .padding(.top, 10)
    }
}

// MARK: - Mini UI mocks (decorative — echo the real components in miniature)

private struct MockCard<Content: View>: View {
    var width: CGFloat? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(11)
            .frame(width: width, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }
}

private struct MiniPill: View {
    let text: String
    var body: some View {
        Text(text).zfont(.caption2, .medium)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.accentSoft, in: Capsule()).foregroundStyle(Theme.accent)
    }
}

private struct DocChip: View {
    let name: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "doc.text.fill").zfont(.caption2).foregroundStyle(Theme.accent)
            Text(name).zfont(.caption2).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairline))
    }
}

// Slide 1 — documents → a next step
private struct ExampleDocsToSteps: View {
    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 7) {
                DocChip(name: "blood-test.pdf")
                DocChip(name: "ultrasound.pdf")
                DocChip(name: "cardiology.jpg")
            }
            Image(systemName: "arrow.right").zfont(.callout).foregroundStyle(.secondary)
            MockCard(width: 210) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ask your GP for a repeat ferritin + iron studies, then add the result here")
                        .zfont(.caption, .medium).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 5) { MiniPill(text: "get more data"); TierBadge(tier: "T1") }
                }
            }
        }
    }
}

// Slide 2 — a cited sentence + the source it opens
private struct ExampleSourced: View {
    var body: some View {
        VStack(spacing: 10) {
            MockCard(width: 320) {
                (Text("Your ferritin is 9 µg/L — below the 30–400 reference range ")
                 + Text("[1]").foregroundColor(Theme.accent).fontWeight(.semibold))
                    .zfont(.caption).fixedSize(horizontal: false, vertical: true)
            }
            MockCard(width: 320) {
                HStack(alignment: .top, spacing: 9) {
                    Text("1").zfont(.caption2, .bold).foregroundStyle(Theme.accent)
                        .frame(width: 18, height: 18).background(Circle().fill(Theme.accentSoft))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Guideline for the management of iron deficiency anaemia")
                            .zfont(.caption2, .medium).lineLimit(2)
                        HStack(spacing: 5) {
                            TierBadge(tier: "T1")
                            Text("Br J Haematol · 2021").zfont(.caption2).foregroundStyle(.secondary)
                            Image(systemName: "arrow.up.right.square").zfont(.caption2).foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
        }
    }
}

// Slide 3 — the family: people chips + a cross-referenced insight
private struct ExampleFamily: View {
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                personChip("You", "person.fill")
                personChip("Mom", "person")
                personChip("Dad", "person")
                personChip("Kids", "figure.child")
            }
            MockCard(width: 320) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "link").zfont(.caption2).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Worth discussing earlier screening")
                            .zfont(.caption, .medium)
                        Text("Two first-degree relatives with the same condition can lower the recommended screening age [1]")
                            .zfont(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
    private func personChip(_ name: String, _ icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).zfont(.caption2).foregroundStyle(Theme.accent)
            Text(name).zfont(.caption2, .medium)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(Theme.panel, in: Capsule()).overlay(Capsule().stroke(Theme.hairline))
    }
}

// Slide 4 — the Claude logo + an honest data-flow note
private struct ExampleClaude: View {
    var body: some View {
        VStack(spacing: 16) {
            Image("ClaudeLogo")
                .resizable().scaledToFit()
                .frame(width: 78, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 18))
            HStack(spacing: 12) {
                flowNode(icon: "laptopcomputer", label: "Your Mac")
                Image(systemName: "arrow.left.arrow.right").zfont(.caption).foregroundStyle(.secondary)
                flowNode(icon: "sparkle", label: "Claude")
            }
            Text("No Rounds server in between · delete everything anytime")
                .zfont(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func flowNode(icon: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).zfont(.caption).foregroundStyle(Theme.accent)
            Text(label).zfont(.caption, .medium)
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(Theme.panel, in: Capsule())
        .overlay(Capsule().stroke(Theme.hairline))
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
                .zfont(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).zfont(.body, .medium)
                if let link, let url = URL(string: link) {
                    Link(detail, destination: url).zfont(.caption)
                } else {
                    Text(detail).zfont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
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
