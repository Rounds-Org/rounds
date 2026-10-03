//
//  roundsApp.swift
//  rounds
//
//  Created by Michael Egorov on 6/20/26.
//

import SwiftUI

@main
struct roundsApp: App {
    @State private var app = AppState()

    init() { HandFont.register() }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(app)
                .task { await app.bootstrap() }
                // Claude Code may have updated (new models) while Rounds sat open — re-read the list.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await app.refreshModels() }
                    if let id = app.activeChatTab { app.markChatSeen(id) }   // back in the app, on that chat → seen
                }
                .frame(minWidth: 1080, minHeight: 720)
        }
        .windowStyle(.hiddenTitleBar)   // Yab-style: traffic lights sit in the sidebar, no title strip
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { app.startNewChat() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Close Tab") {
                    _ = app.closeActiveTab()   // on Home this is a no-op (don't quit the app)
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Larger Text") { app.bumpFontScale(1) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Smaller Text") { app.bumpFontScale(-1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { app.fontScaleStep = 0 }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
            }
            CommandMenu("View") {
                Button("Next Tab") { app.cycleTab(forward: true) }
                    .keyboardShortcut(.tab, modifiers: .control)
                Button("Previous Tab") { app.cycleTab(forward: false) }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
                Button("Search or Ask…") { app.showPalette.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Back") { app.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Forward") { app.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                Button("Settings…") { app.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
                Divider()
                Button("Check for Updates…") { app.checkForUpdate() }
            }
        }
    }
}
