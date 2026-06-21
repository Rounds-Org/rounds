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
                Text("Settings").zfont(.title2, .semibold)
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
                            .zfont(.caption).foregroundStyle(.secondary)
                        Picker("", selection: Binding(get: { app.selectedModel }, set: { app.selectedModel = $0 })) {
                            ForEach(RoundsModel.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.radioGroup)
                    }

                    section("Appearance") {
                        Picker("", selection: Binding(get: { app.appearance }, set: { app.appearance = $0 })) {
                            Text("Light").tag("light")
                            Text("Dark").tag("dark")
                            Text("Match system").tag("system")
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 320)
                        HStack(spacing: 10) {
                            Text("Text size").zfont(.callout)
                            Button { app.bumpFontScale(-1) } label: { Image(systemName: "textformat.size.smaller") }
                            Text(app.fontScaleStep == 0 ? "Default" : (app.fontScaleStep > 0 ? "+\(app.fontScaleStep)" : "\(app.fontScaleStep)"))
                                .zfont(.caption).foregroundStyle(.secondary).frame(width: 60)
                            Button { app.bumpFontScale(1) } label: { Image(systemName: "textformat.size.larger") }
                            Button("Reset") { app.fontScaleStep = 0 }.zfont(.caption).buttonStyle(.borderless)
                            Spacer()
                        }
                        Text("Tip: ⌘+ and ⌘− resize text anywhere in the app.").zfont(.caption2).foregroundStyle(.tertiary)
                    }

                    section("Answer language") {
                        Text("The language Rounds replies in — independent of your documents' language.")
                            .zfont(.caption).foregroundStyle(.secondary)
                        Picker("", selection: $language) {
                            ForEach(languages, id: \.self) { Text($0).tag($0) }
                            if !languages.contains(language), !language.isEmpty { Text(language).tag(language) }
                        }
                        .labelsHidden().frame(maxWidth: 280)
                    }

                    section("Your context") {
                        Text("Background about you that helps Rounds reason — habits, past surgeries, allergies, where you live. (You can add the same for family members from their file later.)")
                            .zfont(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $selfContext)
                            .zfont(.callout).frame(height: 90)
                            .padding(6)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
                    }

                    section("Custom instructions") {
                        Text("Extra guidance for the brain — e.g. \"be very concise\" or \"explain like I'm not a doctor\". These never override the safety principles.")
                            .zfont(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $custom)
                            .zfont(.callout).frame(height: 90)
                            .padding(6)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
                    }

                    section("Claude Code access") {
                        if app.toolPaths.supportsPermissionHooks {
                            Toggle(isOn: Binding(get: { app.fullPowerEnabled }, set: { app.fullPowerEnabled = $0 })) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Full Claude Code power").zfont(.callout, .medium)
                                    Text("Unlock the shell, web search, and sub-agents. Rounds asks your approval before each risky action.")
                                        .zfont(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }.toggleStyle(.switch).tint(Theme.accent)
                        } else {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "arrow.up.circle.fill").foregroundStyle(Theme.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Update Claude Code to unlock full power").zfont(.caption, .medium)
                                    Text("Your Claude Code\(app.toolPaths.claudeVersion.map { " (\($0))" } ?? "") is a bit old. Update it to let Rounds run the shell, web search, and sub-agents with an approval prompt. Until then, Rounds stays in safe mode.")
                                        .zfont(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    Link("Update instructions", destination: URL(string: "https://claude.com/code")!).zfont(.caption2)
                                }
                            }
                            .padding(10).background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            permRow("checkmark.circle.fill", Theme.accent, "Always allowed (no prompt)", "Read files · search your records · look up medical sources · file & update your documents")
                            permRow(app.fullPowerActive ? "hand.raised.fill" : "xmark.octagon.fill",
                                    Theme.warn,
                                    app.fullPowerActive ? "Asks first" : "Blocked in safe mode",
                                    "Shell (Bash) · web search · sub-agents" + (app.fullPowerActive ? " — Rounds shows an Allow/Deny dialog" : ""))
                        }
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                    }

                    section("Privacy") {
                        Toggle(isOn: Binding(get: { !app.analyticsOptOut }, set: { app.analyticsOptOut = !$0 })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Share anonymous usage stats").zfont(.callout)
                                Text("Counts and feature events only — never documents, names, or health data.")
                                    .zfont(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch).tint(Theme.accent)
                    }

                    section("Safety contract") {
                        Text("The system prompt Rounds always enforces. It's read-only — your custom instructions are added on top.")
                            .zfont(.caption).foregroundStyle(.secondary)
                        Button { withAnimation { showContract.toggle() } } label: {
                            HStack(spacing: 6) {
                                Image(systemName: showContract ? "chevron.down" : "chevron.right").zfont(.caption2)
                                Text(showContract ? "Hide the safety contract" : "View the safety contract")
                                Spacer()
                            }
                            .zfont(.callout).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .pointerStyle(.link)
                        if showContract {
                            ScrollView {
                                Text(app.contractText).zfont(.caption, design: .monospaced)
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
                            .zfont(.caption).foregroundStyle(.secondary)
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

    private func permRow(_ icon: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).zfont(.callout)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).zfont(.caption, .medium)
                Text(detail).zfont(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
