// SPDX-License-Identifier: MIT
/*
 * ManageSizesSheet — Resize Release Phase H.
 *
 * A small sheet that lists the user's named custom presets with a
 * delete button per row. No in-place edit — the user re-creates via
 * Custom… + Save if they want to change a preset's dims (re-saving
 * with the same name replaces by the Phase H duplicate-name policy).
 *
 * Surfaced from the Output Size menu's "Manage Sizes…" entry when
 * `AppSettings.shared.customPresets` is non-empty.
 */

import SwiftUI
import GlEncCore

struct ManageSizesSheet: View {
    @ObservedObject var settings: AppSettings
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 32))
                    .foregroundColor(.accentColor)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Manage saved sizes")
                        .font(.headline)
                    Text("Delete a preset to remove it from the Output Size menu. Re-save a name from the Custom… sheet to replace its dimensions.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if settings.customPresets.isEmpty {
                Text("No saved sizes yet.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(settings.customPresets) { preset in
                            HStack(spacing: 8) {
                                Text(preset.displayLabel)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button {
                                    settings.removeCustomPreset(id: preset.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Delete this saved size")
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 220)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1))
            }

            HStack {
                Spacer()
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
