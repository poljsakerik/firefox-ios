// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import MirlumiKit
import UIKit

/// Changes the parent's PIN that keeps Settings locked.
class MirlumiSettingsPINSetting: Setting {
    override var title: NSAttributedString? {
        guard let theme else { return nil }
        return NSAttributedString(string: SettingsLock.changePINTitle,
                                  attributes: [NSAttributedString.Key.foregroundColor: theme.colors.textPrimary])
    }

    override var accessoryType: UITableViewCell.AccessoryType { return .disclosureIndicator }

    override func onClick(_ navigationController: UINavigationController?) {
        guard let navigationController else { return }
        SettingsLock.shared.presentChangePIN(from: navigationController)
    }
}
