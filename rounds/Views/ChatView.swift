//
//  ChatView.swift
//  rounds
//
//  No-bubble chat. Assistant prose streams in left-aligned; the user's lines are
//  right-aligned. An urgent-attention banner can override the calm framing. The input
//  supports @-mentioning a filed document.
//

import SwiftUI
import AppKit
import CoreImage

struct ChatView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        // One screen per chat (keyed by id): switching chats builds a fresh screen instead of diffing
        // one chat's transcript into another's, and every subview observes ONLY the runtime it shows.
        if let id = app.activeChatTab, let rt = app.chatRuntimes[id] {
            ChatScreen(rt: rt).id(rt.id)
        } else {
            Theme.bg
        }
    }
}

/// The open chat. Split into small views that each observe just what they draw, so a streaming
/// token re-renders the live answer — not the whole transcript, the header and the input bar.
private struct ChatScreen: View {
    let rt: ChatRuntime

    var body: some View {
        VStack(spacing: 0) {
            ChatHeader(rt: rt)
            if rt.remoteControlOn { RemoteBar(rt: rt) }
            Divider()
            ChatTranscript(rt: rt)
            ChatInputBar(rt: rt)
        }
        .background(Theme.bg)
    }
}

private struct ChatHeader: View {
    @Environment(AppState.self) private var app
    let rt: ChatRuntime

