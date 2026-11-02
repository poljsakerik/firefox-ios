// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation
import Shared
import Glean
import MozillaAppServices
import OnboardingKit

struct Links {
    static let termsOfService = "https://www.mozilla.org/about/legal/terms/firefox/"
    static let privacyNotice = "https://www.mozilla.org/privacy/firefox/"
}

struct TermsOfServiceManager: FeatureFlaggable, Sendable {
    var prefs: Prefs

    init(prefs: Prefs) {
        self.prefs = prefs
    }

    var isFeatureEnabled: Bool {
        featureFlagsProvider.isEnabled(.tosFeature)
    }

    var isAccepted: Bool {
        prefs.boolForKey(PrefsKeys.TermsOfUseAccepted) ?? false
    }

    var shouldShowScreen: Bool {
        guard featureFlagsProvider.isEnabled(.tosFeature) else { return false }
        return prefs.boolForKey(PrefsKeys.TermsOfUseAccepted) == nil
    }

    func setAccepted(acceptedDate: Date) {
        prefs.setBool(true, forKey: PrefsKeys.TermsOfUseAccepted)
        prefs.setTimestamp(acceptedDate.toTimestamp(), forKey: PrefsKeys.TermsOfUseAcceptedDate)
    }

    func shouldSendTechnicalData(telemetryValue: Bool, studiesValue: Bool) {
        guard MirlumiBuild.sendsTelemetry else { return }

        DefaultGleanWrapper().setUpload(isEnabled: telemetryValue)
        Experiments.setStudiesSetting(studiesValue)
        Experiments.setTelemetrySetting(telemetryValue)
    }

    // MARK: - Terms of Use Configuration

    static var brandRefreshTermsOfUseConfiguration: OnboardingKitCardInfoModel {
        return OnboardingKitCardInfoModel(
            cardType: .basic,
            name: "tos",
            order: 20,
            title: String(format: .Onboarding.TermsOfService.Title, AppName.shortName.rawValue),
            body: String.Mirlumi.OnboardingWelcomeBody,
            buttons: OnboardingButtons(
                primary: OnboardingButtonInfoModel(
                    title: String.Onboarding.Modern.BrandRefresh.TermsOfUse.AgreementButtonTitleV2,
                    action: OnboardingActions.endOnboarding
                )
            ),
            multipleChoiceButtons: [],
            onboardingType: .freshInstall,
            a11yIdRoot: AccessibilityIdentifiers.TermsOfService.root,
            imageID: ImageIdentifiers.homeHeaderLogoBall,
            embededLinkText: []
        )
    }
}
