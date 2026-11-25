// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
import RouterCore

/// The state behind the route list and the route editor of the settings window.
///
/// Save and delete write the `RouteStore` first and call `engine.setRoutes` second, so a failed write
/// leaves the engine as it was. `setRoutes` does not block. It restarts a changed route and tears
/// down a removed one.
@MainActor @Observable
public final class EditorViewModel {
    @ObservationIgnored private let store: any EditorRouteStoring
    @ObservationIgnored private let engine: any ShellEngine
    @ObservationIgnored private let deviceProvider: any DeviceProviding
    @ObservationIgnored private let appProvider: any AppProviding

    /// The stored routes, in file order.
    public private(set) var routes: [Route] = []
    public private(set) var devices: [EditorDevice] = []
    public private(set) var apps: [EditorApp] = []
    /// True while the form is open.
    public private(set) var isEditing = false
    /// The form values.
    public var draft = EditorDraft()
    /// False until a save failed or an existing route was opened, so a new form starts without red text.
    public private(set) var validationShown = false
    /// Why the last save or delete did not write. Shown below the form or the list.
    public private(set) var failure: String?
    /// The row the list asks to confirm a delete for. The view holds no state of its own, because
    /// `@State` is a macro whose plugin ships with Xcode only.
    public private(set) var pendingDelete: EditorRouteRow?

    public init(
        store: any EditorRouteStoring, engine: any ShellEngine, devices: any DeviceProviding,
        apps: any AppProviding
    ) {
        self.store = store
        self.engine = engine
        self.deviceProvider = devices
        self.appProvider = apps
        refresh()
        reload()
    }

    // MARK: - Lists

    /// Reads the devices and apps again. The view calls it while the form is open.
    public func refresh() {
        let newDevices = deviceProvider.devices()
        if newDevices != devices { devices = newDevices }
        let newApps = appProvider.apps()
        if newApps != apps { apps = newApps }
    }

    /// Reads the route file again.
    public func reload() {
        do {
            routes = try store.load()
            failure = nil
        } catch {
            routes = []
            failure = String(describing: error)
        }
    }

    public var rows: [EditorRouteRow] {
        routes.map { route in
            let device = devices.first { $0.uid == route.destinationUID }?.name ?? route.destinationUID
            let first = route.destinationPair.first
            return EditorRouteRow(
                id: route.id, title: route.name,
                detail: "\(route.appBundleID) to \(device), channels \(EditorText.pairLabel(first))")
        }
    }

    // MARK: - Form

    public func beginNew() {
        draft = EditorDraft()
        pendingID = UUID()
        validationShown = false
        failure = nil
        refresh()
        isEditing = true
    }

    public func beginEdit(_ id: UUID) {
        guard var route = routes.first(where: { $0.id == id }) else { return }
        // The file does not hold the menu switch, so the form shows the state the app asked the engine for.
        if let live = engine.routesToBuildOn.first(where: { $0.id == id }) { route.enabled = live.enabled }
        draft = EditorDraft(route: route)
        validationShown = true
        failure = nil
        refresh()
        isEditing = true
    }

    public func cancel() {
        isEditing = false
        validationShown = false
        failure = nil
    }

    /// Picks the destination device. A pair that does not fit the new device goes back to 1,2.
    public func selectDevice(_ uid: String) {
        draft.destinationUID = uid
        guard let device = devices.first(where: { $0.uid == uid }) else { return }
        if draft.destinationFirst + 1 > device.channelCount { draft.destinationFirst = 1 }
        if draft.sourceFirst + 1 > device.tapChannelCount { draft.sourceFirst = 1 }
    }

    /// The devices of the picker. A stored device that is not connected stays in the list, so the
    /// picker can show it next to its error.
    public var deviceChoices: [EditorDevice] {
        let uid = draft.destinationUID
        guard !uid.isEmpty, !devices.contains(where: { $0.uid == uid }) else { return devices }
        return devices + [EditorDevice(uid: uid, name: "Not connected (\(uid))", channelCount: 0)]
    }

    /// The first channels of the pairs the destination pair picker offers.
    public var destinationPairChoices: [Int] {
        Self.pairChoices(channelCount: channelCount, current: draft.destinationFirst)
    }

    /// The first channels of the pairs the source pair picker offers. A device stream tap has the
    /// format of output stream 0 of the destination device, not of the whole device.
    public var sourcePairChoices: [Int] {
        Self.pairChoices(channelCount: tapChannelCount, current: draft.sourceFirst)
    }

    /// A note under the source picker when the tap has fewer channels than the device.
    public var sourceNote: String? {
        tapChannelCount < channelCount ? EditorText.tapLimit : nil
    }

    /// Stereo pairs 1,2 then 3,4 and so on, plus the current value when it is not among them.
    public static func pairChoices(channelCount: Int, current: Int) -> [Int] {
        var firsts = channelCount >= 2 ? Array(stride(from: 1, through: channelCount - 1, by: 2)) : []
        if !firsts.contains(current) { firsts.append(current) }
        return firsts.sorted()
    }

    /// Set when the typed bundle id is not among the running apps.
    public var appNote: String? {
        let id = draft.appBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !apps.contains(where: { $0.bundleID == id }) else { return nil }
        return EditorText.appNotRunning
    }

    public static let destinationHint = EditorText.destinationHint

