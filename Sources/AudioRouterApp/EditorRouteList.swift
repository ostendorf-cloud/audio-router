// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import AudioRouterAppCore
import SwiftUI

/// The route list of the settings window with Add, Edit and Delete. The form opens as a sheet.
/// The pending delete lives in the model: no `@State`, its macro plugin ships with Xcode only.
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
                    .accessibilityLabel("Edit \(row.title)")
                Button("Delete", role: .destructive) { model.requestDelete(row.id) }
                    .accessibilityLabel("Delete \(row.title)")
            }
        }
        if let failure = model.failure, !model.isEditing {
            Text(failure).font(.caption).foregroundStyle(.red)
        }
        Button("Add route\u{2026}") { model.beginNew() }
            .sheet(isPresented: Binding(get: { model.isEditing }, set: { if !$0 { model.cancel() } })) {
                EditorForm(model: model)
            }
            .confirmationDialog(
                "Delete this route?",
                isPresented: Binding(
                    get: { model.pendingDelete != nil }, set: { if !$0 { model.cancelDelete() } }),
                presenting: model.pendingDelete
            ) { row in
                Button("Delete \(row.title)", role: .destructive) { model.confirmDelete(row.id) }
            } message: { row in
                Text("\(row.title) stops and the app plays on its own output again.")
            }
            // The file may have been unreadable at the first open, and devices come and go.
            .onAppear { if !model.isEditing { model.reload() } }
            .task {
                while !Task.isCancelled {
                    model.refresh()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
    }
}
