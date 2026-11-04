// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import MirlumiKit
import UIKit

/// Lists the sites a parent allowed with the PIN, each with a way to remove it.
class MirlumiAllowedSitesSetting: Setting {
    override var title: NSAttributedString? {
        guard let theme else { return nil }
        return NSAttributedString(string: Allowlist.allowedSitesTitle,
                                  attributes: [NSAttributedString.Key.foregroundColor: theme.colors.textPrimary])
    }

    override var accessoryType: UITableViewCell.AccessoryType { return .disclosureIndicator }

    override func onClick(_ navigationController: UINavigationController?) {
        navigationController?.pushViewController(Allowlist.shared.makeAllowedSitesController(), animated: true)
    }
}
