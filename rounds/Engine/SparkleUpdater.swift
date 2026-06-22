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
import Sparkle

@MainActor
final class SparkleUpdater: NSObject, SPUUpdaterDelegate {
    static let shared = SparkleUpdater()

    private var controller: SPUStandardUpdaterController!

    /// Called when Sparkle finds (or stops finding) an update, so AppState can drive the banner.
    var onUpdateFound: ((UpdateInfo) -> Void)?
    var onNoUpdate: (() -> Void)?

    private override init() {
        super.init()
        // startingUpdater: true → begins automatic background checks immediately.
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        controller.updater.automaticallyChecksForUpdates = true
    }

    /// No-op hook; the updater is already started in init. Call once at launch to force creation.
    func start() { _ = controller }

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
