import AppKit
import Carbon.HIToolbox
import SwiftUI

// Compile the capture shortcuts and their stored preferences without
// launching the app:
// xcrun swiftc -module-cache-path /tmp/framecho-hotkeys-module-cache \
//   Framecho/CaptureHotkeys.swift scripts/check-hotkeys.swift \
//   -o /tmp/framecho-hotkeys-check && /tmp/framecho-hotkeys-check
@main
struct HotkeyChecks {
    static var checks = 0

    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        precondition(condition, message)
    }

    static func main() {
        checkModifiers()
        checkDisplay()
        checkMenuEquivalents()
        checkActions()
        checkPreferences()
        print("Hotkey checks passed (\(checks) assertions).")
    }

    static func shortcut(_ modifiers: HotkeyShortcut.Modifiers, _ keyCode: Int) -> HotkeyShortcut {
        HotkeyShortcut(modifiers: modifiers, keyCode: keyCode)
    }

    static func checkModifiers() {
        let all = HotkeyShortcut.Modifiers(from: [.command, .option, .control, .shift, .capsLock, .function])
        expect(all == [.command, .option, .control, .shift], "Only the four shortcut modifiers are kept")
        expect(HotkeyShortcut.Modifiers(from: []).isEmpty, "No modifiers")

        // Carbon wants its own flags; a wrong mapping registers a different shortcut.
        expect(HotkeyShortcut.Modifiers.command.carbonEventModifiers == UInt32(cmdKey), "⌘ maps to cmdKey")
        expect(HotkeyShortcut.Modifiers.option.carbonEventModifiers == UInt32(optionKey), "⌥ maps to optionKey")
        expect(HotkeyShortcut.Modifiers.control.carbonEventModifiers == UInt32(controlKey), "⌃ maps to controlKey")
        expect(HotkeyShortcut.Modifiers.shift.carbonEventModifiers == UInt32(shiftKey), "⇧ maps to shiftKey")
        expect(all.carbonEventModifiers == UInt32(cmdKey | optionKey | controlKey | shiftKey), "Combined")

        expect(all.eventModifiers == [.command, .option, .control, .shift], "SwiftUI modifiers")
        expect(!shortcut([], kVK_ANSI_3).isValid, "A bare key can't be a global shortcut")
        expect(shortcut(.shift, kVK_ANSI_3).isValid, "Any modifier makes it valid")
    }

    static func checkDisplay() {
        // macOS orders modifiers ⌃ ⌥ ⇧ ⌘ whatever order they were pressed in.
        let chord = shortcut([.command, .shift, .option, .control], kVK_ANSI_K)
        expect(chord.displayTokens == ["⌃", "⌥", "⇧", "⌘", "K"], "Modifier order: \(chord.displayTokens)")
        expect(chord.displayString == "⌃ ⌥ ⇧ ⌘ K", "Display string")
        expect(shortcut(.option, kVK_ANSI_3).displayTokens == ["⌥", "3"], "⌥3")

        let labels: [(Int, String)] = [
            (kVK_Return, "↩"), (kVK_Tab, "⇥"), (kVK_Delete, "⌫"), (kVK_ForwardDelete, "⌦"),
            (kVK_Escape, "⎋"), (kVK_LeftArrow, "←"), (kVK_RightArrow, "→"), (kVK_UpArrow, "↑"),
            (kVK_DownArrow, "↓"), (kVK_F1, "F1"), (kVK_F12, "F12"), (kVK_ANSI_Minus, "-"),
            (kVK_ANSI_Slash, "/"), (kVK_ANSI_0, "0"), (kVK_ANSI_Z, "Z"),
        ]
        for (keyCode, label) in labels {
            expect(shortcut(.command, keyCode).displayTokens.last == label, "Key \(keyCode) shows as \(label)")
        }
        expect(!(shortcut(.command, 0xFF).displayTokens.last ?? "").isEmpty, "An unknown key still shows something")
    }

    static func checkMenuEquivalents() {
        // The menu bar shows each active global shortcut.
        expect(shortcut(.option, kVK_ANSI_3).keyboardShortcut?.key == "3", "Digit")
        expect(shortcut(.option, kVK_ANSI_3).keyboardShortcut?.modifiers == .option, "Its modifiers")
        expect(shortcut(.command, kVK_ANSI_K).keyboardShortcut?.key == "k", "Letters are lower case")
        expect(shortcut(.command, kVK_Return).keyboardShortcut?.key == .return, "Return")
        expect(shortcut(.command, kVK_LeftArrow).keyboardShortcut?.key == .leftArrow, "Arrow")
        let f5 = shortcut(.command, kVK_F5).keyboardShortcut?.key.character
        expect(f5 == Character(UnicodeScalar(NSF5FunctionKey)!), "Function key")
        expect(shortcut(.command, 0xFF).keyboardShortcut == nil, "An unknown key has no menu equivalent")
    }

    static func checkActions() {
        let actions = CaptureHotkeyAction.allCases
        // Registered with Carbon by ID: changing one breaks the binding.
        expect(actions.map(\.hotKeyID) == [1, 2, 3, 4, 5, 6, 7, 8], "Hotkey IDs: \(actions.map(\.hotKeyID))")
        for action in actions {
            expect(CaptureHotkeyAction(hotKeyID: action.hotKeyID) == action, "\(action) is found by its ID")
            expect(!action.title.isEmpty, "\(action) has a title")
            expect(action.defaultShortcut.isValid, "\(action)'s default is a valid shortcut")
        }
        expect(CaptureHotkeyAction(hotKeyID: 0) == nil && CaptureHotkeyAction(hotKeyID: 99) == nil, "Unknown IDs")

        let defaults = actions.map(\.defaultShortcut)
        expect(Set(defaults).count == defaults.count, "No two actions share a default shortcut")
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8]
        expect(defaults == digits.map { shortcut(.option, $0) }, "Defaults are ⌥1 through ⌥8")

        // Users' saved shortcuts live under these names.
        let keys = [
            "captureHotkey.fullscreen", "captureHotkey.window", "captureHotkey.area",
            "captureHotkey.screenRecording", "captureHotkey.textCapture", "captureHotkey.timedCapture",
            "captureHotkey.pinArea", "captureHotkey.pinLatest",
        ]
        expect(actions.map(\.preferencesKey) == keys, "Preference keys: \(actions.map(\.preferencesKey))")
    }

    static func checkPreferences() {
        let suite = "framecho.check-hotkeys.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        for action in CaptureHotkeyAction.allCases {
            expect(CaptureHotkeyPreferences.shortcut(for: action, defaults: defaults) == action.defaultShortcut,
                   "Nothing saved: \(action) uses its default")
        }

        let custom = shortcut([.command, .shift], kVK_ANSI_A)
        CaptureHotkeyPreferences.saveShortcut(custom, for: .area, defaults: defaults)
        expect(CaptureHotkeyPreferences.shortcut(for: .area, defaults: defaults) == custom, "A custom shortcut is kept")
        expect(defaults.data(forKey: "captureHotkey.area") != nil, "…under its preference key")
        expect(CaptureHotkeyPreferences.shortcut(for: .window, defaults: defaults) == CaptureHotkeyAction.window.defaultShortcut,
               "Other actions are unaffected")

        CaptureHotkeyPreferences.saveShortcut(CaptureHotkeyAction.area.defaultShortcut, for: .area, defaults: defaults)
        expect(defaults.object(forKey: "captureHotkey.area") == nil,
               "Saving the default clears the override, so a future default change applies")

        defaults.set(Data("not json".utf8), forKey: "captureHotkey.fullscreen")
        expect(CaptureHotkeyPreferences.shortcut(for: .fullscreen, defaults: defaults) == CaptureHotkeyAction.fullscreen.defaultShortcut,
               "A damaged preference falls back to the default")
        defaults.set(try! JSONEncoder().encode(shortcut([], kVK_ANSI_F)), forKey: "captureHotkey.fullscreen")
        expect(CaptureHotkeyPreferences.shortcut(for: .fullscreen, defaults: defaults) == CaptureHotkeyAction.fullscreen.defaultShortcut,
               "A saved shortcut without modifiers falls back to the default")

        // Conflicts are found against what's actually in effect.
        CaptureHotkeyPreferences.saveShortcut(custom, for: .window, defaults: defaults)
        expect(CaptureHotkeyPreferences.conflictingAction(for: custom, excluding: .area, defaults: defaults) == .window,
               "A custom shortcut in use is a conflict")
        expect(CaptureHotkeyPreferences.conflictingAction(for: custom, excluding: .window, defaults: defaults) == nil,
               "An action never conflicts with itself")
        expect(CaptureHotkeyPreferences.conflictingAction(
            for: CaptureHotkeyAction.textCapture.defaultShortcut, excluding: .area, defaults: defaults
        ) == .textCapture, "A default in use is a conflict")
        expect(CaptureHotkeyPreferences.conflictingAction(
            for: CaptureHotkeyAction.window.defaultShortcut, excluding: .area, defaults: defaults
        ) == nil, "A default no longer in use is free")

        let all = CaptureHotkeyPreferences.shortcuts(defaults: defaults)
        expect(all.count == CaptureHotkeyAction.allCases.count && all[.window] == custom, "Every action's shortcut at once")

        // Stored as JSON; the shape must not change under existing users.
        let stored = String(data: try! JSONEncoder().encode(custom), encoding: .utf8)!
        let decoded = try! JSONDecoder().decode(HotkeyShortcut.self, from: Data(#"{"modifiers":9,"keyCode":0}"#.utf8))
        expect(decoded == custom, "A shortcut saved by an earlier build reads back: \(stored)")
    }
}