    // MARK: - Validation

    /// Every problem of the draft, mapped to a field. Empty means the draft can be saved.
    public var issues: [EditorIssue] {
        guard let route = makeRoute() else {
            return [EditorIssue(field: .destinationPair, message: EditorText.invalidPair)]
        }
        let others = routes.filter { $0.id != route.id }
        // The route under edit goes last, so a clash is reported on it and not on the other route.
        // It is checked as enabled, so its device and pair errors show for a switched off route too.
        var checked = route
        checked.enabled = true
        let errors = RouteValidator.validate(
            others + [checked], devices: validatorDevices, processes: []
        ).filter { $0.routeID == route.id }
        return errors.map { map($0, others: others) }
    }

    /// The messages of one field, empty while the form has not been checked yet.
    public func messages(for field: EditorField) -> [String] {
        guard validationShown else { return [] }
        return issues.filter { $0.field == field }.map(\.message)
    }

    // MARK: - Save and delete

    /// Validates, writes the store and hands the routes to the engine. Returns false and keeps the form
    /// open when the draft has a problem or the store refuses.
    @discardableResult
    public func save() -> Bool {
        refresh()
        guard issues.isEmpty, var route = makeRoute() else {
            validationShown = true
            return false
        }
        do {
            let stored = try currentRoutes()
            var updated = stored
            if let index = updated.firstIndex(where: { $0.id == route.id }) {
                // An edit never switches a route on or off. The menu owns that, and it may have
                // changed while the form was open.
                route.enabled = updated[index].enabled
                updated[index] = route
            } else {
                updated.append(route)
            }
            try store.save(updated)
            routes = updated
            engine.setRoutes(updated)
            isEditing = false
            validationShown = false
            failure = nil
            return true
        } catch {
            failure = String(describing: error)
            return false
        }
    }

    /// Asks to confirm the delete of a listed route. An id that is not listed asks nothing.
    public func requestDelete(_ id: UUID) {
        pendingDelete = rows.first { $0.id == id }
    }

    /// Deletes the confirmed route and closes the question. The dialog passes the row it shows, so a
    /// dismiss that runs before the button action cannot lose the id.
    @discardableResult
    public func confirmDelete(_ id: UUID) -> Bool {
        pendingDelete = nil
        return delete(id)
    }

    /// Closes the question and deletes nothing.
    public func cancelDelete() {
        pendingDelete = nil
    }

    /// Removes the route from the store and from the engine, which stops it.
    @discardableResult
    public func delete(_ id: UUID) -> Bool {
        do {
            let updated = try currentRoutes().filter { $0.id != id }
            try store.save(updated)
            routes = updated
            engine.setRoutes(updated)
            if draft.id == id { isEditing = false }
            failure = nil
            return true
        } catch {
            failure = String(describing: error)
            return false
        }
    }

    // MARK: - Private

    private var channelCount: Int {
        devices.first { $0.uid == draft.destinationUID }?.channelCount ?? 0
    }

    private var tapChannelCount: Int {
        devices.first { $0.uid == draft.destinationUID }?.tapChannelCount ?? 0
    }

    private var validatorDevices: [OutputDevice] {
        devices.map { OutputDevice(objectID: 0, uid: $0.uid, name: $0.name, channelCount: $0.channelCount) }
    }

    /// The stored routes with the on and off state the menu holds. The menu switch is not stored, so
    /// the engine's value wins for a route it knows.
    private func currentRoutes() throws -> [Route] {
        let desired = engine.routesToBuildOn
        return try store.load().map { route in
            guard let live = desired.first(where: { $0.id == route.id }) else { return route }
            var merged = route
            merged.enabled = live.enabled
            return merged
        }
    }

    private func makeRoute() -> Route? {
        guard
            let destination = try? ChannelPair(first: draft.destinationFirst),
            let source = try? ChannelPair(first: draft.sourceFirst)
        else { return nil }
        let bundleID = draft.appBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return Route(
            id: draft.id ?? pendingID, name: name.isEmpty ? bundleID : name, appBundleID: bundleID,
            destinationUID: draft.destinationUID, destinationPair: destination, sourcePair: source,
            enabled: draft.enabled)
    }

    /// The id a new route gets, fixed while the form is open so the checks and the save agree.
    @ObservationIgnored private var pendingID = UUID()

    private func map(_ error: RouteValidationError, others: [Route]) -> EditorIssue {
        switch error {
        case .emptyBundleID:
            return EditorIssue(field: .app, message: EditorText.chooseApp)
        case .unknownDevice(_, let uid):
            let message = uid.isEmpty ? EditorText.chooseDevice : EditorText.deviceMissing
            return EditorIssue(field: .device, message: message)
        case .pairOutOfRange(_, _, let channels):
            return EditorIssue(
                field: .destinationPair, message: "This device has \(EditorText.channelCount(channels)).")
        case .duplicateDestinationPair(_, _, let other, let otherFirst, _):
            let name = others.first { $0.id == other }?.name ?? "another route"
            return EditorIssue(
                field: .destinationPair,
                message: "Shares a channel with \"\(name)\" (channels \(EditorText.pairLabel(otherFirst))).")
        case .duplicateRouteID:
            return EditorIssue(field: .general, message: EditorText.sameRouteTwice)
        }
    }
}
