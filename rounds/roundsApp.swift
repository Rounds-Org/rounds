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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(app)
                .task { await app.bootstrap() }
                .frame(minWidth: 1080, minHeight: 720)
        }
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
                Button("Settings…") { app.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
                Divider()
                Button("Check for Updates…") { app.checkForUpdate() }
            }
        }
    }
}