    var body: some View {
        HStack {
            Button { app.selectHome() } label: {
                Label("Home", systemImage: "chevron.left")
            }.buttonStyle(.borderless)
            Spacer()
            if rt.isStreaming {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    if !rt.statusLine.isEmpty {
                        Text(rt.statusLine).zfont(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Button { rt.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(.borderless).zfont(.caption).tint(Theme.warn)
                }
            }
            Spacer()
            Button { rt.setRemoteControl(!rt.remoteControlOn) } label: {
                Label(rt.remoteControlOn ? "On your phone" : "Remote control",
                      systemImage: rt.remoteControlOn ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .zfont(.caption)
            }
            .buttonStyle(.borderless)
            .tint(rt.remoteControlOn ? Theme.accent : .secondary)
            .help("Continue this chat on your phone. Turns it into a Claude Code Remote Control session — open the link / scan the QR on your phone, or find it in the Claude app.")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

/// Shown when remote control is on: the pairing URL + a QR to scan with a phone. Messages typed
/// on the phone appear in this same transcript; you can keep typing here too.
private struct RemoteBar: View {
    @Environment(AppState.self) private var app
    let rt: ChatRuntime

    var body: some View {
        HStack(spacing: 12) {
            if let url = rt.remoteSessionURL, let qr = ChatView.qrImage(url) {
                Image(nsImage: qr).interpolation(.none).resizable().frame(width: 54, height: 54)
                    .background(.white).cornerRadius(4)
            } else {
                ProgressView().controlSize(.small).frame(width: 54, height: 54)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Remote control on — open this chat on your phone").zfont(.caption, .medium)
                if let url = rt.remoteSessionURL {
                    Text(url).zfont(.caption2).foregroundStyle(Theme.accent).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 12) {
                        Button { NSWorkspace.shared.open(URL(string: url)!) } label: { Text("Open here") }
                        Button {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string)
                            app.toast = "Link copied"
                        } label: { Text("Copy link") }
                    }
                    .buttonStyle(.borderless).zfont(.caption2)
                } else {
                    Text("Connecting to the relay…").zfont(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.accentSoft)
    }
}

extension ChatView {
    static func qrImage(_ string: String) -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: ci)
        let img = NSImage(size: rep.size); img.addRepresentation(rep); return img
    }
}

private struct ChatInputBar: View {
    @Environment(AppState.self) private var app
    let rt: ChatRuntime

    // The unsent draft + @-references live on the per-chat ChatRuntime (not local @State), so they
    // survive leaving the tab and coming back, and stay distinct per chat.
    private var draft: Binding<String> { Binding(get: { rt.draft }, set: { rt.draft = $0 }) }
    private var refs: Binding<[Reference]> { Binding(get: { rt.draftReferences }, set: { rt.draftReferences = $0 }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !rt.draftReferences.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(rt.draftReferences) { ref in
                            RefAttachment(ref: ref, compact: true) { rt.draftReferences.removeAll { $0 == ref } }
                        }
                    }
                    .padding(.top, 6).padding(.trailing, 6)
                }
            }
            if !rt.queued.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Queued — sends after this reply").zfont(.caption2).foregroundStyle(.secondary)
                    ForEach(rt.queued) { q in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "clock").zfont(.caption2).foregroundStyle(.secondary)
                            Text(q.text).zfont(.caption).foregroundStyle(.secondary).lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button { rt.queued.removeAll { $0.id == q.id } } label: { Image(systemName: "xmark").zfont(size: 9) }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                                .help("Remove from queue")
                        }
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
                    }
                }
            }
            MentionField(text: draft, references: refs,
                         placeholder: "Ask a follow-up…  (type @ to reference a file, person, problem, or chat)",
                         onSend: send, autofocus: true,
                         onRegisterTextView: { rt.inputTextView = $0 })
            HStack(spacing: 10) {
                InputControls()
                Divider().frame(height: 12)
                ResearchStagePicker(stage: Binding(get: { rt.researchStage }, set: { rt.researchStage = $0 }))
                Spacer()
                VoiceInputButton()
                attachMenu
            }
            .foregroundStyle(.primary)
        }
        .padding(12)
        .background(Theme.panel)
        .overlay(Divider(), alignment: .top)
    }

    private func send() {
        let text = rt.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }   // mid-stream is fine now — ChatRuntime queues it
        let refs = rt.draftReferences
        rt.draft = ""
        rt.draftReferences = []
        rt.send(text, references: refs)
    }

    // Paperclip: first choose the destination (this chat vs. Rounds' general filing), then pick files.
    private var attachMenu: some View {
        Menu {
            Button { pickAndAttach(toChat: true) } label: { Label("Add to this chat", systemImage: "bubble.left") }
            Button { pickAndAttach(toChat: false) } label: { Label("Add to Rounds (read & file)", systemImage: "tray.and.arrow.down") }
        } label: {
            Image(systemName: "paperclip").zfont(.body, .medium).foregroundStyle(.primary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Attach a document — to this chat, or to Rounds for filing")
    }

    private func pickAndAttach(toChat: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Attach"
        panel.message = toChat ? "Add document(s) to this chat" : "Add document(s) to Rounds"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        if toChat { app.attachFilesToChat(panel.urls, chatId: rt.id) }
        else { app.beginImport(panel.urls) }
    }
}

/// The scrolling transcript. Messages sit in a LazyVStack (only what's on screen is laid out — a
/// long chat no longer typesets every past answer on open), each row is Equatable so a parent
/// re-render skips unchanged rows, and the live turn is its own view so streaming tokens touch
/// nothing else.
private struct ChatTranscript: View {
    let rt: ChatRuntime
    @State private var atBottom = true   // only magnet-scroll when the user is already at the bottom

    var body: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let alert = rt.alert { AlertBanner(alert: alert) }
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(rt.messages) { msg in
                                MessageRow(message: msg, chatId: rt.id).equatable()
                            }
                        }
                        LiveTurn(rt: rt, proxy: proxy, follow: atBottom)
                        Color.clear.frame(height: 1).id("bottom")
                            .background(GeometryReader { b in
                                Color.clear.preference(key: AtBottomKey.self,
                                    value: b.frame(in: .global).maxY <= outer.frame(in: .global).maxY + 60)
                            })
                    }
                    .padding(20)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onPreferenceChange(AtBottomKey.self) { v in Task { @MainActor in if atBottom != v { atBottom = v } } }
                .onChange(of: rt.messages.count) { _, _ in if atBottom { withAnimation { proxy.scrollTo("bottom") } } }
                .onAppear { proxy.scrollTo("bottom") }
                .overlay(alignment: .bottomTrailing) {
                    if !atBottom {
                        Button {
                            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                            atBottom = true
                        } label: {
                            Image(systemName: "chevron.down")
                                .zfont(size: 13, weight: .semibold).foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(Theme.accent, in: Circle())
                                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 18).padding(.bottom, 12)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: atBottom)
            }
        }
    }
}

/// The in-flight turn: phase timeline / tool trace + the streaming answer. Observes only the live
/// fields, and keeps the view pinned to the bottom while the user is there (sticky-bottom only).
private struct LiveTurn: View {
    let rt: ChatRuntime
    let proxy: ScrollViewProxy
    let follow: Bool

