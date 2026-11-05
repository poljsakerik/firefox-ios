// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import MirlumiKit
import UIKit

extension AppSettingsTableViewController {
    /// Mirlumi's own settings, which Settings opens on. Each row follows its feature's switch; the last row opens the
    /// browser's settings.
    func mirlumiSettingSections() -> [SettingSection] {
        var sections = [SettingSection]()
        if Allowlist.shared.isEnabled {
            sections.append(SettingSection(title: NSAttributedString(string: MirlumiSettings.browsingSectionTitle),
                                           children: [MirlumiAllowedSitesSetting()]))
        }
        if SettingsLock.shared.isEnabled {
            sections.append(SettingSection(title: NSAttributedString(string: MirlumiSettings.pinSectionTitle),
                                           children: [MirlumiSettingsPINSetting()]))
        }
        sections.append(SettingSection(children: [MirlumiBrowserSettingsSetting { [weak self] in
            self?.makeBrowserSettingsController()
        }]))
        return sections
    }

    /// Mirlumi's rows in the browser's Privacy section, while `MirlumiBuild.settingsScreenEnabled` is off.
    func mirlumiPrivacySettings() -> [Setting] {
        var settings = [Setting]()
        if SettingsLock.shared.isEnabled {
            settings.append(MirlumiSettingsPINSetting())
        }
        if Allowlist.shared.isEnabled {
            settings.append(MirlumiAllowedSitesSetting())
        }
        return settings
    }

    private func makeBrowserSettingsController() -> UIViewController? {
        guard let profile, let tabManager, let settingsDelegate, let parentCoordinator else { return nil }
        return MirlumiBrowserSettingsViewController(
            with: profile,
            and: tabManager,
            settingsDelegate: settingsDelegate,
            parentCoordinator: parentCoordinator,
            gleanUsageReportingMetricsService: AppContainer.shared.resolve()
        )
    }
}

/// The browser's own settings, one row below Mirlumi's.
final class MirlumiBrowserSettingsViewController: AppSettingsTableViewController {
    override var showsMirlumiSettings: Bool { false }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = MirlumiSettings.browserSettingsTitle
    }
}

/// Opens the browser's settings from Mirlumi's.
final class MirlumiBrowserSettingsSetting: Setting {
    private let makeController: () -> UIViewController?

    init(makeController: @escaping () -> UIViewController?) {
        self.makeController = makeController
        super.init()
    }

    override var title: NSAttributedString? {
        guard let theme else { return nil }
        return NSAttributedString(string: MirlumiSettings.browserSettingsTitle,
                                  attributes: [NSAttributedString.Key.foregroundColor: theme.colors.textPrimary])
    }

    override var status: NSAttributedString? {
        guard let theme else { return nil }
        return NSAttributedString(string: MirlumiSettings.browserSettingsSummary,
                                  attributes: [NSAttributedString.Key.foregroundColor: theme.colors.textSecondary])
    }

    override var accessoryType: UITableViewCell.AccessoryType { return .disclosureIndicator }

    override func onClick(_ navigationController: UINavigationController?) {
        guard let controller = makeController() else { return }
        navigationController?.pushViewController(controller, animated: true)
    }
}
