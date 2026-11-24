// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import AudioRouterAppCore
import SwiftUI

/// The route list of the settings window with Add, Edit and Delete. The form opens as a sheet.
struct EditorRouteList: View {
    @Bindable var model: EditorViewModel

    var body: some View {
        if model.rows.isEmpty {
            Text("No routes yet.").foregroundStyle(.secondary)
        }
        ForEach(model.rows) { row in
            HStack {
                VStack(alignment: .leading) {
                    Text(row.title)
                    Text(row.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Edit") { model.beginEdit(row.id) }
                Button("Delete", role: .destructive) { model.delete(row.id) }
            }
        }
        if let failure = model.failure, !model.isEditing {
            Text(failure).font(.caption).foregroundStyle(.red)
        }
        Button("Add route\u{2026}") { model.beginNew() }
            .sheet(isPresented: Binding(get: { model.isEditing }, set: { if !$0 { model.cancel() } })) {
                EditorForm(model: model)
            }
    }
}
