// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

/// The Mozilla-operated services this build leaves off. Each switch is read where the service starts,
/// so turning one on is a deliberate, reviewable change.
public enum MirlumiBuild {
    public static let sendsTelemetry = false
    public static let sendsCrashReports = false
    public static let reportsInstallAttribution = false
    public static let usesRemoteConfiguration = false
    public static let usesFirefoxAccounts = false
    public static let usesPushNotifications = false
    public static let showsSponsoredContent = false
    public static let showsMarketingMessages = false
    public static let showsDebugMenu = false

    /// Mirlumi's own features, from MirlumiKit.
    /// The settings lock keeps Settings, and everything else that changes the browser, behind a parent's PIN.
    public static let settingsLockEnabled = true
}
