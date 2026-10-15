//
//  PlanSection.swift
//  rounds
//
//  Home's plan: each person's PROBLEM LIST — the problems Rounds found in their records, and under
//  each problem the next steps that address it (actions + history questions answered inline). This
//  replaces the old flat pile of next-step cards: steps are grouped by the problem they serve, so the
//  plan reads as one coherent thing. Every change is made either deterministically here (done /
//  not relevant / answer) or by an ordinary chat following the shared rules in the vault CLAUDE.md.
//

import SwiftUI
import AppKit

/// The plan block on Home. Its body is a flat list of rows (person headers, problem cards, …) so the
/// surrounding LazyVStack realizes one problem card at a time.
struct PlanSection: View {
    @Environment(AppState.self) private var app
    @Binding var filter: String

    private enum Row: Identifiable {
        case person(String)
        case problem(Problem)
        case legacy(String, [Hypothesis])
        case closed(String, [Problem])
        var id: String {
            switch self {
            case .person(let s): "person:" + s
            case .problem(let p): "problem:" + p.personId + ":" + p.id
            case .legacy(let s, _): "legacy:" + s
            case .closed(let s, _): "closed:" + s
            }
        }
    }

    /// People that have anything to show (a list, legacy cards, or a review running), in display order:
    /// whoever has a high-priority open problem first, then the most recently updated plan, `You` on ties.
    private var planPeople: [String] {
        var slugs = Set(app.problemLists.filter { !$0.problems.isEmpty }.map(\.personId))
        for p in app.people where !app.legacyOpenSteps(p.slug).isEmpty || app.isPersonBusy(p.slug) { slugs.insert(p.slug) }
        if !filter.isEmpty { slugs = slugs.filter { $0 == filter } }
        func hot(_ s: String) -> Bool { app.problemList(s)?.problems.contains { $0.status == "active" && $0.priority == "high" } ?? false }
        func latest(_ s: String) -> String { app.problemList(s)?.problems.compactMap(\.updatedAt).max() ?? "" }
        return slugs.sorted { a, b in
            if hot(a) != hot(b) { return hot(a) }
            if latest(a) != latest(b) { return latest(a) > latest(b) }
            if (a == "_self") != (b == "_self") { return a == "_self" }
            return a < b
        }
    }

    private var rows: [Row] {
        let people = planPeople
        let showHeaders = people.count > 1 || !filter.isEmpty || people.first.map { $0 != "_self" } ?? false
        var out: [Row] = []
        for slug in people {
            if showHeaders { out.append(.person(slug)) }
            let probs = app.problemList(slug)?.problems ?? []
            let open = probs.filter(\.isOpen).sorted { rank($0) < rank($1) }
            out += open.map { .problem($0) }
            let legacy = app.legacyOpenSteps(slug)
            if !legacy.isEmpty { out.append(.legacy(slug, legacy)) }
            let closed = probs.filter { !$0.isOpen }
            if !closed.isEmpty { out.append(.closed(slug, closed)) }
        }
        return out
    }

    private func rank(_ p: Problem) -> Int {
        let s = p.status == "active" ? 0 : 3
        let pr = ["high": 0, "medium": 1, "low": 2][p.priority] ?? 1
        return s + pr
    }

    private var questionCount: Int {
        app.problems.filter(\.isOpen).reduce(0) { $0 + $1.unansweredQuestions }
            + app.people.flatMap { app.legacyOpenSteps($0.slug) }.filter { $0.isQuestion && !$0.isAnswered }.count
    }

    var body: some View {
        let rows = rows
        PlanHeader(filter: $filter, questionCount: questionCount, singlePerson: planPeople.count == 1 ? planPeople.first : nil)
            .padding(.bottom, 12)
        if let mid = app.migrationChatId, app.isChatStreaming(mid) {
            BusyLine(text: "Organizing your next steps into problems…", chatId: mid).padding(.bottom, 12)
        }
        if rows.isEmpty {
            EmptyPlan().padding(.bottom, 8)
        }
        ForEach(rows) { row in
            switch row {
            case .person(let slug): PersonPlanHeader(slug: slug).padding(.top, 10).padding(.bottom, 8)
            case .problem(let p): ProblemCard(problem: p).padding(.bottom, 12)
            case .legacy(let slug, let steps): LegacySteps(slug: slug, steps: steps).padding(.bottom, 12)
            case .closed(let slug, let probs): ClosedProblems(slug: slug, problems: probs).padding(.bottom, 12)
            }
        }
    }
}

