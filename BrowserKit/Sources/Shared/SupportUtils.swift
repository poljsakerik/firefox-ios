// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation
import UIKit

/// Utility functions related to SUMO and Webcompat
public struct SupportUtils {
    private static func mirlumiPage(_ path: String) -> URL? {
        let isSlovenian = Locale.preferredLanguages.first?.hasPrefix("sl") ?? false
        return URL(string: "https://\(isSlovenian ? "mirlumi.si" : "mirlumi.com")/\(path)")
    }

    private static var mirlumiSupport: URL? { mirlumiPage("podpora.html") }

    public static var URLForPrivateBrowsingLearnMore: URL? {
        return mirlumiSupport
    }

    public static var URLForGetHelp: URL? {
        return mirlumiSupport
    }

    public static var URLForPocketLearnMore: URL? {
        return mirlumiSupport
    }

    public static var URLForTermsOfUse: URL? {
        return mirlumiPage("pravno-obvestilo.html")
    }

    public static var URLForPrivacyNotice: URL? {
        return mirlumiPage("politika-zasebnosti.html")
    }

    public static var URLForUpdatedPrivacyNotice: URL? {
        return mirlumiPage("politika-zasebnosti.html")
    }

    public static var URLForUpdatedPrivacyNoticeDiff: URL? {
        return mirlumiPage("politika-zasebnosti.html")
    }

    public static var URLForRelayAccountManagement: URL? {
        return mirlumiSupport
    }

    public static var URLForRelayMaskLearnMoreArticle: URL? {
        return mirlumiSupport
    }

    public static var URLForConnectionNotSecureLearnMore: URL? {
        return mirlumiSupport
    }

    public static func URLForTopic(_ topic: String, useMobilePath: Bool = true) -> URL? {
        if !MirlumiBuild.usesRemoteConfiguration { return mirlumiSupport }

        // Construct a NSURL pointing to a specific topic on SUMO. The topic should be a non-escaped string. It will
        // be properly escaped by this function.
        //
        // The resulting NSURL will include the app version, operating system and locale code. For example, a topic
        // "cheese" will be turned into a link that looks like https://support.mozilla.org/1/mobile/2.0/iOS/en-US/cheese
        guard let escapedTopic = topic.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let languageIdentifier = Locale.preferredLanguages.first
        else {
            return nil
        }
        let productPath = useMobilePath ? "mobile" : "firefox"
        return URL(string: "https://support.mozilla.org/1/\(productPath)/\(AppInfo.appVersion)/iOS/\(languageIdentifier)/\(escapedTopic)")
    }

    public static func URLForPrivacyNotice(source: String, campaign: String, content: String?) -> URL? {
        let defaultURL = URL(string: "https://www.mozilla.org/privacy/firefox")

        guard let languageIdentifier = Locale.preferredLanguages.first else {
            return defaultURL
        }

        var privacyNoticeString =
                    "https://www.mozilla.org/\(languageIdentifier)/privacy/firefox/?utm_medium=firefox-mobile&utm_source=\(source)&utm_campaign=\(campaign)"

        if let content {
            privacyNoticeString.append("&utm_content=\(content)")
        }

        return URL(string: privacyNoticeString) ?? defaultURL
    }
}
