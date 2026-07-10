//
//  DashboardView.swift
//  rounds
//
//  Home: greeting, the main ask box, the onboarding checklist (until done), hypothesis
//  cards (the core "next steps" entity), and recent chats.
//

import SwiftUI
import AppKit

struct DashboardView: View {
    @Environment(AppState.self) private var app
    // The Home composer draft lives on AppState (so the drag handler + mic can reach it).
    private var askBinding: Binding<String> { Binding(get: { app.homeDraft }, set: { app.homeDraft = $0 }) }
    private var askRefsBinding: Binding<[Reference]> { Binding(get: { app.homeDraftRefs }, set: { app.homeDraftRefs = $0 }) }
    @State private var stepPersonFilter: String?   // nil = everyone
    @State private var collapsedPeople: Set<String> = []   // person groups collapsed in Next steps

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let alert = app.urgentBanner { UrgentBanner(alert: alert) }

                header

                askBox

                if !app.checklistComplete {
                    checklistCard
                }

                if app.checklistComplete, !starterDone { gettingStartedCard }

                nextSteps

                if !app.chats.isEmpty {
                    recentChats
                }

                if !archivedHypotheses.isEmpty {
                    archivedSteps
                }

                featureBanner

                Spacer(minLength: 24)
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Theme.bg)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(app.displayName.isEmpty ? "Hello" : "Hello, \(app.displayName)")
                    .zfont(.largeTitle, .semibold)
                Text("Your health researcher. Drop a document or ask a question.")
                    .zfont(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var askBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !app.homeDraftRefs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(app.homeDraftRefs) { ref in
                            RefAttachment(ref: ref, compact: true) { app.removeHomeDraftAttachment(ref) }
                        }
                    }
                    .padding(.top, 6).padding(.trailing, 6)
                }
            }
            MentionField(text: askBinding, references: askRefsBinding,
                         placeholder: "Ask about a result, or @-reference a document…",
                         onSend: submit,
                         onRegisterTextView: { app.homeInputTextView = $0 })
            HStack(spacing: 10) {
                InputControls()
                Divider().frame(height: 12)
                ResearchStagePicker(stage: Binding(get: { app.researchStage }, set: { app.researchStage = $0 }))
                Spacer()
                VoiceInputButton()
                homeAttachMenu
            }
            .foregroundStyle(.primary)
        }
        .padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
    }

    // Paperclip on Home: choose the destination (a new chat vs. Rounds' general filing), then pick files.
    private var homeAttachMenu: some View {
        Menu {
            Button { pickAndAttach(toNewChat: true) } label: { Label("Attach to a new chat", systemImage: "bubble.left") }
            Button { pickAndAttach(toNewChat: false) } label: { Label("Add to Rounds (read & file)", systemImage: "tray.and.arrow.down") }
        } label: {
            Image(systemName: "paperclip").zfont(.body, .medium).foregroundStyle(.primary)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Attach a document — to a new chat, or to Rounds for filing")
    }

    private func pickAndAttach(toNewChat: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Attach"
        panel.message = toNewChat ? "Add document(s) to a new chat" : "Add document(s) to Rounds"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        if toNewChat { app.attachFilesToHomeDraft(panel.urls) } else { app.beginImport(panel.urls) }
    }

    private func submit() {
        let text = app.homeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let refs = app.homeDraftRefs
        app.homeDraft = ""; app.homeDraftRefs = []
        // Everything typed here opens a chat — the home box behaves exactly like the chat input.
        let id = app.startNewChat()
        let finalRefs = app.rehomePendingRefs(refs, toChat: id)
        app.beginSendChat(text, references: finalRefs)
    }

    private var checklistCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Finish setup")
            ChecklistRow(done: app.toolPaths.claudeInstalled, title: "Claude Code",
                         detail: app.toolPaths.claude ?? "Install from claude.com/code",
                         link: app.toolPaths.claudeInstalled ? nil : "https://claude.com/code")
            ChecklistRow(done: app.toolPaths.nodeInstalled, title: "Node.js",
                         detail: app.toolPaths.node ?? "Install from nodejs.org",
                         link: app.toolPaths.nodeInstalled ? nil : "https://nodejs.org")
            Button { Task { await app.refreshTools() } } label: {
                Label("Re-check", systemImage: "arrow.clockwise")
            }.buttonStyle(.bordered)
        }
        .padding(16)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
    }

    // Feature-discovery checklist so a new user sees what Rounds can do. Each row lights up once done.
    private struct StarterStep: Identifiable { let id = UUID(); let icon: String; let title: String; let detail: String; let done: Bool }
    private var starterSteps: [StarterStep] {
        [
            .init(icon: "tray.and.arrow.down.fill", title: "Add a health record",
                  detail: "Drag in a lab result, report, or a photo of a test — Rounds reads it on your Mac.",
                  done: !app.documents.isEmpty),
            .init(icon: "checklist", title: "Get your next steps",
                  detail: "Rounds turns your records into specific, sourced things to do next.",
                  done: app.hypotheses.contains { !["superseded", "dismissed"].contains($0.status) }),
            .init(icon: "bubble.left.and.text.bubble.right", title: "Answer a question from Rounds",
                  detail: "It asks the questions a good clinician would, to narrow things down.",
                  done: app.hypotheses.contains { $0.isQuestion && !($0.answer?.isEmpty ?? true) }),
            .init(icon: "person.2.fill", title: "Add a family member",
                  detail: "Keep records for parents, partner, kids — Rounds spots risks across the family (with their OK 🙂).",
                  done: app.people.contains { $0.slug != "_self" }),
            .init(icon: "doc.text.magnifyingglass", title: "Open a source",
                  detail: "Every claim links to real medical evidence you can read yourself.",
                  done: app.hypotheses.contains { $0.sourceCount > 0 }),
        ]
    }
    private var starterDone: Bool { starterSteps.allSatisfy { $0.done } }

    private var gettingStartedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                Text("Get started with Rounds").zfont(.callout, .semibold)
                Spacer()
                Text("\(starterSteps.filter(\.done).count)/\(starterSteps.count)")
                    .zfont(.caption2).foregroundStyle(.secondary)
            }
            ForEach(starterSteps) { s in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: s.done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(s.done ? Theme.accent : .secondary).zfont(.body)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.title).zfont(.callout, .medium)
                            .foregroundStyle(s.done ? .secondary : .primary)
                            .strikethrough(s.done, color: .secondary)
                        Text(s.detail).zfont(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(16)
        .background(Theme.accentSoft.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.18)))
    }

    private var nextSteps: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "Next steps")
                if questionCount > 0 {
                    Text("\(questionCount) to answer")
                        .zfont(.caption2, .medium)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.accentSoft, in: Capsule()).foregroundStyle(Theme.accent)
                }
                Spacer()
                if app.people.count > 1 {
                    Menu {
                        Button { stepPersonFilter = nil } label: { Label("Everyone", systemImage: stepPersonFilter == nil ? "checkmark" : "") }
                        Divider()
                        ForEach(app.people) { p in
                            Button { stepPersonFilter = p.slug } label: {
                                Label(p.displayName, systemImage: stepPersonFilter == p.slug ? "checkmark" : "")
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "person.crop.circle").zfont(.caption2)
                            Text(stepPersonFilter.flatMap { pf in app.people.first { $0.slug == pf }?.displayName } ?? "Everyone")
                                .zfont(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                if app.identifyingNextSteps {
                    IdentifyingIndicator()
                } else if !app.documents.isEmpty {
                    Button { app.beginHypotheses() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).zfont(.caption).foregroundStyle(.secondary)
                        .help("Refresh next steps")
                        .disabled(app.isStreaming)
                }
            }

            if activeHypotheses.isEmpty {
                if app.identifyingNextSteps {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Working through your records…").zfont(.callout).foregroundStyle(.secondary) }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                } else {
                    emptyHypotheses
                }
            } else {
                ForEach(groupedHypotheses, id: \.slug) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        if showGroupHeaders {
                            Button { withAnimation { toggleCollapse(group.slug) } } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: collapsedPeople.contains(group.slug) ? "chevron.right" : "chevron.down")
                                        .zfont(.caption2).foregroundStyle(.secondary)
                                    Text(groupName(group.slug) ?? "You").zfont(.caption, .semibold).foregroundStyle(.secondary)
                                    Text("\(group.hyps.count)").zfont(.caption2).foregroundStyle(.tertiary)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).linkCursor()
                        }
                        if !collapsedPeople.contains(group.slug) {
                            ForEach(group.hyps) { HypothesisCard(hyp: $0).transition(.opacity) }
                        }
                    }
                }
            }
        }
    }

    // MARK: next-steps grouping (by person; the person with the newest card shows first)

    /// Extract the yyyy-mm-dd embedded in a hypothesis id (ids look like `hyp_2026-06-21_slug`).
    private func hypDate(_ h: Hypothesis) -> String {
        if let r = h.id.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) { return String(h.id[r]) }
        return ""
    }
    /// Display name for a person group header (nil → render as "You").
    private func groupName(_ slug: String) -> String? {
        if slug == "_self" { return "You" }
        let p = app.people.first { $0.slug == slug }
        let name = p?.displayName ?? slug
        if let rel = p?.relationship, rel != "self" { return "\(name) · \(rel)" }
        return name
    }
    private var groupedHypotheses: [(slug: String, hyps: [Hypothesis])] {
        Dictionary(grouping: activeHypotheses, by: { $0.personId })
            .map { (slug: $0.key, hyps: $0.value) }
            .sorted { a, b in
                let da = a.hyps.map(hypDate).max() ?? "", db = b.hyps.map(hypDate).max() ?? ""
                if da != db { return da > db }                 // newest-card person first
                if (a.slug == "_self") != (b.slug == "_self") { return a.slug == "_self" }  // then You
                return a.slug < b.slug
            }
    }
    private var showGroupHeaders: Bool { groupedHypotheses.count > 1 }
    private func toggleCollapse(_ slug: String) {
        if collapsedPeople.contains(slug) { collapsedPeople.remove(slug) } else { collapsedPeople.insert(slug) }
    }

    private var archivedSet: Set<String> { ["superseded", "done", "dismissed"] }
    private var activeHypotheses: [Hypothesis] {
        app.hypotheses.filter { !archivedSet.contains($0.status) }
            .filter { stepPersonFilter == nil || $0.personId == stepPersonFilter }
    }
    private var questionCount: Int { activeHypotheses.filter { $0.isQuestion && ($0.answer?.isEmpty ?? true) }.count }
    private var archivedHypotheses: [Hypothesis] { app.hypotheses.filter { archivedSet.contains($0.status) } }

    @State private var showArchived = false
    private var archivedSteps: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation { showArchived.toggle() } } label: {
                HStack {
                    SectionHeader(title: "Archived steps")
                    Text("\(archivedHypotheses.count)").zfont(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Image(systemName: showArchived ? "chevron.up" : "chevron.down")
                        .zfont(.caption2).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())   // whole header row is the hit target
            }
            .buttonStyle(.plain)
            .linkCursor()
            if showArchived {
                VStack(spacing: 8) {
                    ForEach(archivedHypotheses) { HypothesisCard(hyp: $0) }
                }
                .padding(.top, 6)
            }
        }
    }

    private let suggestedDocs = [
        ("drop.fill", "A recent blood test or lab panel"),
        ("waveform.path.ecg", "An imaging report — ultrasound, CT, MRI, X-ray"),
        ("doc.text", "A specialist's note or discharge summary"),
        ("camera.fill", "A photo of skin, a nail, or swelling"),
    ]
    private var emptyHypotheses: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: app.documents.isEmpty ? "tray.and.arrow.down.fill" : "checkmark.seal.fill")
                    .foregroundStyle(app.documents.isEmpty ? Theme.accent : .green)
                Text(app.documents.isEmpty ? "Let's get started" : "You're all caught up")
                    .zfont(.callout, .semibold)
            }
            Text(app.documents.isEmpty
                 ? "Add a health record and Rounds will read it on your Mac, file it, and propose the right next steps — nothing leaves your computer."
                 : "No open next steps right now — that's a good place to be. Add more records and Rounds will find what's worth doing next.")
                .zfont(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 5) {
                Text("Helpful things to add").zfont(.caption2, .semibold).foregroundStyle(.tertiary)
                ForEach(suggestedDocs, id: \.1) { icon, label in
                    HStack(spacing: 7) {
                        Image(systemName: icon).zfont(.caption2).foregroundStyle(Theme.accent).frame(width: 16)
                        Text(label).zfont(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))

            Text(app.documents.isEmpty
                 ? "Drag any of these onto the window — or ask a question in the box above."
                 : "Drag a new record onto the window, or ask a question above.")
                .zfont(.caption2).foregroundStyle(.tertiary)
            if !app.documents.isEmpty {
                Button { app.beginHypotheses() } label: { Label("Find next steps now", systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
    }

    private var featureBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars").zfont(.caption).foregroundStyle(.secondary)
            Text("Want a feature? Rounds is open source — ask your Claude Code to clone the repo and build it for you.")
                .zfont(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                if let url = URL(string: "https://github.com/Rounds-Org/rounds") { NSWorkspace.shared.open(url) }
            } label: { Label("Open repo", systemImage: "arrow.up.right.square") }
                .zfont(.caption2).buttonStyle(.borderless).tint(Theme.accent)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.panel.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairline))
    }

    private var recentChats: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Recent chats")
            ForEach(app.chats.prefix(8)) { chat in
                Button { app.openChat(chat) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "bubble.left").foregroundStyle(.secondary)
                        Text(chat.title).lineLimit(1)
                        Spacer()
                        if app.isChatStreaming(chat.id) {
                            HStack(spacing: 5) {
                                ProgressView().controlSize(.mini)
                                Text("working…").zfont(.caption2).foregroundStyle(Theme.accent)
                            }
                        } else {
                            Text(chat.updatedAt.formatted(.relative(presentation: .named)))
                                .zfont(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 7).padding(.horizontal, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background((app.isChatStreaming(chat.id) ? Theme.accentSoft : Theme.panel.opacity(0.6)),
                            in: RoundedRectangle(cornerRadius: 8))
                .contextMenu {
                    Button("Open") { app.openChat(chat) }
                    Divider()
                    Button("Delete", role: .destructive) { app.deleteChat(chat.id) }
                }
            }
        }
    }
}

