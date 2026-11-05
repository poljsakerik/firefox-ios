// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import XCTest
@testable import MirlumiKit

final class MirlumiSettingsStringsTests: XCTestCase {
    private let keys = ["BrowsingSectionTitle", "PINSectionTitle", "BrowserSettingsTitle", "BrowserSettingsSummary"]

    func testEveryStringExistsInEnglishAndSlovenian() throws {
        for language in ["en", "sl"] {
            let path = try XCTUnwrap(Bundle.module.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: "MISSING", table: "Settings")
                XCTAssertNotEqual(value, "MISSING", "\(language): \(key)")
            }
        }
    }
}
