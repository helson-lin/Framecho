//
//  SettingsShortcutsPane.swift
//  Framecho
//

import AppKit
import SwiftUI

/// Groups the global shortcuts the way the capture menu does.
private enum CaptureHotkeyGroup: CaseIterable, Identifiable {
    case screenshots
    case pinning
    case recording

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .screenshots: "Screenshots"
        case .pinning: "Pinning"
        case .recording: "Screen Recording"
        }
    }

    var actions: [CaptureHotkeyAction] {
        switch self {
        case .screenshots: [.fullscreen, .window, .area, .textCapture, .timedCapture]
        case .pinning: [.pinArea, .pinLatest]
        case .recording: [.screenRecording]
        }
    }
}

/// A problem with one action's shortcut, shown on that action's row.
private struct ShortcutIssue: Equatable {
    let action: CaptureHotkeyAction
    let message: String
}

struct ShortcutsSettingsPane: View {
    @State private var shortcuts = CaptureHotkeyPreferences.shortcuts()
    @State private var recorder = HotkeyShortcutRecorder()
    @State private var recordingAction: CaptureHotkeyAction?
    @State private var issue: ShortcutIssue?

    private var hasCustomShortcuts: Bool {
        CaptureHotkeyAction.allCases.contains { shortcut(for: $0) != $0.defaultShortcut }
    }

    var body: some View {
        Form {
            ForEach(CaptureHotkeyGroup.allCases) { group in
                Section {
                    ForEach(group.actions) { action in
                        row(for: action)
                    }
                } header: {
                    Text(group.title)
                } footer: {
                    if group == CaptureHotkeyGroup.allCases.last {
                        HStack {
                            Spacer()
                            Button("Restore All Defaults") { restoreAllDefaults() }
                                .disabled(!hasCustomShortcuts)
                        }
                    }
                }
            }
        }
        .settingsFormStyle()
        .onAppear {
            reloadShortcuts()
            configureRecorder()
        }
        .onDisappear {
            recorder.stop()
            recordingAction = nil
        }
    }

