// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import AudioRouterAppCore
import ServiceManagement

/// Holds the one login item model of the app, created on first use. The settings window reads it from
/// here instead of `@State`.
@MainActor
enum LoginItemContext {
    static let model = LoginItemViewModel(service: LiveLoginItemService())
}

/// The login item over `SMAppService.mainApp` (macOS 13 and later, the floor is 14.2).
struct LiveLoginItemService: LoginItemService {
    private var service: SMAppService { SMAppService.mainApp }

    var status: LoginItemStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
