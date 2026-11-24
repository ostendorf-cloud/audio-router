// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

/// The four states of `SMAppService.Status`, without the ServiceManagement import.
public enum LoginItemStatus: Sendable, Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

/// The login item registration. The live implementation wraps `SMAppService.mainApp` in the app target.
@MainActor
public protocol LoginItemService {
    /// The current status. Read it again on every use, the user can change it in System Settings.
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    /// Opens Login Items in System Settings.
    func openSystemSettings()
}
