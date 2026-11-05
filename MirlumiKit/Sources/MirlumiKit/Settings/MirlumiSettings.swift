// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// The texts of Mirlumi's Settings screen: Mirlumi's own settings first, then a row that opens the browser's settings.
public enum MirlumiSettings {
    public static var browsingSectionTitle: String { string("BrowsingSectionTitle") }
    public static var pinSectionTitle: String { string("PINSectionTitle") }
    public static var browserSettingsTitle: String { string("BrowserSettingsTitle") }
    public static var browserSettingsSummary: String { string("BrowserSettingsSummary") }

    static func string(_ key: String) -> String {
        NSLocalizedString(key, tableName: "Settings", bundle: .module, comment: "")
    }
}
