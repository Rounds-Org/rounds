//
//  SparkleUpdater.swift
//  rounds
//
//  One-click auto-update via Sparkle. Rounds ships its own Developer-ID-signed, notarized
//  builds; Sparkle reads the appcast (SUFeedURL in Info.plist), downloads the next version in
//  the background, verifies its EdDSA signature against SUPublicEDKey, and installs + relaunches
//  on a single click — the same flow as other native Mac apps. No health data is involved; the
//  only network touch is fetching the static appcast.xml + the release zip.
//

import Foundation
import AppKit
import Sparkle

@MainActor
final class SparkleUpdater: NSObject, SPUUpdaterDelegate {
    static let shared = SparkleUpdater()

    private var controller: SPUStandardUpdaterController!
    private var lastBackgroundCheck = Date.distantPast

    /// Called when Sparkle finds (or stops finding) an update, so AppState can drive the banner.
    var onUpdateFound: ((UpdateInfo) -> Void)?
    var onNoUpdate: (() -> Void)?

    private override init() {
        super.init()
        // startingUpdater: true → begins automatic background checks immediately.
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        controller.updater.automaticallyChecksForUpdates = true
        // Don't rely on Sparkle's 24h default — a Rounds window can stay open for months. Check
        // hourly (3600 is Sparkle's enforced minimum); the scheduler fires this timer even while
        // the app keeps running, so it's not a launch-only check.
        controller.updater.updateCheckInterval = 3600
    }

    /// Called once at launch. Registers wake/activate triggers so a Mac that was asleep for days
    /// (where the periodic timer can drift) re-checks promptly the moment the user comes back —
    /// silently, only surfacing the banner if there's actually a newer build.
    func start() {
        _ = controller
        NotificationCenter.default.addObserver(self, selector: #selector(wakeOrActivate),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wakeOrActivate),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc nonisolated private func wakeOrActivate() {
        Task { @MainActor in self.runBackgroundCheck() }
    }

    /// A silent background check, throttled to at most once per hour on top of Sparkle's own timer.
    private func runBackgroundCheck() {
        guard controller.updater.canCheckForUpdates,
              Date().timeIntervalSince(lastBackgroundCheck) >= 3600 else { return }
        lastBackgroundCheck = Date()
        controller.updater.checkForUpdatesInBackground()
    }

    /// Show Sparkle's update flow: download → verify signature → install & relaunch.
    /// Used by the sidebar banner and the "Check for Updates…" menu item.
    func checkForUpdates() { controller.checkForUpdates(nil) }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    // MARK: - SPUUpdaterDelegate

    /// Belt-and-suspenders: the feed URL is also in Info.plist (SUFeedURL); returning it here keeps
    /// the source of truth in code too.
    func feedURLString(for updater: SPUUpdater) -> String? {
        "https://raw.githubusercontent.com/Rounds-Org/rounds/main/appcast.xml"
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        onUpdateFound?(UpdateInfo(latestVersion: item.displayVersionString,
                                  downloadURL: nil,
                                  notes: item.itemDescription ?? "",
                                  mandatory: item.isCriticalUpdate))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        onNoUpdate?()
    }
}
