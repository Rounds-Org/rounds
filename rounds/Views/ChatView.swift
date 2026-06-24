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
    @State private var atBottom = true   // only magnet-scroll when the user is already at the bottom

    // The unsent draft + @-references live on the per-chat ChatRuntime (not local @State), so they
    // survive leaving the tab and coming back, and stay distinct per chat.
    private func draftBinding(_ rt: ChatRuntime) -> Binding<String> {
        Binding(get: { rt.draft }, set: { rt.draft = $0 })
    }
    private func refsBinding(_ rt: ChatRuntime) -> Binding<[Reference]> {
        Binding(get: { rt.draftReferences }, set: { rt.draftReferences = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let rt = app.activeRuntime, rt.remoteControlOn { remoteBar(rt) }
            Divider()
            transcript
            inputBar
        }
        .background(Theme.bg)
        .onAppear(perform: pickupPending)
        .onChange(of: app.activeChatId) { _, _ in pickupPending() }
    }

    private func pickupPending() {
        guard let rt = app.activeRuntime else { return }
        if !app.pendingChatDraft.isEmpty || !app.pendingReferences.isEmpty {
            rt.draft = app.pendingChatDraft
            rt.draftReferences = app.pendingReferences
            app.pendingChatDraft = ""
            app.pendingReferences = []
        }
    }

    @ViewBuilder private var inputBar: some View {
        if let rt = app.activeRuntime {
            VStack(alignment: .leading, spacing: 6) {
                if !rt.draftReferences.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(rt.draftReferences) { ref in
                                HStack(spacing: 4) {
                                    Image(systemName: ref.iconName).zfont(.caption2)
                                    Text(ref.label).zfont(.caption2).lineLimit(1)
                                    Button { rt.draftReferences.removeAll { $0 == ref } } label: { Image(systemName: "xmark").zfont(size: 8) }
                                        .buttonStyle(.borderless)
                                }
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Theme.accentSoft, in: Capsule()).foregroundStyle(Theme.accent)
                            }
                        }
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
                MentionField(text: draftBinding(rt), references: refsBinding(rt),
                             placeholder: "Ask a follow-up…  (type @ to reference a file, person, step, or chat)",
                             onSend: send, autofocus: true)
                InputControls()
            }
            .padding(12)
            .background(Theme.panel)
            .overlay(Divider(), alignment: .top)
        }
    }

    private func send() {
        guard let rt = app.activeRuntime else { return }
        let text = rt.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }   // mid-stream is fine now — ChatRuntime queues it
        let refs = rt.draftReferences
        rt.draft = ""
        rt.draftReferences = []
        app.beginSendChat(text, references: refs)
    }

    private var header: some View {
        HStack {
            Button { app.selectHome() } label: {
                Label("Home", systemImage: "chevron.left")
            }.buttonStyle(.borderless)
            Spacer()
            if app.isStreaming {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    if !app.statusLine.isEmpty {
                        Text(app.statusLine).zfont(.caption).foregroundStyle(.secondary)
                    }
                    Button { app.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(.borderless).zfont(.caption).tint(Theme.warn)
                }
            }
            Spacer()
            if let rt = app.activeRuntime {
                Button { rt.setRemoteControl(!rt.remoteControlOn) } label: {
                    Label(rt.remoteControlOn ? "On your phone" : "Remote control",
                          systemImage: rt.remoteControlOn ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                        .zfont(.caption)
                }
                .buttonStyle(.borderless)
                .tint(rt.remoteControlOn ? Theme.accent : .secondary)
                .help("Continue this chat on your phone. Turns it into a Claude Code Remote Control session — open the link / scan the QR on your phone, or find it in the Claude app.")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// Shown when remote control is on: the pairing URL + a QR to scan with a phone. Messages typed
    /// on the phone appear in this same transcript; you can keep typing here too.
    private func remoteBar(_ rt: ChatRuntime) -> some View {
        HStack(spacing: 12) {
            if let url = rt.remoteSessionURL, let qr = Self.qrImage(url) {
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

    static func qrImage(_ string: String) -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: ci)
        let img = NSImage(size: rep.size); img.addRepresentation(rep); return img
    }

    private var transcript: some View {
        GeometryReader { outer in
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let alert = app.currentAlert { AlertBanner(alert: alert) }

                    ForEach(app.messages) { msg in
                        MessageRow(message: msg)
                    }

                    if app.isStreaming {
                        ResearchTrace(steps: app.currentTrace, statusLine: app.statusLine, tokens: app.currentTokens)
                        if !app.liveText.isEmpty {
                            MessageRow(message: ChatMessage(id: "live", role: .assistant, text: app.liveText + " ▍", timestamp: Date()))
                        }
                    }
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
            .onPreferenceChange(AtBottomKey.self) { v in Task { @MainActor in atBottom = v } }
            .onChange(of: app.messages.count) { _, _ in if atBottom { withAnimation { proxy.scrollTo("bottom") } } }
            .onChange(of: app.liveText) { _, _ in if atBottom { proxy.scrollTo("bottom") } }
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

private struct AtBottomKey: PreferenceKey {
    static var defaultValue: Bool = true
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = nextValue() }
}

struct MessageRow: View {
    @Environment(AppState.self) private var app
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack(alignment: .bottom, spacing: 4) {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 3) {
                    if !message.references.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(message.references) { ref in
                                HStack(spacing: 4) {
                                    Image(systemName: ref.iconName).zfont(size: 9)
                                    Text(ref.label).zfont(.caption2).lineLimit(1)
                                }
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Theme.accentSoft, in: Capsule()).foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    if !message.text.isEmpty {
                        Text(message.text)
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
                // Table-free messages render as ONE selectable Text so the user can drag-select
                // across paragraphs and copy. Table messages keep the grid renderer (per-block).
                Group {
                    if MarkdownText.hasTable(message.text) {
                        MarkdownText(message.text)
                    } else {
                        Text(MarkdownText.fullAttributed(message.text))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                    .contextMenu {
                        Button("Explain in a new chat") {
                            app.explainInNewChat(message.text, fromChat: app.activeChatId)
                        }
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                        }
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
                    Text((expanded ? "Working · \(steps.count) step\(steps.count == 1 ? "" : "s")" : current) + tokenLabel)
                        .zfont(.caption, .medium).foregroundStyle(.secondary).lineLimit(1)
                        .monospacedDigit()
                    Spacer(minLength: 4)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").zfont(.caption2).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
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
struct MarkdownText: View {
    let raw: String
    init(_ raw: String) { self.raw = raw }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(MarkdownText.parse(raw).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
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
    static func fullAttributed(_ raw: String) -> AttributedString {
        var out = AttributedString("")
        for (i, block) in parse(raw).enumerated() {
            if i > 0 { out += AttributedString("\n\n") }
            switch block {
            case .heading(let t):
                var a = inline(t); a.font = .headline
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

    static func renumberCitations(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "\\[S(\\d+)\\]") else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "[$1]")
    }
}
