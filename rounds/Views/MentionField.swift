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
    @State private var slashQuery: String?
    @State private var selected = 0
    @State private var editorHeight: CGFloat = 24

    private var items: [Reference] { mentionQuery.map { app.mentionCandidates($0) } ?? [] }
    private var menuOpen: Bool { mentionQuery != nil && !items.isEmpty }

    // `/` slash commands (Claude Code) — only when the message STARTS with "/".
    private var slashItems: [String] {
        guard let q = slashQuery?.lowercased() else { return [] }
        let all = app.slashCommands
        let hits = q.isEmpty ? all : all.filter { $0.lowercased().hasPrefix(q) } + all.filter { $0.lowercased().contains(q) && !$0.lowercased().hasPrefix(q) }
        return Array(NSOrderedSet(array: hits).array as? [String] ?? hits).prefix(8).map { $0 }
    }
    private var slashMenuOpen: Bool { slashQuery != nil && !slashItems.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if menuOpen { menu }
            if slashMenuOpen { slashMenu }
            HStack(alignment: .bottom, spacing: 10) {
                ChatInputEditor(text: $text, height: $editorHeight, placeholder: placeholder, autofocus: autofocus,
                                onEnter: handleEnter, onArrow: handleArrow, onEscape: handleEscape)
                    .frame(maxWidth: .infinity)
                    .frame(height: editorHeight)
                    .onChange(of: text) { _, new in updateTriggers(new) }
                Button(action: trySend) {
                    Image(systemName: "arrow.up.circle.fill").zfont(.title2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(text.isEmpty ? .secondary : Theme.accent)
                .disabled(text.isEmpty)   // mid-stream is allowed now — the message gets queued
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

    // Special keys routed from the native editor (ChatInputEditor). Return true if consumed.
    private func handleEnter() -> Bool {
        if slashMenuOpen { pickSlash(slashItems[min(selected, slashItems.count - 1)]); return true }
        if menuOpen { pick(items[min(selected, items.count - 1)]); return true }
        trySend(); return true
    }
    private func handleArrow(_ up: Bool) -> Bool {
        guard menuOpen || slashMenuOpen else { return false }
        if up { selected = max(0, selected - 1) }
        else { selected = min((slashMenuOpen ? slashItems.count : items.count) - 1, selected + 1) }
        return true
    }
    private func handleEscape() -> Bool {
        guard menuOpen || slashMenuOpen else { return false }
        mentionQuery = nil; slashQuery = nil; return true
    }

    private func updateTriggers(_ s: String) {
        // Slash command: only when the whole message starts with "/" and the command word is still
        // being typed (no space yet). Picking inserts a trailing space, which closes the menu.
        if s.hasPrefix("/"), !s.dropFirst().contains(" "), !s.contains("\n") {
            let q = String(s.dropFirst())
            if q != slashQuery { selected = 0 }
            slashQuery = q; mentionQuery = nil
            return
        }
        slashQuery = nil
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

    private var slashMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Claude Code command").zfont(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("↑↓ ↩").zfont(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            ForEach(Array(slashItems.enumerated()), id: \.element) { i, cmd in
                Button { pickSlash(cmd) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "terminal").foregroundStyle(Theme.accent).frame(width: 16)
                        Text("/\(cmd)").lineLimit(1)
                        Spacer()
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

    private func pickSlash(_ cmd: String) {
        text = "/\(cmd) "   // trailing space closes the menu; press ↩ to run (or add arguments first)
        slashQuery = nil
        selected = 0
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
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }   // mid-stream OK — queued
        mentionQuery = nil
        onSend()
    }
}
