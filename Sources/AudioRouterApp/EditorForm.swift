// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import AudioRouterAppCore
import SwiftUI

/// The route form: app, destination device, destination pair and source pair. Messages come from the
/// view model and sit under their field.
struct EditorForm: View {
    @Bindable var model: EditorViewModel

    var body: some View {
        Form {
            Section("App") {
                TextField("Bundle id", text: $model.draft.appBundleID)
                Menu("Running apps") {
                    ForEach(model.apps) { app in
                        Button(app.title) { model.draft.appBundleID = app.bundleID }
                    }
                }
                .disabled(model.apps.isEmpty)
                if let note = model.appNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                issues(.app)
                TextField("Name (optional)", text: $model.draft.name)
            }
            Section("Destination") {
                Picker(
                    "Device",
                    selection: Binding(get: { model.draft.destinationUID }, set: { model.selectDevice($0) })
                ) {
                    Text("Choose a device").tag("")
                    ForEach(model.deviceChoices) { Text($0.name).tag($0.uid) }
                }
                issues(.device)
                Picker("Channels", selection: $model.draft.destinationFirst) {
                    ForEach(model.destinationPairChoices, id: \.self) { Text(EditorText.pairLabel($0)).tag($0) }
                }
                issues(.destinationPair)
                Text(EditorViewModel.destinationHint).font(.caption).foregroundStyle(.secondary)
            }
            Section("Source") {
                Picker("App channels", selection: $model.draft.sourceFirst) {
                    ForEach(model.sourcePairChoices, id: \.self) { Text(EditorText.pairLabel($0)).tag($0) }
                }
                issues(.sourcePair)
            }
            issues(.general)
            if let failure = model.failure {
                Text(failure).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { model.save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        // The device and app lists change while the form is open.
        .task {
            while !Task.isCancelled {
                model.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder
    private func issues(_ field: EditorField) -> some View {
        ForEach(model.messages(for: field), id: \.self) { message in
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }
}
