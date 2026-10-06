import Foundation

// Compile the setup guide's launch decision without launching the app:
// xcrun swiftc -module-cache-path /tmp/framecho-onboarding-module-cache \
//   Screendrop/OnboardingLaunch.swift scripts/check-onboarding-launch.swift \
//   -o /tmp/framecho-onboarding-check && /tmp/framecho-onboarding-check
@main
struct OnboardingLaunchChecks {
    static var checks = 0

    static func expect(
        completed: Bool, resuming: Bool, granted: Bool,
        _ expected: OnboardingLaunch.Decision, _ message: String
    ) {
        checks += 1
        let actual = OnboardingLaunch.decision(
            isCompleted: completed, isResuming: resuming, isScreenRecordingGranted: granted
        )
        precondition(actual == expected, "\(message): expected \(expected), got \(actual)")
    }

    static func main() {
        // A new Mac: the guide opens from the start.
        expect(completed: false, resuming: false, granted: false, .show(.welcome), "First launch")

        // An update from a version without the guide, already allowed:
        // nothing to explain, so it's remembered as done.
        expect(completed: false, resuming: false, granted: true, .markCompleted, "Update with access")

        // Relaunched to apply a grant: back to the permissions page, whether
        // or not the grant took, so the ready page isn't skipped.
        expect(completed: false, resuming: true, granted: true, .show(.permissions), "Relaunched after granting")
        expect(completed: false, resuming: true, granted: false, .show(.permissions), "Relaunched without the grant")

        // Finished or dismissed: never again on its own.
        for resuming in [false, true] {
            for granted in [false, true] {
                expect(completed: true, resuming: resuming, granted: granted, .none,
                       "Completed (resuming: \(resuming), granted: \(granted))")
            }
        }

        precondition(OnboardingPage.allCases == [.welcome, .permissions, .ready], "The guide's pages, in order")
        checks += 1

        print("Onboarding launch checks passed (\(checks) assertions).")
    }
}
