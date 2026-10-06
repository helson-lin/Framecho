import Foundation

// Compile the permission catalogue and its rules without launching the app:
// xcrun swiftc -module-cache-path /tmp/framecho-permissions-module-cache \
//   Screendrop/AppPermission.swift scripts/check-app-permissions.swift \
//   -o /tmp/framecho-permissions-check && /tmp/framecho-permissions-check
@main
struct AppPermissionChecks {
    static var checks = 0

    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        precondition(condition, message)
    }

    static func main() {
        checkCatalogue()
        checkScreenRecordingStatus()
        checkRelaunchSuggestion()
        print("App permission checks passed (\(checks) assertions).")
    }

    static func checkCatalogue() {
        let all = AppPermission.allCases
        expect(Set(all.map(\.rawValue)).count == all.count, "Permission ids are unique")
        expect(all.filter(\.isRequired) == [.screenRecording], "Only Screen Recording is required")
        expect(all.first == .screenRecording, "The required permission is listed first")
        expect(Set(all.filter(\.needsRelaunchAfterGrant)) == [.screenRecording, .inputMonitoring],
               "Only the grants macOS applies on relaunch ask for one")

        for permission in all {
            expect(!permission.title.isEmpty, "\(permission) has a title")
            expect(!permission.purpose.isEmpty, "\(permission) says what it's for")
            expect(!permission.systemImage.isEmpty, "\(permission) has an icon")
            let url = permission.settingsURL
            expect(url?.scheme == "x-apple.systempreferences", "\(permission) opens System Settings: \(String(describing: url))")
        }
        expect(Set(all.compactMap { $0.settingsURL?.absoluteString }).count == all.count,
               "Each permission opens its own pane")
    }

    static func checkScreenRecordingStatus() {
        typealias Rules = AppPermissionRules
        expect(Rules.screenRecordingStatus(isGranted: true, wasRequested: false) == .granted, "Granted without asking")
        expect(Rules.screenRecordingStatus(isGranted: true, wasRequested: true) == .granted, "Granted after asking")
        // macOS shows its prompt once; after that only System Settings helps.
        expect(Rules.screenRecordingStatus(isGranted: false, wasRequested: false) == .notDetermined,
               "Never asked: the prompt is still available")
        expect(Rules.screenRecordingStatus(isGranted: false, wasRequested: true) == .denied,
               "Asked and not granted: send to System Settings")
    }

    static func checkRelaunchSuggestion() {
        func suggested(_ sent: Set<AppPermission>, _ statuses: [AppPermission: AppPermissionStatus]) -> Bool {
            AppPermissionRules.isRelaunchSuggested(sentToSettings: sent) { statuses[$0] ?? .notDetermined }
        }

        expect(!suggested([], [:]), "Nothing sent to System Settings, nothing to apply")
        expect(suggested([.screenRecording], [.screenRecording: .denied]),
               "Screen Recording possibly turned on in System Settings")
        expect(!suggested([.screenRecording], [.screenRecording: .granted]),
               "Already in effect: no relaunch")
        expect(suggested([.inputMonitoring], [.inputMonitoring: .notDetermined]),
               "Input Monitoring also applies on relaunch")
        // Microphone, camera and notifications apply at once.
        expect(!suggested([.microphone, .camera, .notifications],
                          [.microphone: .denied, .camera: .denied, .notifications: .denied]),
               "Grants that apply at once never suggest a relaunch")
        expect(suggested([.microphone, .screenRecording], [.microphone: .denied, .screenRecording: .denied]),
               "One pending relaunch grant is enough")
    }
}