// MARK: - headers

private struct PlanHeader: View {
    @Environment(AppState.self) private var app
    @Binding var filter: String
    let questionCount: Int
    let singlePerson: String?

    var body: some View {
        HStack(spacing: 8) {
            SectionHeader(title: "Problems & next steps")
            if questionCount > 0 {
                Text("\(questionCount) to answer")
                    .zfont(.caption2, .medium)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Theme.accentSoft, in: Capsule()).foregroundStyle(Theme.accent)
            }
            Spacer()
            if app.people.count > 1 {
                Menu {
                    Button { filter = "" } label: { Label("Everyone", systemImage: filter.isEmpty ? "checkmark" : "") }
                    Divider()
                    ForEach(app.people) { p in
                        Button { filter = p.slug } label: {
                            Label(p.slug == "_self" ? "You" : p.displayName, systemImage: filter == p.slug ? "checkmark" : "")
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "person.crop.circle").zfont(.caption2)
                        Text(filter.isEmpty ? "Everyone" : (app.people.first { $0.slug == filter }.map { $0.slug == "_self" ? "You" : $0.displayName } ?? "Everyone"))
                            .zfont(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            // With one person on screen there are no group headers — their review control lives here.
            if let slug = singlePerson { ReviewControl(slug: slug) }
        }
    }
}

private struct PersonPlanHeader: View {
    @Environment(AppState.self) private var app
    let slug: String

    var body: some View {
        let p = app.people.first { $0.slug == slug }
        let name = slug == "_self" ? "You" : (p?.displayName ?? slug)
        let rel = (p?.relationship).flatMap { $0 == "self" ? nil : $0 }
        let open = app.problemList(slug)?.problems.filter(\.isOpen).count ?? 0
        HStack(spacing: 6) {
            Text(name).zfont(.callout, .semibold)
            if let rel { Text(rel).zfont(.caption).foregroundStyle(.tertiary) }
            if open > 0 { Text("\(open)").zfont(.caption2).foregroundStyle(.tertiary) }
            Spacer()
            ReviewControl(slug: slug)
        }
    }
}

/// "Review" (start a background review chat for this person) — or, while one runs, a live link to it.
private struct ReviewControl: View {
    @Environment(AppState.self) private var app
    let slug: String

    var body: some View {
        if app.isPersonBusy(slug), let chat = app.migratingPeople.contains(slug) ? app.migrationChatId : app.busyPeople[slug] {
            BusyLine(text: app.migratingPeople.contains(slug) ? "Organizing…" : "Updating the plan…", chatId: chat)
        } else if !app.documents.filter({ $0.personId == slug }).isEmpty || app.problemList(slug) != nil {
            Button { app.reviewPerson(slug) } label: { Label("Review", systemImage: "arrow.clockwise") }
                .buttonStyle(.borderless).zfont(.caption).foregroundStyle(.secondary)
                .help("Re-read the records and bring this plan up to date (runs as a chat you can open)")
        }
    }
}

/// A spinner + label that opens the chat doing the work.
private struct BusyLine: View {
    @Environment(AppState.self) private var app
    let text: String
    let chatId: String
    @State private var hovering = false

    var body: some View {
        Button { app.selectTab(.chat(chatId)) } label: {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(text).zfont(.caption, .medium).foregroundStyle(Theme.accent).lineLimit(1).underline(hovering)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).linkCursor()
        .onHover { hovering = $0 }
        .help("Open the chat that's doing this")
    }
}

// MARK: - problem card

struct ProblemCard: View {
    @Environment(AppState.self) private var app
    let problem: Problem
    @State private var showSummary = false
    @State private var showClosed = false

    private var tint: Color {
        if problem.status == "watching" { return .secondary }
        switch problem.priority { case "high": return Theme.warn; case "low": return .secondary; default: return Theme.accent }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Circle().fill(tint).frame(width: 8, height: 8).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                VStack(alignment: .leading, spacing: 2) {
                    Text(problem.title).zfont(.headline)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if problem.status == "watching" {
                        Text("Watching — nothing to do right now").zfont(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 6)
                if problem.status == "active", problem.priority == "high" { Pill(text: "high", color: Theme.warn) }
                problemMenu
            }

            if !problem.summary.isEmpty {
                Text(MarkdownText.cachedAttributed(problem.summary))
                    .zfont(.callout).foregroundStyle(.secondary)
                    .lineLimit(showSummary ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { showSummary.toggle() } }
            }

            if !problem.openSteps.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(problem.openSteps.enumerated()), id: \.element.id) { i, step in
                        if i > 0 { Divider().padding(.leading, 30) }
                        StepRow(step: step)
                    }
                }
                .background(Theme.bg.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairline))
            } else if problem.status == "active" {
                Text("No open steps — Rounds will add the next move when there's something to do.")
                    .zfont(.caption).foregroundStyle(.tertiary)
            }

            if showClosed, !problem.closedSteps.isEmpty {
                VStack(spacing: 0) {
                    ForEach(problem.closedSteps) { StepRow(step: $0) }
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: 14) {
                Button { app.chatAboutProblem(problem) } label: {
                    Label("Chat about this", systemImage: "bubble.left.and.text.bubble.right")
                }
                .buttonStyle(.borderless).zfont(.caption, .medium).tint(Theme.accent)
                if !problem.sources.isEmpty { SourcesChip(sources: problem.sources) }
                Spacer()
                if !problem.closedSteps.isEmpty {
                    Button(showClosed ? "Hide done" : "\(problem.closedSteps.count) done") {
                        withAnimation(.easeInOut(duration: 0.15)) { showClosed.toggle() }
                    }
                    .buttonStyle(.borderless).zfont(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
        .contextMenu { menuItems }
    }

    private var problemMenu: some View {
        Menu { menuItems } label: {
            Image(systemName: "ellipsis").zfont(.callout).foregroundStyle(.secondary).frame(width: 22, height: 16)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    @ViewBuilder private var menuItems: some View {
        Button("Chat about this problem") { app.chatAboutProblem(problem) }
        Divider()
        if problem.status != "watching" { Button("Just watch it") { app.setProblemStatus(problem, "watching") } }
        if problem.status != "active" { Button("Make it active") { app.setProblemStatus(problem, "active") } }
        Button("Mark as resolved") { app.setProblemStatus(problem, "resolved") }
        Button("Ruled out") { app.setProblemStatus(problem, "ruled-out") }
    }
}

// MARK: - step row

struct StepRow: View {
    @Environment(AppState.self) private var app
    let step: Hypothesis
    @State private var expanded = false
    @State private var draft = ""
    @State private var hovering = false

    private var closed: Bool { !step.isOpenStep }

    var body: some View {
        Group {
            if step.isQuestion && !step.isAnswered && !closed { question }
            else { action }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Chat about this step") { app.chatAbout(step) }
            Divider()
            if closed {
                Button("Reopen") { app.setStepStatus(step, "open") }
            } else {
                if !step.isQuestion { Button("Mark done") { app.setStepStatus(step, "done") } }
                Button("Not relevant") { app.setStepStatus(step, "dismissed") }
            }
        }
    }

    // A history question: answer inline.
    private var question: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right").zfont(.callout).foregroundStyle(Theme.accent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 6) {
                Text(step.title).zfont(.subheadline, .medium)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if !step.whyNow.isEmpty {
                    Text(MarkdownText.cachedAttributed(step.whyNow)).zfont(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if app.answeringStep == step.id {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Saving your answer…").zfont(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    HStack(alignment: .bottom, spacing: 8) {
                        TextField(step.askPlaceholder?.isEmpty == false ? step.askPlaceholder! : "Your answer — a sentence or two is plenty",
                                  text: $draft, axis: .vertical)
                            .textFieldStyle(.plain).lineLimit(1...5).zfont(.callout)
                            .padding(8)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
                            .onSubmit(submit)
                        Button(action: submit) { Image(systemName: "arrow.up.circle.fill").zfont(.title3) }
                            .buttonStyle(.borderless).foregroundStyle(draft.isEmpty ? Color.secondary : Theme.accent)
                            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                            .help("Send your answer — Rounds records it and updates the plan")
                    }
                }
            }
        }
    }

    private func submit() {
        let a = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return }
        draft = ""
        Task { await app.answerStep(step, answer: a) }
    }

    private var action: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                guard !step.isQuestion else { return }
                app.setStepStatus(step, closed ? "open" : "done")
            } label: {
                Image(systemName: closed ? statusIcon : (hovering && !step.isQuestion ? "checkmark.circle" : "circle"))
                    .zfont(.body).foregroundStyle(closed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Theme.accent))
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .help(closed ? "Reopen" : (step.isQuestion ? "" : "Mark done"))
            .onHover { hovering = $0 }

            VStack(alignment: .leading, spacing: 5) {
                Text(step.title).zfont(.subheadline, closed ? .regular : .medium)
                    .foregroundStyle(closed ? .secondary : .primary)
                    .strikethrough(step.status == "done" && !step.isQuestion, color: .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
                if step.isQuestion, let a = step.answer, !a.isEmpty {
                    Text("Your answer: " + a).zfont(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Text(Self.kindLabel(step.kind)).zfont(.caption2).foregroundStyle(.tertiary)
                    if closed { Text(Self.statusLabel(step.status)).zfont(.caption2).foregroundStyle(.tertiary) }
                    if step.priority == "high", !closed { Text("high").zfont(.caption2, .medium).foregroundStyle(Theme.warn) }
                    if !step.sources.isEmpty { SourcesChip(sources: step.sources) }
                    Spacer()
                    if !closed {
                        Button(expanded ? "Hide" : "Details") { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
                            .buttonStyle(.borderless).zfont(.caption2).foregroundStyle(.secondary)
                    }
                }
                if expanded { details }
            }
        }
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !step.whyNow.isEmpty {
                Text(MarkdownText.cachedAttributed(step.whyNow)).zfont(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let body = step.body, !body.isEmpty {
                let clean = Self.stripFrontMatter(body)
                if MarkdownText.cachedHasTable(clean) {
                    MarkdownText(clean).zfont(.callout)
                } else {
                    Text(MarkdownText.cachedAttributed(clean)).zfont(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack(spacing: 10) {
                Button { app.chatAbout(step) } label: { Label("Chat about this step", systemImage: "bubble.left") }
                    .buttonStyle(.bordered).controlSize(.small).tint(Theme.accent)
                if !step.isQuestion {
                    Button { app.setStepStatus(step, "done") } label: { Label("Done", systemImage: "checkmark") }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                Button { app.setStepStatus(step, "dismissed") } label: { Text("Not relevant") }
                    .buttonStyle(.borderless).controlSize(.small).foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
        .padding(.top, 4)
    }

    private var statusIcon: String {
        switch step.status {
        case "done": "checkmark.circle.fill"
        case "superseded": "arrow.triangle.2.circlepath"
        case "snoozed": "moon.zzz"
        default: "minus.circle"
        }
    }

    static func kindLabel(_ k: String) -> String {
        switch k {
        case "get-more-data": "Get data"
        case "try-something": "Try"
        case "see-specialist": "Specialist"
        case "watch": "Watch"
        case "ask-user": "Question"
        case "needs-exam": "Exam"
        default: k.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    static func statusLabel(_ s: String) -> String {
        switch s {
        case "done": "Done"
        case "dismissed": "Not relevant"
        case "superseded": "Replaced"
        case "snoozed": "Snoozed"
        case "resolved": "Resolved"
        case "ruled-out": "Ruled out"
        case "watching": "Watching"
        case "active", "open": "Reopened"
        default: s.capitalized
        }
    }

    static func stripFrontMatter(_ md: String) -> String {
        guard md.hasPrefix("---") else { return md }
        let parts = md.components(separatedBy: "---")
        return parts.count >= 3 ? parts[2...].joined(separator: "---").trimmingCharacters(in: .whitespacesAndNewlines) : md
    }
}

/// "N sources" — click for a popover of clickable source cards.
struct SourcesChip: View {
    let sources: [Source]
    @State private var show = false
    @State private var hovering = false

    var body: some View {
        Button { show.toggle() } label: {
            Label("\(sources.count) source\(sources.count == 1 ? "" : "s")", systemImage: "doc.text.magnifyingglass")
                .zfont(.caption2).foregroundStyle(.secondary).underline(hovering)
        }
        .buttonStyle(.plain).linkCursor()
        .onHover { hovering = $0 }
        .popover(isPresented: $show, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sources").zfont(.caption, .semibold).foregroundStyle(.secondary)
                ForEach(sources) { MiniSourceCard(source: $0) }
            }
            .padding(12).frame(width: 330)
        }
    }
}

// MARK: - legacy, closed, empty

/// Flat next-step cards from before problem lists, shown until the one-time reorganization finishes.
private struct LegacySteps: View {
    @Environment(AppState.self) private var app
    let slug: String
    let steps: [Hypothesis]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "tray.full").zfont(.caption).foregroundStyle(.secondary)
                Text("Not organized into problems yet").zfont(.caption, .semibold).foregroundStyle(.secondary)
                Text("\(steps.count)").zfont(.caption2).foregroundStyle(.tertiary)
                Spacer()
                // While it's being organized, the person header already shows "Organizing…".
                if !app.migratingPeople.contains(slug) {
                    Button("Organize now") { app.migrateLegacyIfNeeded(force: true) }
                        .buttonStyle(.borderless).zfont(.caption).tint(Theme.accent)
                }
            }
            ForEach(steps) { HypothesisCard(hyp: $0) }
        }
    }
}

private struct ClosedProblems: View {
    let slug: String
    let problems: [Problem]
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").zfont(.caption2).foregroundStyle(.secondary)
                    Text("Resolved & ruled out").zfont(.caption, .medium).foregroundStyle(.secondary)
                    Text("\(problems.count)").zfont(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).linkCursor()
            if open {
                ForEach(problems) { ProblemCard(problem: $0).opacity(0.75) }
            }
        }
    }
}

private struct EmptyPlan: View {
    @Environment(AppState.self) private var app

    private let suggestedDocs = [
        ("drop.fill", "A recent blood test or lab panel"),
        ("waveform.path.ecg", "An imaging report — ultrasound, CT, MRI, X-ray"),
        ("doc.text", "A specialist's note or discharge summary"),
        ("camera.fill", "A photo of skin, a nail, or swelling"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: app.documents.isEmpty ? "tray.and.arrow.down.fill" : "checkmark.seal.fill")
                    .foregroundStyle(app.documents.isEmpty ? Theme.accent : .green)
                Text(app.documents.isEmpty ? "Let's get started" : "Nothing open right now")
                    .zfont(.callout, .semibold)
            }
            Text(app.documents.isEmpty
                 ? "Add a health record and Rounds will read it on your Mac, file it, and build a plan: the problems it finds and the right next steps for each."
                 : "No open problems — a good place to be. Add more records, or ask Rounds to review what's there.")
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

            if !app.documents.isEmpty {
                Button { app.reviewEveryone() } label: { Label("Review my records", systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - in chat: "the plan changed"

/// Under an assistant message: what this turn changed in the plan (from its `problems_update` calls).
struct PlanChangesCard: View {
    @Environment(AppState.self) private var app
    let changes: [PlanChange]
    @State private var hovering = false

    var body: some View {
        Button { app.selectHome() } label: {
            VStack(alignment: .leading, spacing: 5) {
                Label("Plan updated", systemImage: "checklist").zfont(.caption, .semibold).foregroundStyle(Theme.accent)
                ForEach(Self.dedup(changes), id: \.stableId) { c in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: Self.icon(c)).zfont(.caption2).foregroundStyle(.secondary).frame(width: 12)
                        Text(Self.verb(c)).zfont(.caption).foregroundStyle(.secondary)
                        Text(c.title.isEmpty ? "—" : c.title).zfont(.caption).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).linkCursor()
        .background(Theme.accentSoft.opacity(hovering ? 0.8 : 0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.25)))
        .onHover { hovering = $0 }
        .help("Open Home to see the plan")
    }

    /// One line per item (the last thing that happened to it wins).
    static func dedup(_ cs: [PlanChange]) -> [PlanChange] {
        var seen: [String: Int] = [:]
        var out: [PlanChange] = []
        for c in cs {
            let key = c.person + "|" + c.id
            if let i = seen[key] {
                // Keep "added" as the verb if it was created this turn, but take the newest status/title.
                var merged = c
                if out[i].op.hasPrefix("add_") && c.op.hasPrefix("update_") { merged.op = out[i].op }
                if merged.title.isEmpty { merged.title = out[i].title }
                out[i] = merged
            } else { seen[key] = out.count; out.append(c) }
        }
        return out
    }

    static func icon(_ c: PlanChange) -> String {
        switch c.op {
        case "add_problem", "add_step": "plus"
        case "answered": "checkmark.bubble"
        case "merge": "arrow.triangle.merge"
        case "move_step": "arrow.turn.down.right"
        case "step_status", "problem_status":
            ["done", "resolved"].contains(c.status ?? "") ? "checkmark" : "arrow.triangle.2.circlepath"
        default: "pencil"
        }
    }

    static func verb(_ c: PlanChange) -> String {
        switch c.op {
        case "add_problem": "New problem"
        case "update_problem": "Updated"
        case "add_step": "New step"
        case "update_step": "Updated step"
        case "answered": "Answered"
        case "merge": "Merged into"
        case "move_step": "Moved"
        case "step_status", "problem_status": StepRow.statusLabel(c.status ?? "")
        default: "Changed"
        }
    }
}
