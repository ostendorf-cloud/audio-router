// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Drives the `menu` client of the `MeterPoller` from the tracking of the menu bar menu.
///
/// A `MenuBarExtra` in menu style turns its content into `NSMenuItem`s. `onAppear` and
/// `onDisappear` of that content are not tied to opening and closing the menu, so the app does not
/// use them. It listens to `NSMenu.didBeginTrackingNotification` and
/// `NSMenu.didEndTrackingNotification` instead and calls this type.
///
/// Which menu is ours: the app cannot reach the `NSMenu` of the status item, so it passes the item
/// titles of the menu that is tracked, and the tracker accepts it only when `ownsMenu` says so. That
/// is a menu with the quit item of this app, `quitTitle`. A context menu or a menu of another part of
/// the app has no such item and is ignored, for begin and for end alike.
///
/// A begin twice and an end once leave the menu closed, because the poller keeps its clients as a set.
@MainActor
public final class MeterMenuTracker {
    /// The title of the quit item. The menu and the filter share it, so they cannot drift apart.
    public nonisolated static let quitTitle = "Quit audio-router"

    /// True for the item titles of the menu bar menu of this app.
    public nonisolated static func ownsMenu(itemTitles: [String]) -> Bool {
        itemTitles.contains(quitTitle)
    }

    private let poller: MeterPoller

    public init(poller: MeterPoller) {
        self.poller = poller
    }

    /// A menu started tracking. `itemTitles` nil means the caller already knows it is ours.
    public func menuDidBeginTracking(itemTitles: [String]? = nil) {
        guard itemTitles.map(Self.ownsMenu) ?? true else { return }
        poller.start(.menu)
    }

    /// A menu ended tracking.
    public func menuDidEndTracking(itemTitles: [String]? = nil) {
        guard itemTitles.map(Self.ownsMenu) ?? true else { return }
        poller.stop(.menu)
    }
}
