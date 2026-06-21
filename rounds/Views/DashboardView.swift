//
//  DashboardView.swift
//  rounds
//
//  Home: greeting, the main ask box, the onboarding checklist (until done), hypothesis
//  cards (the core "next steps" entity), and recent chats.
//

import SwiftUI

struct DashboardView: View {
    @Environment(AppState.self) private var app
    @State private var ask = ""
    @State private var askRefs: [Reference] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let alert = app.urgentBanner { UrgentBanner(alert: alert) }

                header

                askBox

                if !app.checklistComplete {
                    checklistCard
                }

                if !openComplaints.isEmpty { concernsSection }

                nextSteps

                if !app.chats.isEmpty {
                    recentChats
                }

                if !archivedHypotheses.isEmpty {
                    archivedSteps
                }

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
                    .font(.largeTitle.weight(.semibold))
                Text("Your health researcher. Describe a symptom, drop a document, or ask a question.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            ModelPicker()
        }
    }

    private var askBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !askRefs.isEmpty {
                HStack(spacing: 6) {
                    ForEach(askRefs) { ref in
                        HStack(spacing: 4) {
                            Image(systemName: ref.iconName).font(.caption2)
                            Text(ref.label).font(.caption2).lineLimit(1)
                            Button { askRefs.removeAll { $0 == ref } } label: { Image(systemName: "xmark").font(.system(size: 8)) }
                                .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Theme.accentSoft, in: Capsule()).foregroundStyle(Theme.accent)
                    }
                }
            }
            MentionField(text: $ask, references: $askRefs,
                         placeholder: "Describe a symptom, ask about a result, or @-reference…",
                         onSend: submit)
            Text("Research tool grounded in sources — not medical advice, and it can be wrong.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
    }

    private func submit() {
        let text = ask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let refs = askRefs
        ask = ""; askRefs = []
        // Plain symptom text (no @-references) opens a persisted Complaint + history interview;
        // questions / references go to chat.
        if refs.isEmpty, app.looksLikeSymptom(text) {
            app.beginComplaint(text)
        } else {
            app.startNewChat()
            app.beginSendChat(text, references: refs)
        }
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

    private var openComplaints: [Complaint] { app.complaints.filter { $0.status != "resolved" } }
    private var concernsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Your concerns")
            ForEach(openComplaints) { ComplaintCard(complaint: $0) }
        }
    }

    private var nextSteps: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "Next steps")
                if questionCount > 0 {
                    Text("\(questionCount) to answer")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.accentSoft, in: Capsule()).foregroundStyle(Theme.accent)
                }
                Spacer()
                if app.identifyingNextSteps {
                    IdentifyingIndicator()
                } else if !app.documents.isEmpty {
                    Button { app.beginHypotheses() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                        .help("Refresh next steps")
                        .disabled(app.isStreaming)
                }
            }

            if activeHypotheses.isEmpty {
                if app.identifyingNextSteps {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Working through your records…").font(.callout).foregroundStyle(.secondary) }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                } else {
                    emptyHypotheses
                }
            } else {
                ForEach(activeHypotheses) { HypothesisCard(hyp: $0) }
            }
        }
    }

    private var archivedSet: Set<String> { ["superseded", "done", "dismissed"] }
    private var activeHypotheses: [Hypothesis] { app.hypotheses.filter { !archivedSet.contains($0.status) } }
    private var questionCount: Int { activeHypotheses.filter { $0.isQuestion && ($0.answer?.isEmpty ?? true) }.count }
    private var archivedHypotheses: [Hypothesis] { app.hypotheses.filter { archivedSet.contains($0.status) } }

    @State private var showArchived = false
    private var archivedSteps: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation { showArchived.toggle() } } label: {
                HStack {
                    SectionHeader(title: "Archived steps")
                    Text("\(archivedHypotheses.count)").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Image(systemName: showArchived ? "chevron.up" : "chevron.down")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())   // whole header row is the hit target
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
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
        ("camera.fill", "A photo of a symptom — skin, nail, swelling"),
    ]
    private var emptyHypotheses: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: app.documents.isEmpty ? "tray.and.arrow.down.fill" : "checkmark.seal.fill")
                    .foregroundStyle(app.documents.isEmpty ? Theme.accent : .green)
                Text(app.documents.isEmpty ? "Let's get started" : "You're all caught up")
                    .font(.callout.weight(.semibold))
            }
            Text(app.documents.isEmpty
                 ? "Add a health record and Rounds will read it on your Mac, file it, and propose the right next steps — nothing leaves your computer."
                 : "No open next steps right now — that's a good place to be. Add more records and Rounds will find what's worth doing next.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 5) {
                Text("Helpful things to add").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                ForEach(suggestedDocs, id: \.1) { icon, label in
                    HStack(spacing: 7) {
                        Image(systemName: icon).font(.caption2).foregroundStyle(Theme.accent).frame(width: 16)
                        Text(label).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))

            Text(app.documents.isEmpty
                 ? "Drag any of these onto the window — or describe a symptom in the box above."
                 : "Drag a new record onto the window, or ask a question above.")
                .font(.caption2).foregroundStyle(.tertiary)
            if !app.documents.isEmpty {
                Button { app.beginHypotheses() } label: { Label("Find next steps now", systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
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
                                Text("working…").font(.caption2).foregroundStyle(Theme.accent)
                            }
                        } else {
                            Text(chat.updatedAt, style: .relative).font(.caption2).foregroundStyle(.tertiary)
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
                Text(alert.message).font(.callout.weight(.semibold)).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                if let m = alert.marker {
                    Text(m + (alert.value.map { ": \($0)" } ?? "") + (alert.basis.map { " · \($0)" } ?? ""))
                        .font(.caption2).foregroundStyle(.white.opacity(0.85))
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

/// A symptom-first encounter card. Its interview questions + next steps render below in Next steps
/// (linked by complaintId); this card is the persistent anchor with status + resolve/delete.
struct ComplaintCard: View {
    @Environment(AppState.self) private var app
    let complaint: Complaint
    private var linked: [Hypothesis] {
        app.hypotheses.filter { $0.complaintId == complaint.id && !["superseded", "dismissed"].contains($0.status) }
    }
    private var openQuestions: Int { linked.filter { $0.isQuestion && ($0.answer?.isEmpty ?? true) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "stethoscope").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(complaint.title).font(.headline).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    statusLine
                }
                Spacer()
                Menu {
                    Button("Mark resolved") { app.resolveComplaint(complaint) }
                    Button("Delete", role: .destructive) { app.deleteComplaint(complaint) }
                } label: { Image(systemName: "ellipsis.circle").foregroundStyle(.secondary) }
                    .menuStyle(.borderlessButton).fixedSize()
            }
        }
        .padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
    }

    @ViewBuilder private var statusLine: some View {
        if openQuestions > 0 {
            Text("\(openQuestions) quick question\(openQuestions > 1 ? "s" : "") to answer below in Next steps")
                .font(.caption).foregroundStyle(Theme.accent)
        } else if app.identifyingNextSteps {
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Thinking it through…").font(.caption).foregroundStyle(.secondary) }
        } else if linked.isEmpty {
            Text("Reviewing your concern…").font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Your next steps for this are below.").font(.caption).foregroundStyle(.secondary)
        }
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
                    .font(.caption.weight(.medium)).foregroundStyle(Theme.accent).lineLimit(1)
                    .underline(hovering)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
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
                    Label(person, systemImage: "person").font(.caption2).foregroundStyle(Theme.accent)
                }
                HStack(spacing: 5) {
                    Image(systemName: "bubble.left.and.text.bubble.right").font(.caption2)
                    Text("A quick question").font(.caption2.weight(.semibold))
                }
                .foregroundStyle(Theme.accent)
                Text(hyp.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                if !hyp.whyNow.isEmpty {
                    Text(hyp.whyNow).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if app.answeringStep == hyp.id {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Recording your answer and updating your next steps…").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                TextField(hyp.askPlaceholder ?? "Your answer — a sentence or two is plenty", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...5)
                    .padding(10)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
                HStack {
                    Button("Chat about this instead") { app.chatAbout(hyp) }
                        .font(.caption).buttonStyle(.borderless).tint(Theme.accent)
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
                Image(systemName: "checkmark.bubble").font(.caption2)
                Text("Answered" + (hyp.answeredAt.map { " · \($0)" } ?? "")).font(.caption2)
                Spacer()
            }
            .foregroundStyle(.tertiary)
            Text(hyp.title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let a = hyp.answer, !a.isEmpty {
                Text(a).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var actionBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    if let person = personLabel {
                        Label(person, systemImage: "person")
                            .font(.caption2).foregroundStyle(Theme.accent)
                    }
                    Text(hyp.title).font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(hyp.whyNow).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { expanded.toggle() } }
                Spacer()
                Pill(text: hyp.priority, color: priorityColor)
            }
            HStack(spacing: 8) {
                Pill(text: hyp.kind.replacingOccurrences(of: "-", with: " "))
                if let tier = hyp.topTier { TierBadge(tier: tier) }
                if hyp.sourceCount > 0 {
                    Label("\(hyp.sourceCount) sources", systemImage: "doc.text.magnifyingglass")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button(expanded ? "Hide" : "Details") { withAnimation { expanded.toggle() } }
                    .font(.caption).buttonStyle(.borderless)
                Button("Chat about this") { app.chatAbout(hyp) }
                    .font(.caption.weight(.medium)).buttonStyle(.borderless).tint(Theme.accent)
            }
            if expanded {
                if let body = hyp.body {
                    Divider()
                    MarkdownText(stripFrontMatter(body)).font(.callout)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Questions? Need clarification? Any ideas?")
                        .font(.callout.weight(.medium))
                    Text("Talk it through with Rounds — refine this step, ask what a result would mean, or decide it's already handled.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { app.chatAbout(hyp) } label: {
                        Label("Chat about this", systemImage: "bubble.left.and.text.bubble.right")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
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
