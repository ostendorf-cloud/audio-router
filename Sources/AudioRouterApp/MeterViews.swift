// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AudioRouterAppCore
import SwiftUI

/// A bar from -60 to 0 dBFS. The light bar is the peak, the solid bar in front is the RMS.
struct MeterBar: View {
    let level: MeterLevel?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.tint.opacity(0.35))
                    .frame(width: proxy.size.width * (level?.peakFraction ?? 0))
                Capsule().fill(.tint)
                    .frame(width: proxy.size.width * (level?.rmsFraction ?? 0))
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("Level")
        .accessibilityValue(level.map { "peak \($0.peakText) dBFS" } ?? "no signal")
    }
}

/// The name, the bar and the peak as a number.
struct MeterRow: View {
    let name: String
    let level: MeterLevel?

    var body: some View {
        HStack {
            Text(name).lineLimit(1)
            MeterBar(level: level)
                .frame(minWidth: 80)
            Text(level.map { "\($0.peakText) dBFS" } ?? "-")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
    }
}

/// The meters of the running routes. It starts no polling itself, see the two hooks below.
struct MeterList: View {
    let model: ShellViewModel

    var body: some View {
        let running = model.rows.filter { $0.state == .running || $0.state == .warning }
        if running.isEmpty {
            Text("No route is running.").foregroundStyle(.secondary)
        }
        ForEach(running) { row in
            MeterRow(name: row.name, level: model.meters.levels[row.id])
        }
    }
}

/// One hook for the menu: the meters below the route rows. The menu counts as visible between
/// `onAppear` and `onDisappear`. A `MenuBarExtra` menu may not report these reliably. Not verified,
/// see the pull request. The poller counts a client once, so a repeated event does no harm.
struct MeterMenuLines: View {
    let model: ShellViewModel

    var body: some View {
        MeterList(model: model)
            .onAppear { model.meters.start(.menu) }
            .onDisappear { model.meters.stop(.menu) }
    }
}

/// One hook for the settings window: a section with the meters. The window reports its own
/// visibility, because closing a settings window does not have to remove its content.
struct MeterSettingsSection: View {
    var body: some View {
        let model = ShellContext.model
        Section("Levels") {
            MeterList(model: model)
                .background(
                    WindowVisibility { visible in
                        if visible {
                            model.meters.start(.settings)
                        } else {
                            model.meters.stop(.settings)
                        }
                    }
                )
                .onDisappear { model.meters.stop(.settings) }
        }
    }
}

/// Reports whether the window that holds the view is on screen: shown, not minimised, not hidden
/// behind other windows or another space (occlusion state).
struct WindowVisibility: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: @MainActor (Bool) -> Void = { _ in }
        private var observers: [any NSObjectProtocol] = []
        private var last: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            guard let window else {
                report(false)
                return
            }
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            ]
            for name in names {
                observers.append(
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                        [weak self] notification in
                        let closing = notification.name == NSWindow.willCloseNotification
                        MainActor.assumeIsolated { self?.report(closing ? false : self?.isOnScreen ?? false) }
                    })
            }
            report(isOnScreen)
        }

        private var isOnScreen: Bool {
            guard let window else { return false }
            return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        }

        private func report(_ visible: Bool) {
            guard last != visible else { return }
            last = visible
            let onChange = onChange
            MainActor.assumeIsolated { onChange(visible) }
        }

        deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
