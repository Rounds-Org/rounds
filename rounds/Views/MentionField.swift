//
//  MentionField.swift
//  rounds
//
//  The shared chat/ask input. Type @ to reference a document, a person, a next step, or a
//  prior chat — arrow keys move through the menu, Enter picks (or sends when the menu is
//  closed). Picked references are resolved into context the brain can Read.
//

import SwiftUI
import AppKit

struct MentionField: View {
    @Environment(AppState.self) private var app
    @Binding var text: String
    @Binding var references: [Reference]
    var placeholder: String
    var onSend: () -> Void
    var autofocus: Bool = false

    @State private var mentionQuery: String?
    @State private var selected = 0
    @FocusState private var focused: Bool

    private var items: [Reference] { mentionQuery.map { app.mentionCandidates($0) } ?? [] }
    private var menuOpen: Bool { mentionQuery != nil && !items.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if menuOpen { menu }
            HStack(spacing: 10) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($focused)
                    .onChange(of: text) { _, new in updateMention(new) }
                    .onKeyPress { press in handleKey(press) }
                Button(action: trySend) {
                    Image(systemName: "arrow.up.circle.fill").zfont(.title2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(text.isEmpty ? .secondary : Theme.accent)
                .disabled(text.isEmpty || app.isStreaming)
            }
        }
        .onAppear {
            if autofocus {
                focused = true
                // Pre-filled text gets select-all on focus by default — move the caret to the end.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                        let end = (editor.string as NSString).length
                        editor.setSelectedRange(NSRange(location: end, length: 0))
                    }
                }
            }
        }
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Reference a file, person, next step, or chat").zfont(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("↑↓ ↩").zfont(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            ForEach(Array(items.enumerated()), id: \.element.id) { i, ref in
                Button { pick(ref) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: ref.iconName).foregroundStyle(Theme.accent).frame(width: 16)
                        Text(ref.label).lineLimit(1)
                        Spacer()
                        Text(ref.kind.rawValue).zfont(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 5).padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(i == selected ? Theme.accentSoft : .clear)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 4)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
        .padding(.bottom, 6)
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .upArrow where menuOpen:
            selected = max(0, selected - 1); return .handled
        case .downArrow where menuOpen:
            selected = min(items.count - 1, selected + 1); return .handled
        case .escape where menuOpen:
            mentionQuery = nil; return .handled
        case .return:
            if menuOpen { pick(items[min(selected, items.count - 1)]); return .handled }
            if press.modifiers.contains(.shift) { text += "\n"; return .handled }   // newline
            trySend(); return .handled
        default:
            return .ignored
        }
    }

    private func updateMention(_ s: String) {
        if let at = s.lastIndex(of: "@") {
            let after = s[s.index(after: at)...]
            if !after.contains("\n"), !after.contains("  ") {
                let q = String(after)
                if q != mentionQuery { selected = 0 }
                mentionQuery = q
                return
            }
        }
        mentionQuery = nil
    }

    private func pick(_ ref: Reference) {
        let token = "@\(ref.label) "
        let trigger = "@" + (mentionQuery ?? "")
        if let r = text.range(of: trigger, options: .backwards) {
            text.replaceSubrange(r, with: token)          // replace the "@query" the user typed
        } else if let at = text.lastIndex(of: "@") {
            text.replaceSubrange(at..., with: token)
        } else {
            text += token
        }
        if !references.contains(ref) { references.append(ref) }
        mentionQuery = nil
        selected = 0
    }

    private func trySend() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !app.isStreaming else { return }
        mentionQuery = nil
        onSend()
    }
}
