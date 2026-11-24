// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Observation

/// The state behind the login item toggle in Settings.
@MainActor @Observable
public final class LoginItemViewModel {
    @ObservationIgnored private let service: any LoginItemService

    public private(set) var status: LoginItemStatus
    /// The text of the last failed register or unregister. Cleared by the next successful change.
    public private(set) var errorMessage: String?

    public init(service: any LoginItemService) {
        self.service = service
        status = service.status
    }

    /// Reads the real status. Call it on each appear of Settings.
    public func refresh() {
        errorMessage = nil
        status = service.status
    }

    /// The toggle shows on when the app is registered, also while the user still has to approve it.
    public var isOn: Bool { status == .enabled || status == .requiresApproval }

    /// Registers or unregisters. A failure becomes `errorMessage`. The status is read again either way.
    public func setEnabled(_ on: Bool) {
        do {
            if on {
                try service.register()
            } else {
                try service.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = "The login item could not be changed: \(error.localizedDescription)"
        }
        status = service.status
    }

    /// True when the hint comes with the button to Login Items.
    public var showsSettingsLink: Bool { status == .requiresApproval }

    /// A short hint or error for the current state, nil when there is nothing to say.
    public var message: String? {
        // The approval hint wins over an error, because it comes with the button to Login Items.
        switch status {
        case .requiresApproval:
            return "Approval is likely needed. Allow audio-router in Login Items in System Settings."
        case .notFound:
            return errorMessage ?? "The login item was not found. It likely works only from the /Applications folder."
        case .notRegistered, .enabled:
            return errorMessage
        }
    }

    public func openSystemSettings() {
        service.openSystemSettings()
    }
}
