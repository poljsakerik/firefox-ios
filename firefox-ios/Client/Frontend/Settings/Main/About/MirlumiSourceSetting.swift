// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation
import Shared

/// States that this build derives from Firefox and opens its published source.
class MirlumiSourceSetting: Setting {
    override var title: NSAttributedString? {
        guard let theme else { return nil }
        return NSAttributedString(string: String(format: .Mirlumi.BasedOnFirefoxTitle, AppInfo.displayName),
                                  attributes: [NSAttributedString.Key.foregroundColor: theme.colors.textPrimary])
    }

    override var status: NSAttributedString? {
        guard let theme else { return nil }
        return NSAttributedString(string: .Mirlumi.SourceCodeStatus,
                                  attributes: [NSAttributedString.Key.foregroundColor: theme.colors.textSecondary])
    }

    override var url: URL? {
        return URL(string: "https://github.com/poljsakerik/firefox-ios")
    }

    weak var settingsDelegate: AboutSettingsDelegate?

    init(settingsDelegate: AboutSettingsDelegate?) {
        self.settingsDelegate = settingsDelegate
    }

    override func onClick(_ navigationController: UINavigationController?) {
        guard let url, let title else { return }
        settingsDelegate?.pressedYourRights(url: url, title: title)
    }
}
