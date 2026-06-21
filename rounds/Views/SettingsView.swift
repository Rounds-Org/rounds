//
//  SettingsView.swift
//  rounds
//
//  Change the model, the language Claude Code answers in, and add custom instructions
//  (which never override the safety contract). The contract itself is shown read-only.
//

import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @State private var language = ""
    @State private var custom = ""
    @State private var selfContext = ""
    @State private var permissionMode: RoundsPermissionMode = .bypass
    @State private var showContract = false
    @State private var confirmWipe = false
    @State private var wiping = false

    private let languages = ["Auto (match the user)", "English", "Russian", "Spanish", "German",
                             "French", "Portuguese", "Ukrainian", "Hindi", "Chinese (Simplified)"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.title2.weight(.semibold))
                Spacer()
                Button { app.showSettings = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section("Model") {
                        Text("Which Claude model the brain uses. Opus is the deepest reasoner.")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: Binding(get: { app.selectedModel }, set: { app.selectedModel = $0 })) {
                            ForEach(RoundsModel.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.radioGroup)
                    }

                    section("Answer language") {
                        Text("The language Rounds replies in — independent of your documents' language.")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: $language) {
                            ForEach(languages, id: \.self) { Text($0).tag($0) }
                            if !languages.contains(language), !language.isEmpty { Text(language).tag(language) }
                        }
                        .labelsHidden().frame(maxWidth: 280)
                    }

                    section("Your context") {
                        Text("Background about you that helps Rounds reason — habits, past surgeries, allergies, where you live. (You can add the same for family members from their file later.)")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $selfContext)
                            .font(.callout).frame(height: 90)
                            .padding(6)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
                    }

                    section("Custom instructions") {
                        Text("Extra guidance for the brain — e.g. \"be very concise\" or \"explain like I'm not a doctor\". These never override the safety principles.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $custom)
                            .font(.callout).frame(height: 90)
                            .padding(6)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
                    }

                    section("Permissions") {
                        Text("How Claude Code asks before it reads or changes your records. Rounds can't show Claude Code's own approval prompts, so keep Bypass unless you know why you need otherwise.")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: $permissionMode) {
                            ForEach(RoundsPermissionMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.radioGroup)
                        Text(permissionMode.blurb).font(.caption2).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    section("Privacy") {
                        Toggle(isOn: Binding(get: { !app.analyticsOptOut }, set: { app.analyticsOptOut = !$0 })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Share anonymous usage stats").font(.callout)
                                Text("Counts and feature events only — never documents, names, or health data.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch).tint(Theme.accent)
                    }

                    section("Safety contract") {
                        Text("The system prompt Rounds always enforces. It's read-only — your custom instructions are added on top.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button { withAnimation { showContract.toggle() } } label: {
                            HStack(spacing: 6) {
                                Image(systemName: showContract ? "chevron.down" : "chevron.right").font(.caption2)
                                Text(showContract ? "Hide the safety contract" : "View the safety contract")
                                Spacer()
                            }
                            .font(.callout).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .pointerStyle(.link)
                        if showContract {
                            ScrollView {
                                Text(app.contractText).font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: 200)
                            .padding(8)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }

                    section("Reset") {
                        Text("Erase everything Rounds has stored — all documents, people, next steps, chats, and settings — and start over as a brand-new user. Claude Code and Node stay installed. This can't be undone.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(role: .destructive) { confirmWipe = true } label: {
                            HStack(spacing: 6) {
                                if wiping { ProgressView().controlSize(.small) }
                                Label("Delete all data", systemImage: "trash")
                            }
                        }
                        .buttonStyle(.bordered).tint(.red)
                        .disabled(wiping)
                    }
                }
                .padding(18)
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") {
                    app.saveSettings(language: language, customInstructions: custom, permissionMode: permissionMode)
                    if selfContext != app.selfContextText { app.saveSelfContext(selfContext) }
                    app.showSettings = false
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
            .padding(16)
        }
        .frame(width: 560, height: 620)
        .background(Theme.bg)
        .onAppear { language = app.language; custom = app.customInstructions; selfContext = app.selfContextText; permissionMode = app.permissionMode }
        .confirmationDialog("Delete all Rounds data?", isPresented: $confirmWipe, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) {
                wiping = true
                Task {
                    await app.wipeAllData()   // resets state + re-bootstraps into onboarding
                    wiping = false
                    app.showSettings = false
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This erases all documents, people, next steps, chats, and settings, and starts you over as a new user. It can't be undone. Claude Code and Node stay installed.")
        }
    }

    @ViewBuilder private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title)
            content()
        }
    }
}