    var body: some View {
        Group {
            if rt.isStreaming {
                VStack(alignment: .leading, spacing: 18) {
                    // A multi-step pipeline shows the green phase timeline; a plain turn keeps the
                    // simple tool trace. (Phases fall back to the trace until the first one lands.)
                    if !rt.phases.isEmpty {
                        PhaseTimeline(phases: rt.phases, live: true)
                    } else {
                        ResearchTrace(steps: rt.trace, statusLine: rt.statusLine, tokens: rt.liveTokens)
                    }
                    if !rt.liveText.isEmpty {
                        LiveAnswer(text: rt.liveText)
                    }
                }
            }
        }
        .onChange(of: rt.liveText) { _, _ in if follow { proxy.scrollTo("bottom") } }
    }
}

/// The streaming answer. Completed paragraphs are parsed once (cached); only the growing tail is
/// re-parsed per tick.
private struct LiveAnswer: View {
    @Environment(\.zoomScale) private var zoom
    let text: String

    var body: some View {
        let split = text.range(of: "\n\n", options: .backwards)
        let head = split.map { String(text[..<$0.lowerBound]) } ?? ""
        let tail = split.map { String(text[$0.upperBound...]) } ?? text
        var attr = head.isEmpty ? AttributedString("") : MarkdownText.cachedAttributed(head, scale: zoom)
        if !head.isEmpty { attr += AttributedString("\n\n") }
        attr += MarkdownText.fullAttributed(tail, scale: zoom)
        attr += AttributedString(" ▍")
        return Text(attr)
            .zfont(.body)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AtBottomKey: PreferenceKey {
    static var defaultValue: Bool = true
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = nextValue() }
}

struct MessageRow: View, Equatable {
    @Environment(AppState.self) private var app
    @Environment(\.zoomScale) private var zoom
    let message: ChatMessage
    var chatId: String? = nil

    static func == (l: MessageRow, r: MessageRow) -> Bool { l.message == r.message && l.chatId == r.chatId }

