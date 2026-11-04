// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import XCTest
#if canImport(WebKit)
import WebKit
#endif
@testable import MirlumiKit

@MainActor
final class SafeSearchTests: XCTestCase {
    private func enabled() -> SafeSearch {
        let safeSearch = SafeSearch()
        safeSearch.isEnabled = true
        return safeSearch
    }

    private func safe(_ address: String) -> String? {
        enabled().safeURL(for: URL(string: address)!)?.absoluteString
    }

    func testTheBundledRulesLoad() {
        XCTAssertNotNil(SafeSearch.bundledScript())
    }

    func testSearchesGoToTheSafeHost() {
        XCTAssertEqual(safe("https://duckduckgo.com/?q=cats&kp=-2"), "https://safe.duckduckgo.com/?q=cats&kp=-2")
        XCTAssertEqual(safe("https://html.duckduckgo.com/html/?q=cats"), "https://safe.duckduckgo.com/?q=cats")
        XCTAssertEqual(safe("http://www.duckduckgo.com/?q=cats"), "https://safe.duckduckgo.com/?q=cats")
        XCTAssertEqual(safe("https://noai.duckduckgo.com/?q=cats#x"), "https://safe.duckduckgo.com/?q=cats#x")
    }

    func testOtherAddressesLoadUnchanged() {
        XCTAssertNil(safe("https://safe.duckduckgo.com/?q=cats"))
        XCTAssertNil(safe("https://links.duckduckgo.com/d.js?q=cats"))
        XCTAssertNil(safe("https://example.com/?q=duckduckgo.com"))
        XCTAssertNil(safe("https://duckduckgo.com.example.com/"))
    }

    func testTrailingDotHostsGoToTheSafeHost() {
        XCTAssertEqual(safe("https://duckduckgo.com./?q=cats"), "https://safe.duckduckgo.com/?q=cats")
        XCTAssertEqual(safe("https://html.duckduckgo.com./html/?q=cats"), "https://safe.duckduckgo.com/?q=cats")
    }

    func testBangsAreTakenOutOfSearches() {
        XCTAssertEqual(safe("https://duckduckgo.com/?q=%21g+cats"), "https://safe.duckduckgo.com/?q=g+cats")
        XCTAssertEqual(safe("https://safe.duckduckgo.com/?q=cats+g%21"), "https://safe.duckduckgo.com/?q=cats+g")
        XCTAssertEqual(safe("https://safe.duckduckgo.com/?q=%5Ccats"), "https://safe.duckduckgo.com/?q=cats")
        XCTAssertEqual(safe("https://safe.duckduckgo.com/?q=dogs;q=%EF%BC%81g"), "https://safe.duckduckgo.com/?q=dogs;q=g")
    }

    func testPostedFormsToDuckDuckGoAreRefused() {
        let safeSearch = enabled()
        XCTAssertTrue(safeSearch.refusesLoad(of: URL(string: "https://safe.duckduckgo.com/lite/")!, method: "POST"))
        XCTAssertTrue(safeSearch.refusesLoad(of: URL(string: "https://duckduckgo.com/")!, method: "POST"))
        XCTAssertFalse(safeSearch.refusesLoad(of: URL(string: "https://duckduckgo.com/")!, method: "GET"))
        XCTAssertFalse(safeSearch.refusesLoad(of: URL(string: "https://duckduckgo.com/")!, method: nil))
        XCTAssertFalse(safeSearch.refusesLoad(of: URL(string: "https://example.com/")!, method: "POST"))
        XCTAssertFalse(SafeSearch().refusesLoad(of: URL(string: "https://duckduckgo.com/")!, method: "POST"))
    }

    #if canImport(WebKit)
    func testAGuardedWebViewSendsItsNavigationsThroughSafeSearch() {
        let webView = WKWebView()
        XCTAssertNil(webView.navigationDelegate)
        let safeSearch = enabled()
        safeSearch.guardNavigation(of: webView)
        XCTAssertTrue(webView.navigationDelegate is NavigationGuard)
    }
    #endif

    func testNothingChangesWhenSwitchedOff() {
        XCTAssertNil(SafeSearch().safeURL(for: URL(string: "https://duckduckgo.com/?q=cats")!))
    }
}