    private func row(for action: CaptureHotkeyAction) -> some View {
        let current = shortcut(for: action)
        let message = issue?.action == action
            ? issue?.message
            : HotkeyManager.shared.registrationErrors[action]

        return LabeledContent {
            HStack(spacing: 6) {
                Group {
                    if current != action.defaultShortcut {
                        Button {
                            resetShortcut(for: action)
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(String(localized: "Restore Default (\(action.defaultShortcut.displayString))"))
                        .accessibilityLabel(String(localized: "Restore \(action.title) to \(action.defaultShortcut.displayString)"))
                    }
                }
                .frame(width: 20)

                ShortcutRecorderField(
                    title: action.title,
                    shortcut: current,
                    isRecording: isRecording(action),
                    hasIssue: message != nil
                ) {
                    toggleRecording(for: action)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(action.title)
                if let message {
                    SettingsIssueText(message)
                }
            }
        }
    }

    private func shortcut(for action: CaptureHotkeyAction) -> HotkeyShortcut {
        shortcuts[action] ?? action.defaultShortcut
    }

    private func isRecording(_ action: CaptureHotkeyAction) -> Bool {
        recorder.isRecording && recordingAction == action
    }

    private func toggleRecording(for action: CaptureHotkeyAction) {
        issue = nil

        if isRecording(action) {
            recorder.stop()
            recordingAction = nil
            return
        }

        recordingAction = action
        recorder.start()
    }

    private func resetShortcut(for action: CaptureHotkeyAction) {
        recorder.stop()
        recordingAction = nil
        apply(action.defaultShortcut, to: action)
    }

    /// Restores every action, retrying the ones whose default is still held by
    /// another action until a pass makes no progress (e.g. two swapped keys).
    private func restoreAllDefaults() {
        recorder.stop()
        recordingAction = nil
        issue = nil

        var pending = CaptureHotkeyAction.allCases.filter { shortcut(for: $0) != $0.defaultShortcut }
        var lastError: (CaptureHotkeyAction, Error)?
        while !pending.isEmpty {
            let remaining = pending.filter { action in
                do {
                    try HotkeyManager.shared.setShortcut(action.defaultShortcut, for: action)
                    return false
                } catch {
                    lastError = (action, error)
                    return true
                }
            }
            if remaining.count == pending.count { break }
            pending = remaining
        }
        reloadShortcuts()

        if let (action, error) = lastError, !pending.isEmpty {
            issue = ShortcutIssue(action: action, message: error.localizedDescription)
            NSSound.beep()
        }
    }

    private func configureRecorder() {
        recorder.onShortcutRecorded = { shortcut in
            guard let recordingAction else { return }
            apply(shortcut, to: recordingAction)
        }

        recorder.onCancel = {
            recordingAction = nil
        }
    }

    private func apply(_ shortcut: HotkeyShortcut, to action: CaptureHotkeyAction) {
        defer { recordingAction = nil }

        if let conflict = CaptureHotkeyPreferences.conflictingAction(for: shortcut, excluding: action) {
            issue = ShortcutIssue(
                action: action,
                message: String(localized: "\(shortcut.displayString) is already assigned to \(conflict.title). Your previous shortcut has been kept.")
            )
            NSSound.beep()
            recorder.stop()
            return
        }

        do {
            try HotkeyManager.shared.setShortcut(shortcut, for: action)
            shortcuts[action] = shortcut
            issue = nil
        } catch {
            issue = ShortcutIssue(
                action: action,
                message: String(localized: "\(error.localizedDescription) Your previous shortcut has been kept.")
            )
            NSSound.beep()
        }
    }

    private func reloadShortcuts() {
        shortcuts = CaptureHotkeyPreferences.shortcuts()
    }
}

/// The shortcut itself is the control: click it, then press the new keys.
private struct ShortcutRecorderField: View {
    let title: String
    let shortcut: HotkeyShortcut
    let isRecording: Bool
    let hasIssue: Bool
    let action: () -> Void

    private let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)

    var body: some View {
        Button(action: action) {
            Group {
                if isRecording {
                    Text("Press keys…")
                        .font(.caption)
                        .foregroundStyle(.tint)
                } else {
                    HotkeyShortcutDisplay(shortcut: shortcut)
                }
            }
            .frame(width: 112, height: 24)
            .background(Color(nsColor: .controlBackgroundColor), in: shape)
            .overlay {
                shape.strokeBorder(borderStyle, lineWidth: isRecording ? 2 : 1)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(isRecording ? String(localized: "Press Esc to cancel.") : String(localized: "Click to record a new shortcut."))
        .accessibilityLabel(title)
        .accessibilityValue(isRecording ? String(localized: "Recording") : shortcut.displayString)
        .accessibilityHint(String(localized: "Click to record a new shortcut."))
    }

    private var borderStyle: AnyShapeStyle {
        if isRecording { return AnyShapeStyle(.tint) }
        if hasIssue { return AnyShapeStyle(.orange) }
        return AnyShapeStyle(.separator)
    }
}

struct HotkeyShortcutDisplay: View {
    let shortcut: HotkeyShortcut

    var body: some View {
        HStack(spacing: 3) {
            ForEach(shortcut.displayTokens, id: \.self) { token in
                HotkeyKeyCap(token: token)
            }
        }
        // Expose the shortcut as one static text element. A label on the bare
        // HStack is pushed onto each key cap Text, and on macOS 27 SwiftUI
        // recurses reading it back when an accessibility client inspects
        // Settings, crashing the app.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(shortcut.displayString)
    }
}

private struct HotkeyKeyCap: View {
    let token: String

    var body: some View {
        Text(token)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary)
            .monospacedDigit()
            .frame(minWidth: 22, minHeight: 21)
            .padding(.horizontal, token.count > 1 ? 6 : 0)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.separator.opacity(0.35))
            }
    }
}