    var body: some View {
        switch message.role {
        case .user:
            HStack(alignment: .bottom, spacing: 4) {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 3) {
                    if !message.references.isEmpty {
                        VStack(alignment: .trailing, spacing: 5) {
                            ForEach(message.references) { ref in RefAttachment(ref: ref) }
                        }
                    }
                    if !message.text.isEmpty {
                        Text(message.text)
                            .zfont(.body)
                            .textSelection(.enabled)
                            .padding(.vertical, 8).padding(.horizontal, 12)
                            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
                    }
                    CopyButton(text: message.text)
                }
            }
        case .system:
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.secondary)
                Text(message.text).zfont(.callout).foregroundStyle(.secondary).italic()
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                // The pipeline that produced this turn, kept above the answer as a collapsed timeline.
                if !message.phases.isEmpty {
                    PhaseTimeline(phases: message.phases)
                }
                // Table-free messages render as ONE selectable Text so the user can drag-select
                // across paragraphs and copy. Table messages keep the grid renderer (per-block).
                // The parsed AttributedString is cached by content, so a re-render never re-parses.
                Group {
                    if MarkdownText.cachedHasTable(message.text) {
                        MarkdownText(message.text)
                    } else {
                        Text(MarkdownText.cachedAttributed(message.text, scale: zoom))
                            .zfont(.body)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                    .contextMenu {
                        Button("Explain in a new chat") {
                            app.explainInNewChat(message.text, fromChat: chatId)
                        }
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                        }
                    }
                if !message.planChanges.isEmpty {
                    PlanChangesCard(changes: message.planChanges).padding(.top, 2)
                }
                if !message.hypotheses.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(message.hypotheses.count == 1 ? "Added to your next steps" : "Added \(message.hypotheses.count) next steps",
                              systemImage: "checklist")
                            .zfont(.caption, .semibold).foregroundStyle(Theme.accent)
                        ForEach(message.hypotheses) { InlineStepCard(hyp: $0) }
                    }
                    .padding(.top, 2)
                }
                CopyButton(text: message.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A compact next-step card shown INLINE in chat when a conversation creates a step.
/// Clicking it jumps Home, where the full card lives in "Next steps".
struct InlineStepCard: View {
    @Environment(AppState.self) private var app
    let hyp: Hypothesis
    @State private var hovering = false

    var body: some View {
        Button { app.selectHome() } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: hyp.isQuestion ? "bubble.left.and.text.bubble.right" : "checklist")
                    .foregroundStyle(Theme.accent).zfont(.callout)
                VStack(alignment: .leading, spacing: 3) {
                    Text(hyp.title).zfont(.subheadline, .medium)
                        .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                    if !hyp.whyNow.isEmpty {
                        Text(hyp.whyNow).zfont(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                    }
                    HStack(spacing: 6) {
                        Pill(text: hyp.kind.replacingOccurrences(of: "-", with: " "))
                        if let t = hyp.topTier { TierBadge(tier: t) }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").zfont(.caption2).foregroundStyle(.tertiary)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkCursor()
        .background(Theme.accentSoft.opacity(hovering ? 0.8 : 0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.30)))
        .onHover { hovering = $0 }
    }
}

struct CopyButton: View {
    let text: String
    @State private var copied = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                .zfont(.caption2).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
    }
}

/// The green phase timeline for a multi-step pipeline (filing, next-steps, a long research turn).
/// A vertical green track with one labelled dot per phase: finished dots are solid green checks,
/// the active dot (live only) shows a spinner, and the tool calls that ran under a phase appear as
/// chips beneath its dot. Live above the streaming answer; persisted (collapsed) above a finished one.
struct PhaseTimeline: View {
    let phases: [PipelinePhase]
    var live: Bool = false
    @State private var expanded: Bool

    init(phases: [PipelinePhase], live: Bool = false) {
        self.phases = phases
        self.live = live
        _expanded = State(initialValue: live)   // live: open so the user watches it; finished: collapsed
    }

    /// The spinning dot: the last not-yet-done phase, but only while streaming.
    private var activeIndex: Int? { live ? phases.lastIndex(where: { !$0.done }) : nil }

    private var headerText: String {
        if !expanded, let a = activeIndex { return phases[a].label }
        if phases.count == 1 { return phases[0].label }   // e.g. a plain turn's "Used 4 tools"
        let n = phases.count
        return "\(n) step\(n == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 7) {
                    if activeIndex != nil { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "checkmark.seal.fill").zfont(.caption).foregroundStyle(Theme.accent) }
                    Text(headerText).zfont(.caption, .medium).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").zfont(.caption2).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(phases.enumerated()), id: \.element.id) { i, phase in
                        PhaseRow(phase: phase, isActive: i == activeIndex,
                                 isFirst: i == 0, isLast: i == phases.count - 1)
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct PhaseRow: View {
    let phase: PipelinePhase
    let isActive: Bool
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // The rail: a top connector (from the row top down to the dot), the dot, then a bottom
            // connector that fills the rest of the row so the green line stays continuous through
            // however tall the phase's content is.
            VStack(spacing: 0) {
                Rectangle().fill(isFirst ? Color.clear : Theme.accent).frame(width: 2, height: 5)
                dot
                Rectangle().fill(isLast ? Color.clear : Theme.accent).frame(width: 2).frame(maxHeight: .infinity)
            }
            .frame(width: 15)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(phase.label)
                        .zfont(.caption, isActive ? .semibold : .regular)
                        .foregroundStyle(isActive ? .primary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if isActive { ProgressView().controlSize(.mini) }
                }
                if !phase.steps.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(phase.steps.enumerated()), id: \.offset) { _, step in
                            Text(step).zfont(.caption2)
                                .foregroundStyle(step.hasSuffix(" — failed") ? AnyShapeStyle(Theme.danger) : AnyShapeStyle(.tertiary))
                                .lineLimit(1).help(step)
                        }
                    }
                }
            }
            .padding(.bottom, isLast ? 0 : 11)
        }
    }

    @ViewBuilder private var dot: some View {
        if phase.done {
            Image(systemName: "checkmark.circle.fill").zfont(size: 14).foregroundStyle(Theme.accent)
        } else {
            Circle().fill(Theme.bg).overlay(Circle().stroke(Theme.accent, lineWidth: 2)).frame(width: 13, height: 13)
        }
    }
}

