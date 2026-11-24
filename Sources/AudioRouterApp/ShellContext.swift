// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AudioRouterAppCore
import RouterCore
import RouterCoreAudio

/// Builds the real engine on Core Audio and holds the one view model the scenes and the delegate share.
@MainActor
enum ShellContext {
    static let engine = DesiredRoutesEngine(makeEngine())
    static let model = ShellViewModel(engine: engine)

    private static func makeEngine() -> RouteEngine {
        RouteEngine(
            deviceModel: DeviceModel(monitor: CoreAudioDeviceMonitor()),
            processMonitor: ProcessMonitor.coreAudio(),
            sessions: BackendSessionMaker(backend: CoreAudioRoutingBackend(), devices: CoreAudioDeviceProvider()))
    }

    /// Loads the stored routes (none when there is no file or it cannot be read) and starts the engine.
    static func startEngine() {
        let routes = (try? RouteStore.defaultURL()).flatMap { try? RouteStore(url: $0).load() } ?? []
        Task { await model.start(routes: routes) }
    }
}

/// AppKit is needed for two things: the activation policy and the quit handshake.
final class ShellAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A bundled run gets no Dock icon from LSUIElement. A dev run (`swift run`) has no Info.plist,
        // so the policy is set here too.
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated { ShellContext.startEngine() }
    }

    /// Quit waits for `engine.stopAll()`. `.terminateLater` keeps the process alive while the view
    /// model tears the routes down off the main thread, and `reply(toApplicationShouldTerminate:)`
    /// lets the quit go on after `stopAll` returned. `.terminateNow` would exit while routes still
    /// hold a tap and an aggregate device.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            ShellContext.model.shutdown { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}