/// A red flag surfaced from the background next-steps lane (Principle 6). Prominent, dismissible.
struct UrgentBanner: View {
    @Environment(AppState.self) private var app
    let alert: RoundsAlert
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.message).zfont(.callout, .semibold).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                if let m = alert.marker {
                    Text(m + (alert.value.map { ": \($0)" } ?? "") + (alert.basis.map { " · \($0)" } ?? ""))
                        .zfont(.caption2).foregroundStyle(.white.opacity(0.85))
                }
            }
            Spacer()
            Button { app.urgentBanner = nil } label: { Image(systemName: "xmark").foregroundStyle(.white.opacity(0.9)) }
                .buttonStyle(.borderless)
        }
        .padding(14)
        .background(Theme.warn, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// While next steps generate, this links to the live Claude Code session (a real chat the user can
/// open, watch, and continue). Underlines + shows a pointer on hover; click opens the session chat.
struct IdentifyingIndicator: View {
    @Environment(AppState.self) private var app
    @State private var hovering = false

    var body: some View {
        Button { app.openNextStepsChat() } label: {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(app.nextStepsStatus.isEmpty ? "Identifying next steps…" : app.nextStepsStatus)
                    .zfont(.caption, .medium).foregroundStyle(Theme.accent).lineLimit(1)
                    .underline(hovering)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkCursor()
        .onHover { hovering = $0 }
    }
}

struct HypothesisCard: View {
    @Environment(AppState.self) private var app
    let hyp: Hypothesis
    @State private var expanded = false
    @State private var draft = ""

    var body: some View {
        Group {
            if hyp.isQuestion && (hyp.answer?.isEmpty ?? true) { questionBody }
            else if hyp.isQuestion { answeredBody }
            else { actionBody }
        }
        .padding(16)
        .background((hyp.isQuestion && !(hyp.answer?.isEmpty ?? true)) ? Theme.panel.opacity(0.5) : Theme.panel,
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
    }

    // A patient-history question awaiting the user's answer (inline).
    private var questionBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                if let person = personLabel {
                    Label(person, systemImage: "person").zfont(.caption2).foregroundStyle(Theme.accent)
                }
                HStack(spacing: 5) {
                    Image(systemName: "bubble.left.and.text.bubble.right").zfont(.caption2)
                    Text("A quick question").zfont(.caption2, .semibold)
                }
                .foregroundStyle(Theme.accent)
                Text(hyp.title).zfont(.headline).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !hyp.whyNow.isEmpty {
                    Text(hyp.whyNow).zfont(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            if app.answeringStep == hyp.id {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Recording your answer and updating your next steps…").zfont(.caption).foregroundStyle(.secondary)
                }
            } else {
                TextField(hyp.askPlaceholder ?? "Your answer — a sentence or two is plenty", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...5)
                    .padding(10)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
                HStack {
                    Button("Chat about this instead") { app.chatAbout(hyp) }
                        .zfont(.caption).buttonStyle(.borderless).tint(Theme.accent)
                    Spacer()
                    Button {
                        let a = draft; draft = ""
                        Task { await app.answerQuestionStep(hyp, answer: a) }
                    } label: { Label("Submit", systemImage: "paperplane.fill") }
                        .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    // A question the user already answered — muted, read-only audit trail.
    private var answeredBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.bubble").zfont(.caption2)
                Text("Answered" + (hyp.answeredAt.map { " · \($0)" } ?? "")).zfont(.caption2)
                Spacer()
            }
            .foregroundStyle(.tertiary)
            Text(hyp.title).zfont(.subheadline, .medium).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let a = hyp.answer, !a.isEmpty {
                Text(a).zfont(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var actionBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                // Compact, Linear-style: just the title collapsed; the "why now" description shows
                // only in the expanded (full) view below.
                Text(hyp.title).zfont(.subheadline, .medium)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation { expanded.toggle() } }   // tap the title to open, like Details
                Pill(text: hyp.priority, color: priorityColor)
            }
            HStack(spacing: 8) {
                Pill(text: hyp.kind.replacingOccurrences(of: "-", with: " "))
                if hyp.sourceCount > 0 { SourcesHoverLabel(hyp: hyp) }
                Spacer()
                Button(expanded ? "Hide" : "Details") { withAnimation { expanded.toggle() } }
                    .zfont(.caption).buttonStyle(.borderless)
                Button("Chat about this") { app.chatAbout(hyp) }
                    .zfont(.caption, .medium).buttonStyle(.borderless).tint(Theme.accent)
            }
            if expanded {
                Text(hyp.whyNow).zfont(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let body = hyp.body {
                    Divider()
                    let clean = stripFrontMatter(body)
                    // One selectable AttributedString so you can drag-select across ALL paragraphs
                    // (the per-block renderer only let you select one paragraph at a time). Tables
                    // keep the grid renderer.
                    if MarkdownText.hasTable(clean) {
                        MarkdownText(clean).zfont(.callout)
                    } else {
                        Text(MarkdownText.fullAttributed(clean))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Questions? Need clarification? Any ideas?")
                        .zfont(.callout, .medium)
                    Text("Talk it through with Rounds — refine this step, ask what a result would mean, or decide it's already handled.")
                        .zfont(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { app.chatAbout(hyp) } label: {
                        Label("Chat about this", systemImage: "bubble.left.and.text.bubble.right")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    // Resolve lives here — only in the open card, beside the big Chat button. Fades out.
                    Button { app.resolveHypothesis(hyp) } label: {
                        Label("Mark as resolved", systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.bordered).tint(.secondary)
                    .help("Mark this next step done — moves it to Archived.")
                }
                .padding(.top, 4)
            }
        }
    }

    private var priorityColor: Color {
        switch hyp.priority { case "high": Theme.warn; case "medium": Theme.accent; default: .secondary }
    }

    private var personLabel: String? {
        guard hyp.personId != "_self" else { return nil }
        let p = app.people.first { $0.slug == hyp.personId }
        let name = p?.displayName ?? hyp.personId
        if let rel = p?.relationship, rel != "self" { return "\(name) · \(rel)" }
        return name
    }

    private func stripFrontMatter(_ md: String) -> String {
        guard md.hasPrefix("---") else { return md }
        let parts = md.components(separatedBy: "---")
        return parts.count >= 3 ? parts[2...].joined(separator: "---").trimmingCharacters(in: .whitespacesAndNewlines) : md
    }
}

/// The "N sources" label on a next-step card: underlines on hover, opens a popover of clickable
/// source cards on CLICK. The popover dismisses when you click outside it.
struct SourcesHoverLabel: View {
    let hyp: Hypothesis
    @State private var show = false
    @State private var hovering = false

    var body: some View {
        Button { show.toggle() } label: {
            Label("\(hyp.sourceCount) source\(hyp.sourceCount == 1 ? "" : "s")", systemImage: "doc.text.magnifyingglass")
                .zfont(.caption2).foregroundStyle(.secondary)
                .underline(hovering)
        }
        .buttonStyle(.plain)
        .linkCursor()
        .onHover { hovering = $0 }
        .popover(isPresented: $show, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sources").zfont(.caption, .semibold).foregroundStyle(.secondary)
                if hyp.sources.isEmpty {
                    Text("Open “Details” to see the citations behind this step.")
                        .zfont(.caption2).foregroundStyle(.secondary)
                } else {
                    ForEach(hyp.sources) { MiniSourceCard(source: $0) }
                }
            }
            .padding(12).frame(width: 330)
        }
    }
}

/// A compact, clickable source card (opens the DOI/PubMed link).
struct MiniSourceCard: View {
    let source: Source
    var body: some View {
        Button {
            if let u = source.url, let url = URL(string: u) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Text(source.id.replacingOccurrences(of: "S", with: "")).zfont(.caption2, .bold)
                    .foregroundStyle(Theme.accent).frame(width: 18, height: 18).background(Circle().fill(Theme.accentSoft))
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.title).zfont(.caption2, .medium).lineLimit(3).multilineTextAlignment(.leading)
                    HStack(spacing: 5) {
                        TierBadge(tier: source.trustTier)
                        if let y = source.year { Text(String(y)).zfont(.caption2).foregroundStyle(.secondary) }
                        if source.url != nil { Image(systemName: "arrow.up.right.square").zfont(.caption2).foregroundStyle(Theme.accent) }
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
