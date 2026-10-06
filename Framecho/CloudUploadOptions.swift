//
//  CloudUploadOptions.swift
//  Framecho
//
//  The title offered right before a manual cloud upload, plus the
//  remembered image upload preferences. Auto-upload (after-capture, no
//  user interaction) skips the popover and lets the worker pick the title.
//

import SwiftUI

struct CloudUploadOptions: Sendable {
    var title: String

    /// `nil` title means "let the worker fall back to the filename (or,
    /// for recordings, the auto-generated 'Screen Recording - …' title)".
    var trimmedTitleOrNil: String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum CloudUploadPreferences {
    static let imageFormatKey = "cloudUploadImageFormat"
    static let imageQualityKey = "cloudUploadImageQuality"
    static let downscalesRetinaImagesKey = "cloudUploadDownscalesRetinaImages"
    static let defaultImageQuality = 0.8

    /// AVIF unless the user chose to upload originals.
    static var imageFormat: CloudImageUploadFormat {
        UserDefaults.standard.string(forKey: imageFormatKey)
            .flatMap(CloudImageUploadFormat.init(rawValue:)) ?? .avif
    }

    static var imageQuality: Double {
        let value = UserDefaults.standard.object(forKey: imageQualityKey) as? Double ?? defaultImageQuality
        return min(max(value, 0.1), 1)
    }

    static var downscalesRetinaImages: Bool {
        UserDefaults.standard.bool(forKey: downscalesRetinaImagesKey)
    }
}

/// Small popover form shown from an upload/share button: a title field,
/// prefilled with a suggested default and editable.
struct CloudUploadOptionsPopover: View {
    let suggestedTitle: String
    let onConfirm: (CloudUploadOptions) -> Void

    @State private var title: String
    @Environment(\.dismiss) private var dismiss

    init(suggestedTitle: String = "", onConfirm: @escaping (CloudUploadOptions) -> Void) {
        self.suggestedTitle = suggestedTitle
        self.onConfirm = onConfirm
        _title = State(initialValue: suggestedTitle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Share Options")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Title")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Title", text: $title, prompt: Text("Untitled"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Upload") {
                    let options = CloudUploadOptions(title: title)
                    dismiss()
                    onConfirm(options)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}

/// Wraps any trigger content in a button that opens `CloudUploadOptionsPopover`
/// before firing `onUpload`. Drop-in replacement for a plain
/// `Button(action: onUpload) { ... }` at a manual upload/share call site.
struct CloudUploadButton<Label: View>: View {
    let suggestedTitle: String
    let onUpload: (CloudUploadOptions) -> Void
    @ViewBuilder let label: () -> Label

    @State private var showingOptions = false

    var body: some View {
        Button {
            showingOptions = true
        } label: {
            label()
        }
        .popover(isPresented: $showingOptions, arrowEdge: .bottom) {
            CloudUploadOptionsPopover(suggestedTitle: suggestedTitle, onConfirm: onUpload)
        }
    }
}
