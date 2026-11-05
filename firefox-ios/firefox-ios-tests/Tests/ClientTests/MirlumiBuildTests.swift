// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Shared
import UIKit
import XCTest

@testable import Client

final class MirlumiBuildTests: XCTestCase {
    func testMozillaServicesStayOff() {
        XCTAssertFalse(MirlumiBuild.sendsTelemetry)
        XCTAssertFalse(MirlumiBuild.sendsCrashReports)
        XCTAssertFalse(MirlumiBuild.reportsInstallAttribution)
        XCTAssertFalse(MirlumiBuild.usesRemoteConfiguration)
        XCTAssertFalse(MirlumiBuild.usesFirefoxAccounts)
        XCTAssertFalse(MirlumiBuild.usesPushNotifications)
        XCTAssertFalse(MirlumiBuild.showsSponsoredContent)
        XCTAssertFalse(MirlumiBuild.showsMarketingMessages)
        XCTAssertFalse(MirlumiBuild.showsDebugMenu)
    }

    func testSettingsAreBehindTheParentsPIN() {
        XCTAssertTrue(MirlumiBuild.settingsLockEnabled)
    }

    func testSettingsOpenOnMirlumisOwnSettings() {
        XCTAssertTrue(MirlumiBuild.settingsScreenEnabled)
    }

    func testDuckDuckGoSearchesUseStrictSafeSearch() {
        XCTAssertTrue(MirlumiBuild.safeSearchEnabled)
    }

    func testOnlyAllowedSitesOpen() {
        XCTAssertTrue(MirlumiBuild.allowlistEnabled)
    }

    func testContentRulesAreOn() {
        XCTAssertTrue(MirlumiBuild.contentRulesEnabled)
    }

    func testImageCheckIsOn() {
        XCTAssertTrue(MirlumiBuild.imageCheckEnabled)
    }

    func testOpenModeWithThePageClassifierIsOffered() {
        XCTAssertTrue(MirlumiBuild.pageClassifierEnabled)
    }

    func testIdentity() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertEqual(Bundle.main.bundleIdentifier, "app.mirlumi.browser.dev")
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "Mirlumi Browser")
        XCTAssertEqual(info["MozPublicURLScheme"] as? String, "mirlumi")
        XCTAssertEqual(info["MozInternalURLScheme"] as? String, "mirlumi-dev")
        XCTAssertEqual(AppInfo.sharedContainerIdentifier, "group.app.mirlumi.browser.dev")
        XCTAssertEqual(AppName.shortName.rawValue, "Mirlumi")
    }

    func testInfoPlistHoldsNoServiceEndpointsOrKeys() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        for key in ["AttributionCopyEndpoint", "NSAdvertisingAttributionReportEndpoint", "SKAdNetworkItems",
                    "NimbusURL", "SentryCloudDSN", "PocketEnvironmentAPIKey", "LiteLLMAPIKey",
                    "LiteLLMAPIEndpoint", "MozWallpaperURLScheme"] {
            XCTAssertNil(info[key], key)
        }
    }

    func testServiceFeaturesCannotBeEnabled() {
        let layer = NimbusFeatureFlagLayer()
        let prefs = MockProfilePrefs()
        for flag in NimbusFeatureFlagLayer.disabledInMirlumi {
            if let debugKey = flag.debugKey {
                prefs.setBool(true, forKey: debugKey)
            }
            XCTAssertFalse(layer.checkNimbusConfigFor(flag, with: prefs), flag.rawValue)
        }
    }

    func testBuiltInSearchEngines() {
        let engines = MirlumiSearchEngines.bundled(languageCode: "en")
        XCTAssertEqual(engines.map(\.shortName), ["DuckDuckGo", "Google", "Bing", "Wikipedia"])
        for engine in engines {
            XCTAssertNil(engine.partners, engine.shortName)
            XCTAssertFalse(engine.searchTemplate.contains(OpenSearchEngine.partnerCodeComponent), engine.shortName)
            XCTAssertFalse(engine.isCustomEngine, engine.shortName)
        }
    }

    func testDuckDuckGoIsTheOnlySearchEngine() throws {
        XCTAssertTrue(MirlumiBuild.onlyDuckDuckGoEnabled)
        XCTAssertFalse(MirlumiSearchEngines.allowsCustomEngines)

        let bundled = MirlumiSearchEngines.bundled(languageCode: "en")
        let custom = OpenSearchEngine(engineID: "ddg",
                                      shortName: "Custom",
                                      telemetrySuffix: nil,
                                      image: UIImage(),
                                      searchTemplate: "https://example.com/?q={searchTerms}",
                                      suggestTemplate: nil,
                                      isCustomEngine: true)
        let allowed = MirlumiSearchEngines.allowed([custom] + bundled)
        XCTAssertEqual(allowed.map(\.shortName), ["DuckDuckGo"])
        // Google Lens is only offered while Google is the default engine.
        XCTAssertFalse(try XCTUnwrap(allowed.first).isGoogleEngine)
        XCTAssertEqual(MirlumiSearchEngines.allowed(bundled, onlyDuckDuckGo: false).count, bundled.count)
    }

    func testSlovenianSearchUsesSlovenianWikipedia() throws {
        let wikipedia = try XCTUnwrap(MirlumiSearchEngines.definitions(languageCode: "sl-SI").last)
        XCTAssertTrue(wikipedia.searchTemplate.hasPrefix("https://sl.wikipedia.org/"))
    }

    func testProductLinksStayOnMirlumiDomains() throws {
        let links = [SupportUtils.URLForGetHelp, SupportUtils.URLForTermsOfUse, SupportUtils.URLForPrivacyNotice,
                     SupportUtils.URLForTopic("anything")]
        for link in links {
            let host = try XCTUnwrap(try XCTUnwrap(link).host)
            XCTAssertTrue(["mirlumi.com", "mirlumi.si"].contains(host), host)
        }
    }
}
