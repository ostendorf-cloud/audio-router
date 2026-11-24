// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import AudioRouterAppCore

/// A scripted login item. `register` and `unregister` move the status like the real service.
@MainActor
final class FakeLoginItemService: LoginItemService {
    struct Failure: Error, LocalizedError {
        var errorDescription: String? { "denied" }
    }

    var status: LoginItemStatus
    /// The status after a successful `register`.
    var statusAfterRegister: LoginItemStatus = .enabled
    var failure: Error?
    private(set) var calls: [String] = []

    init(status: LoginItemStatus = .notRegistered) { self.status = status }

    func register() throws {
        calls.append("register")
        if let failure { throw failure }
        status = statusAfterRegister
    }

    func unregister() throws {
        calls.append("unregister")
        if let failure { throw failure }
        status = .notRegistered
    }

    func openSystemSettings() { calls.append("openSystemSettings") }
}

@MainActor
struct LoginItemViewModelTests {
    @Test func toggleOnRegisters() {
        let service = FakeLoginItemService()
        let model = LoginItemViewModel(service: service)
        model.setEnabled(true)
        #expect(service.calls == ["register"])
        #expect(model.isOn)
        #expect(model.message == nil)
    }

    @Test func toggleOffUnregisters() {
        let service = FakeLoginItemService(status: .enabled)
        let model = LoginItemViewModel(service: service)
        #expect(model.isOn)
        model.setEnabled(false)
        #expect(service.calls == ["unregister"])
        #expect(!model.isOn)
    }

    @Test func requiresApprovalShowsHintAndLink() {
        let service = FakeLoginItemService()
        service.statusAfterRegister = .requiresApproval
        let model = LoginItemViewModel(service: service)
        model.setEnabled(true)
        #expect(model.isOn)
        #expect(model.showsSettingsLink)
        #expect(model.message?.contains("likely") == true)
        model.openSystemSettings()
        #expect(service.calls.last == "openSystemSettings")
    }

    @Test func notFoundShowsMessageWithoutLink() {
        let model = LoginItemViewModel(service: FakeLoginItemService(status: .notFound))
        #expect(!model.isOn)
        #expect(!model.showsSettingsLink)
        #expect(model.message?.contains("not found") == true)
    }

    @Test func errorShowsMessageAndKeepsRealStatus() {
        let service = FakeLoginItemService()
        service.failure = FakeLoginItemService.Failure()
        let model = LoginItemViewModel(service: service)
        model.setEnabled(true)
        #expect(!model.isOn)
        #expect(model.message?.contains("denied") == true)
    }

    @Test func successClearsEarlierError() {
        let service = FakeLoginItemService()
        service.failure = FakeLoginItemService.Failure()
        let model = LoginItemViewModel(service: service)
        model.setEnabled(true)
        service.failure = nil
        model.setEnabled(true)
        #expect(model.message == nil)
        #expect(model.isOn)
    }

    @Test func refreshClearsAStaleError() {
        let service = FakeLoginItemService()
        service.failure = FakeLoginItemService.Failure()
        let model = LoginItemViewModel(service: service)
        model.setEnabled(true)
        #expect(model.message != nil)
        model.refresh()
        #expect(model.message == nil)
    }

    @Test func approvalHintShowsDespiteAnOldError() {
        let service = FakeLoginItemService()
        service.failure = FakeLoginItemService.Failure()
        let model = LoginItemViewModel(service: service)
        model.setEnabled(true)
        service.status = .requiresApproval
        model.refresh()
        #expect(model.message?.contains("likely") == true)
        // A fresh error with the status still requiresApproval keeps the hint too.
        model.setEnabled(true)
        #expect(model.message?.contains("likely") == true)
    }

    @Test func plainStatesShowNoMessage() {
        #expect(LoginItemViewModel(service: FakeLoginItemService(status: .notRegistered)).message == nil)
        #expect(LoginItemViewModel(service: FakeLoginItemService(status: .enabled)).message == nil)
    }

    @Test func refreshReadsTheRealStatus() {
        let service = FakeLoginItemService(status: .enabled)
        let model = LoginItemViewModel(service: service)
        #expect(model.isOn)
        service.status = .notRegistered
        #expect(model.isOn)
        model.refresh()
        #expect(!model.isOn)
        service.status = .requiresApproval
        model.refresh()
        #expect(model.status == .requiresApproval)
    }
}
