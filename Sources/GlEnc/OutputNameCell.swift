// SPDX-License-Identifier: MIT
import SwiftUI

/// Phase 8C-b — per-row Output column cell. Editable filename text
/// field + reset (↻) button visible when the user has overridden
/// the auto-generated name.
///
/// Editing model:
///   - The TextField shows `name` (the canonical job.outputName).
///   - The user types: each keystroke updates a local `@State editingText`
///     buffer + flips `isEditing = true`. The model isn't touched yet.
///   - On Enter (`onSubmit` modifier): `onEdit(editingText)` fires; the
///     parent writes back into the job, sets the override flag, and
///     the cell exits edit mode.
///   - On focus loss without Enter (current SwiftUI default for TextField
///     on macOS): same behavior — commit the edit. SwiftUI's
///     `onSubmit` fires on both Enter and editing-end.
///   - When `name` changes externally (codec/trim change re-derives
///     the auto-name), the cell syncs `editingText` to the new value
///     IF the user isn't actively editing.
///
/// The reset (↻) button is only rendered when `overridden == true`.
/// It calls `onReset` which clears the override flag + recomputes
/// the auto-name on the parent side; the resulting `name` change
/// flows back through `.onChange(of:name)` into `editingText`.
struct OutputNameCell: View {
    let name: String
    let overridden: Bool
    let onEdit: (String) -> Void
    let onReset: () -> Void

    @State private var editingText: String = ""
    @State private var isEditing: Bool = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $editingText)
                .textFieldStyle(.plain)
                .lineLimit(1)
                .truncationMode(.middle)
                .focused($isFocused)
                .help(name)
                .onChange(of: isFocused) { _, focused in
                    if focused {
                        isEditing = true
                    } else if isEditing {
                        // Lost focus while editing — commit.
                        commitIfChanged()
                    }
                }
                .onSubmit {
                    commitIfChanged()
                }
            if overridden {
                Button(action: {
                    isEditing = false
                    onReset()
                }) {
                    Image(systemName: "arrow.counterclockwise.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Reset to auto-generated name")
            }
        }
        .onAppear {
            editingText = name
        }
        .onChange(of: name) { _, newName in
            // Upstream auto-name update — sync into the field unless
            // the user is actively typing.
            if !isEditing {
                editingText = newName
            }
        }
    }

    private func commitIfChanged() {
        defer { isEditing = false }
        let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty / whitespace-only input → revert to current name.
        guard !trimmed.isEmpty else {
            editingText = name
            return
        }
        guard trimmed != name else { return }
        onEdit(trimmed)
    }
}
