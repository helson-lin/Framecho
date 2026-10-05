//
//  OnboardingLaunch.swift
//  Screendrop
//
//  Whether a launch opens the setup guide, and on which page, decided from
//  what's remembered and what macOS allows. Checked by
//  scripts/check-onboarding-launch.swift.
//

import Foundation

nonisolated enum OnboardingPage: Hashable, CaseIterable {
    case welcome
    case permissions
    case ready
}

nonisolated enum OnboardingLaunch {
    enum Decision: Equatable {
        /// The guide was finished or dismissed before.
        case none
        /// Never seen, but Screen Recording is already allowed: an update
        /// from a version without the guide. Remember it as done.
        case markCompleted
        case show(OnboardingPage)
    }

    /// - Parameters:
    ///   - isResuming: The guide opened before and wasn't finished, most
    ///     likely because a new grant needed a relaunch.
    static func decision(isCompleted: Bool, isResuming: Bool, isScreenRecordingGranted: Bool) -> Decision {
        if isCompleted { return .none }
        if isResuming { return .show(.permissions) }
        if isScreenRecordingGranted { return .markCompleted }
        return .show(.welcome)
    }
}
