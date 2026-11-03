// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import XCTest
@testable import MirlumiKit

final class SettingsLockStringsTests: XCTestCase {
    private let keys = ["SetupTitle", "SetupBody", "ConfirmTitle", "ConfirmBody", "UnlockTitle", "UnlockBody",
                        "CurrentTitle", "NewTitle", "Changed", "Wrong", "Mismatch", "LockedOut", "Cancel", "Delete",
                        "Progress", "PreferenceTitle", "Seconds", "Minutes"]

    private func bundle(_ language: String) throws -> Bundle {
        let path = try XCTUnwrap(Bundle.module.path(forResource: language, ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path))
    }

    func testEveryStringExistsInEnglishAndSlovenian() throws {
        for language in ["en", "sl"] {
            let bundle = try bundle(language)
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: "MISSING", table: "SettingsLock")
                XCTAssertNotEqual(value, "MISSING", "\(language): \(key)")
            }
        }
    }

    func testSlovenianDeclinesTheLockoutTime() throws {
        let bundle = try bundle("sl")
        let format = bundle.localizedString(forKey: "Seconds", value: nil, table: "SettingsLock")
        let slovenian = Locale(identifier: "sl")

        XCTAssertEqual(String(format: format, locale: slovenian, 1), "1 sekundo")
        XCTAssertEqual(String(format: format, locale: slovenian, 2), "2 sekundi")
        XCTAssertEqual(String(format: format, locale: slovenian, 3), "3 sekunde")
        XCTAssertEqual(String(format: format, locale: slovenian, 30), "30 sekund")
    }

    func testTheDigitsEnteredArePluralInBothLanguages() throws {
        func progress(_ language: String, _ entered: Int) throws -> String {
            let format = try bundle(language).localizedString(forKey: "Progress", value: nil, table: "SettingsLock")
            return String(format: format, locale: Locale(identifier: language), entered, SettingsPIN.length)
        }

        XCTAssertEqual(try progress("en", 0), "0 digits of 4 entered")
        XCTAssertEqual(try progress("en", 1), "1 digit of 4 entered")
        XCTAssertEqual(try progress("en", 4), "4 digits of 4 entered")
        XCTAssertEqual(try progress("sl", 0), "Vnesenih 0 števk od 4")
        XCTAssertEqual(try progress("sl", 1), "Vnesena 1 števka od 4")
        XCTAssertEqual(try progress("sl", 2), "Vneseni 2 števki od 4")
        XCTAssertEqual(try progress("sl", 3), "Vnesene 3 števke od 4")
        XCTAssertEqual(try progress("sl", 4), "Vnesene 4 števke od 4")
    }
}
