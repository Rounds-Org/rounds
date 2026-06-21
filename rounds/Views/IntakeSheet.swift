//
//  IntakeSheet.swift
//  rounds
//
//  Confirm-to-continue filing. One question can cover SEVERAL files of the same person, so the
//  sheet shows every file it's asking about. Selecting an option only ARMS an answer; a
//  free-form multiline answer is always available; an explicit Continue submits. Rounds never
//  silently misfiles a document.
//

import SwiftUI

struct IntakeSheet: View {
    @Environment(AppState.self) private var app
    let state: IntakeState

    @State private var selected: String?
    @State private var freeform = ""
    @State private var nameAnswer = ""

    private var anyImaging: Bool { state.files.contains { $0.isImaging } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if anyImaging {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(Theme.warn)
                    Text("Some of these look like an image/scan with no written report. Rounds will store them, but only draws conclusions from text reports.")
                        .zfont(.caption).foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Theme.warn.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            Text(state.question.title).zfont(.title3, .medium)
                .fixedSize(horizontal: false, vertical: true)
            if let ctx = state.question.context, !ctx.isEmpty {
                Text(ctx).zfont(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(state.question.options) { opt in
                    Button { selected = opt.id } label: {
                        HStack {
                            Image(systemName: selected == opt.id ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(selected == opt.id ? Theme.accent : .secondary)
                            Text(opt.label)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .padding(10)
                        .background(selected == opt.id ? Theme.accentSoft : Theme.panel,
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }

            if state.askIdentity {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your name").zfont(.caption).foregroundStyle(.secondary)
                    TextField("e.g. Mike Smith", text: $nameAnswer)
                        .textFieldStyle(.roundedBorder)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Useful context (optional)").zfont(.caption).foregroundStyle(.secondary)
                Text("Who it is if it's a new person, where they live, habits, conditions — anything that helps Rounds reason.")
                    .zfont(.caption2).foregroundStyle(.tertiary)
                TextEditor(text: $freeform)
                    .zfont(.body)
                    .frame(height: 70)
                    .padding(6)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
            }

            HStack {
                Button("Skip these", role: .destructive) { app.skipIntake() }
                    .buttonStyle(.bordered)
                    .help("Discard these files — they aren't medical documents you want to keep")
                Button("Keep in inbox") { app.cancelIntake() }
                    .buttonStyle(.bordered)
                Spacer()
                Button {
                    let sel = selected
                    let ff = freeform
                    let nm = state.askIdentity ? nameAnswer : nil
                    Task { await app.submitIntake(selectedOptionId: sel, freeform: ff, nameAnswer: nm) }
                } label: {
                    Label("Continue", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .disabled(selected == nil && freeform.trimmingCharacters(in: .whitespaces).isEmpty && nameAnswer.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(Theme.bg)
    }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "tray.full")
                Text(state.files.count == 1 ? "Filing a document" : "Filing \(state.files.count) documents")
                    .zfont(.headline)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(state.files.prefix(6), id: \.stagedPath) { f in
                        VStack(spacing: 4) {
                            FilePreviewView(url: URL(fileURLWithPath: f.stagedPath))
                                .frame(width: 78, height: 100)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
                                .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: f.stagedPath)) }
                                .help("Open \(f.fileName)")
                            Text(f.fileName).zfont(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).frame(width: 78)
                        }
                    }
                    if state.files.count > 6 {
                        Text("+\(state.files.count - 6)")
                            .zfont(.caption).foregroundStyle(.secondary)
                            .frame(width: 44, height: 100)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }
}
