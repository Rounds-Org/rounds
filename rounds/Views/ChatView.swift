//
//  ChatView.swift
//  rounds
//
//  No-bubble chat. Assistant prose streams in left-aligned; the user's lines are
//  right-aligned. An urgent-attention banner can override the calm framing. The input
//  supports @-mentioning a filed document.
//

import SwiftUI

struct ChatView: View {
    @Environment(AppState.self) private var app
    @State private var draft = ""
    @State private var references: [Reference] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            inputBar
        }
        .background(Theme.bg)
        .onAppear(perform: pickupPending)
        .onChange(of: app.activeChatId) { _, _ in pickupPending() }
    }

    private func pickupPending() {
        if !app.pendingChatDraft.isEmpty {
            draft = app.pendingChatDraft
            references = app.pendingReferences
            app.pendingChatDraft = ""
            app.pendingReferences = []
        }
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !references.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(references) { ref in
                            HStack(spacing: 4) {
                                Image(systemName: ref.iconName).font(.caption2)
                                Text(ref.label).font(.caption2).lineLimit(1)
                                Button { references.removeAll { $0 == ref } } label: { Image(systemName: "xmark").font(.system(size: 8)) }
                                    .buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Theme.accentSoft, in: Capsule()).foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
            MentionField(text: $draft, references: $references,
                         placeholder: "Ask a follow-up…  (type @ to reference a file, person, step, or chat)",
                         onSend: send, autofocus: true)
        }
        .padding(12)
        .background(Theme.panel)
        .overlay(Divider(), alignment: .top)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !app.isStreaming else { return }
        let refs = references
        draft = ""
        references = []
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
                        Text(app.statusLine).font(.caption).foregroundStyle(.secondary)
                    }
                    Button { app.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(.borderless).font(.caption).tint(Theme.warn)
                }
            }
            Spacer()
            ModelPicker()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let alert = app.currentAlert { AlertBanner(alert: alert) }

                    ForEach(app.messages) { msg in
                        MessageRow(message: msg)
                    }

                    if app.isStreaming {
                        ResearchTrace(steps: app.currentTrace, statusLine: app.statusLine)
                        if !app.liveText.isEmpty {
                            MessageRow(message: ChatMessage(id: "live", role: .assistant, text: app.liveText + " ▍", timestamp: Date()))
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: app.messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
            .onChange(of: app.liveText) { _, _ in proxy.scrollTo("bottom") }
        }
    }

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
                    Text(message.text)
                        .textSelection(.enabled)
                        .padding(.vertical, 8).padding(.horizontal, 12)
                        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
                    CopyButton(text: message.text)
                }
            }
        case .system:
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.secondary)
                Text(message.text).font(.callout).foregroundStyle(.secondary).italic()
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 4) {
                MarkdownText(message.text)
                    .contextMenu {
                        Button("Explain in a new chat") {
                            app.explainInNewChat(message.text, fromChat: app.activeChatId)
                        }
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                        }
                    }
                CopyButton(text: message.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                .font(.caption2).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
    }
}

/// A live "what the AI is doing" trace. Collapsed (default) shows just the current line;
/// expanded shows every step.
struct ResearchTrace: View {
    let steps: [String]
    let statusLine: String
    @State private var expanded = true

    private var current: String { statusLine.isEmpty ? (steps.last ?? "Working…") : statusLine }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation { expanded.toggle() } } label: {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text(expanded ? "Working · \(steps.count) step\(steps.count == 1 ? "" : "s")" : current)
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    HStack(spacing: 7) {
                        if i == steps.count - 1 {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(Theme.accent)
                        }
                        Text(step).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
                Text("This may need urgent attention").font(.headline).foregroundStyle(.white)
                Text(alert.message).font(.callout).foregroundStyle(.white.opacity(0.95))
                if let m = alert.marker, let v = alert.value {
                    Text("\(m): \(v)" + (alert.basis.map { " · \($0)" } ?? ""))
                        .font(.caption).foregroundStyle(.white.opacity(0.85))
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
            Text(t).font(.headline).fixedSize(horizontal: false, vertical: true)
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
                            Text(MarkdownText.inline(h)).font(.callout.weight(.semibold))
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
