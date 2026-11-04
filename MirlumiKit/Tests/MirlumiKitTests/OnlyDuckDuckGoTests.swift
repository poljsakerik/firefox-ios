// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
@testable import MirlumiKit

final class OnlyDuckDuckGoTests: XCTestCase {
    func testOnlyTheBuiltInDuckDuckGoIsAllowed() {
        XCTAssertTrue(OnlyDuckDuckGo.allows(engineID: "ddg", isCustomEngine: false, enabled: true))
        for engineID in ["google", "bing", "wikipedia", "DDG", ""] {
            XCTAssertFalse(OnlyDuckDuckGo.allows(engineID: engineID, isCustomEngine: false, enabled: true), engineID)
        }
        XCTAssertFalse(OnlyDuckDuckGo.allows(engineID: "ddg", isCustomEngine: true, enabled: true))
        XCTAssertFalse(OnlyDuckDuckGo.allowsCustomEngines(enabled: true))
    }

    func testEveryEngineIsAllowedWhenSwitchedOff() {
        XCTAssertTrue(OnlyDuckDuckGo.allows(engineID: "google", isCustomEngine: false, enabled: false))
        XCTAssertTrue(OnlyDuckDuckGo.allows(engineID: "custom", isCustomEngine: true, enabled: false))
        XCTAssertTrue(OnlyDuckDuckGo.allowsCustomEngines(enabled: false))
    }
}