/// A live "what the AI is doing" trace. Collapsed (default) shows just the current line;
/// expanded shows every step.
struct ResearchTrace: View {
    let steps: [String]
    let statusLine: String
    var tokens: Int = 0
    @State private var expanded = true

    private var current: String { statusLine.isEmpty ? (steps.last ?? "Working…") : statusLine }
    private var tokenLabel: String {
        guard tokens > 0 else { return "" }
        return tokens >= 1000 ? String(format: " · %.1fk tokens", Double(tokens) / 1000) : " · \(tokens) tokens"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation { expanded.toggle() } } label: {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text((expanded && !steps.isEmpty ? "Working · \(steps.count) step\(steps.count == 1 ? "" : "s")" : current) + tokenLabel)
                        .zfont(.caption, .medium).foregroundStyle(.secondary).lineLimit(1)
                        .monospacedDigit()
                    Spacer(minLength: 4)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").zfont(.caption2).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                // Long agentic runs can do dozens of calls — show the most recent ones, count the rest.
                let shown = 14, hidden = max(0, steps.count - shown)
                if hidden > 0 {
                    Text("+\(hidden) earlier step\(hidden == 1 ? "" : "s")").zfont(.caption2).foregroundStyle(.tertiary)
                }
                ForEach(Array(steps.enumerated()).suffix(shown), id: \.offset) { i, step in
                    HStack(spacing: 7) {
                        if i == steps.count - 1 {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "checkmark.circle.fill").zfont(.caption2).foregroundStyle(Theme.accent)
                        }
                        Text(step).zfont(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct AlertBanner: View {
    let alert: RoundsAlert
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 3) {
                Text("This may need urgent attention").zfont(.headline).foregroundStyle(.white)
                Text(alert.message).zfont(.callout).foregroundStyle(.white.opacity(0.95))
                if let m = alert.marker, let v = alert.value {
                    Text("\(m): \(v)" + (alert.basis.map { " · \($0)" } ?? ""))
                        .zfont(.caption).foregroundStyle(.white.opacity(0.85))
                }
            }
            Spacer()
        }
        .padding(14)
        .background(Theme.danger, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Block-based markdown renderer: paragraphs, bold/italics, bullet & numbered lists,
/// headings, and GitHub-style tables.
struct MarkdownText: View, Equatable {
    let raw: String
    init(_ raw: String) { self.raw = raw }
    static func == (l: MarkdownText, r: MarkdownText) -> Bool { l.raw == r.raw }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(MarkdownText.parse(raw).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .zfont(.body)   // base font for all inline body text, so ⌘+/⌘− scales the table-message renderer too
    }

    @ViewBuilder private func view(for block: MDBlock) -> some View {
        switch block {
        case .heading(let t):
            Text(t).zfont(.headline).fixedSize(horizontal: false, vertical: true)
        case .paragraph(let t):
            Text(MarkdownText.inline(t)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•").foregroundStyle(.secondary)
                        Text(MarkdownText.inline(it)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .ordered(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("\(i + 1).").foregroundStyle(.secondary).monospacedDigit()
                        Text(MarkdownText.inline(it)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, h in
                            Text(MarkdownText.inline(h)).zfont(.callout, .semibold)
                        }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(MarkdownText.inline(cell)).textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(10)
                .background(Theme.panel.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: parsing

    enum MDBlock { case heading(String), paragraph(String), bullets([String]), ordered([String]), table(header: [String], rows: [[String]]) }

    static func parse(_ raw: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        var para: [String] = []
        func flush() { if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] } }
        let lines = raw.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { flush(); i += 1; continue }
            if t.hasPrefix("#") { flush(); blocks.append(.heading(t.drop(while: { $0 == "#" || $0 == " " }).description)); i += 1; continue }
            if t.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flush()
                let header = splitRow(t)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(splitRow(lines[i])); i += 1
                }
                blocks.append(.table(header: header, rows: rows)); continue
            }
            if t.hasPrefix("- ") || t.hasPrefix("* ") {
                flush()
                var items: [String] = []
                while i < lines.count {
                    let lt = lines[i].trimmingCharacters(in: .whitespaces)
                    if lt.hasPrefix("- ") || lt.hasPrefix("* ") { items.append(String(lt.dropFirst(2))) }
                    else if lt.isEmpty { break }
                    else if !items.isEmpty { items[items.count - 1] += " " + lt }
                    i += 1
                }
                blocks.append(.bullets(items)); continue
            }
            if t.range(of: "^\\d+\\. ", options: .regularExpression) != nil {
                flush()
                var items: [String] = []
                while i < lines.count {
                    let lt = lines[i].trimmingCharacters(in: .whitespaces)
                    if let r = lt.range(of: "^\\d+\\. ", options: .regularExpression) { items.append(String(lt[r.upperBound...])) }
                    else if lt.isEmpty { break }
                    else if !items.isEmpty { items[items.count - 1] += " " + lt }
                    i += 1
                }
                blocks.append(.ordered(items)); continue
            }
            para.append(line); i += 1
        }
        flush()
        return blocks
    }

    /// Does the text contain a GitHub-style table? Such messages keep the grid renderer; everything
    /// else renders as a single selectable Text (so selection spans paragraphs).
    static func hasTable(_ raw: String) -> Bool {
        let lines = raw.components(separatedBy: "\n")
        for i in 0..<lines.count where lines[i].contains("|") {
            if i + 1 < lines.count, isTableSeparator(lines[i + 1]) { return true }
        }
        return false
    }

    /// The whole message as ONE AttributedString (paragraphs, headings, bullets, numbered lists,
    /// inline bold/italic, renumbered [S#]) — so a single SwiftUI Text can be drag-selected end-to-end.
    static func fullAttributed(_ raw: String, scale: CGFloat = 1) -> AttributedString {
        var out = AttributedString("")
        for (i, block) in parse(raw).enumerated() {
            if i > 0 { out += AttributedString("\n\n") }
            switch block {
            case .heading(let t):
                var a = inline(t)
                // Headings carry a baked font, so unlike the body runs they don't inherit the view's
                // scaled `.body`. Scale them here too; at scale 1 this matches the semantic .headline.
                a.font = scale == 1 ? .headline : .system(size: 13 * scale, weight: .semibold)
                out += a
            case .paragraph(let t):
                out += inline(t)
            case .bullets(let items):
                for (j, it) in items.enumerated() {
                    if j > 0 { out += AttributedString("\n") }
                    out += AttributedString("•  ") + inline(it)
                }
            case .ordered(let items):
                for (j, it) in items.enumerated() {
                    if j > 0 { out += AttributedString("\n") }
                    out += AttributedString("\(j + 1).  ") + inline(it)
                }
            case .table(let header, let rows):
                let lines = ([header] + rows).map { $0.joined(separator: "   |   ") }
                out += AttributedString(lines.joined(separator: "\n"))
            }
        }
        return out
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    private static func splitRow(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func inline(_ s: String) -> AttributedString {
        let renumbered = renumberCitations(s)
        return (try? AttributedString(markdown: renumbered, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(renumbered)
    }

    private static let citationRegex = try? NSRegularExpression(pattern: "\\[S(\\d+)\\]")

    static func renumberCitations(_ s: String) -> String {
        guard s.contains("[S"), let re = citationRegex else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "[$1]")
    }

    // MARK: render cache
    //
    // Parsing markdown into an AttributedString is the expensive part of drawing a message (and it
    // used to run for EVERY message on EVERY re-render). Results are cached by content + zoom so a
    // message is parsed once; the cache is bounded and simply resets when it grows too large.

    private struct CacheKey: Hashable { let text: String; let scale: CGFloat }
    @MainActor private static var attributedCache: [CacheKey: AttributedString] = [:]
    @MainActor private static var tableCache: [String: Bool] = [:]

    @MainActor static func cachedAttributed(_ raw: String, scale: CGFloat = 1) -> AttributedString {
        let key = CacheKey(text: raw, scale: scale)
        if let hit = attributedCache[key] { return hit }
        if attributedCache.count > 600 { attributedCache.removeAll(keepingCapacity: true) }
        let value = fullAttributed(raw, scale: scale)
        attributedCache[key] = value
        return value
    }

    @MainActor static func cachedHasTable(_ raw: String) -> Bool {
        if let hit = tableCache[raw] { return hit }
        if tableCache.count > 1200 { tableCache.removeAll(keepingCapacity: true) }
        let value = hasTable(raw)
        tableCache[raw] = value
        return value
    }
}
