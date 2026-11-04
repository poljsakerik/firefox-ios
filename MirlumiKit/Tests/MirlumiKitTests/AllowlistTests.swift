// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import XCTest
@testable import MirlumiKit

@MainActor
final class AllowlistTests: XCTestCase {
    private final class MemoryStore: ParentSiteStore {
        var saved: [String]
        init(_ saved: [String] = []) { self.saved = saved }
        func read() -> [String] { saved }
        func write(_ sites: [String]) { saved = sites }
        func readMode() -> String? { nil }
        func writeMode(_ mode: String) {}
    }

    private final class Page {}

    private func allowlist(_ store: MemoryStore = MemoryStore()) -> Allowlist {
        Allowlist(store: store, script: Allowlist.bundledScript)
    }

    private func url(_ string: String) -> URL { URL(string: string)! }

    func testTheBundledListOpensAndOtherSitesDont() {
        let allowlist = allowlist()
        XCTAssertTrue(allowlist.allows(url("https://pbskids.org/games")))
        XCTAssertTrue(allowlist.allows(url("https://www.pbskids.org/")))
        XCTAssertTrue(allowlist.allows(url("https://duckduckgo.com/?q=cats")))
        XCTAssertTrue(allowlist.allows(url("https://www.bbc.co.uk/cbeebies/games")))
        XCTAssertFalse(allowlist.allows(url("https://www.bbc.co.uk/news")))
        XCTAssertFalse(allowlist.allows(url("https://www.bbc.co.uk/cbeebies/%2e%2e/news")))
        XCTAssertFalse(allowlist.allows(url("https://example.com/")))
        XCTAssertFalse(allowlist.allows(url("https://pbskids.org.example.com/")))
        XCTAssertFalse(allowlist.allows(url("http://127.0.0.1/")))
    }

    func testAnInternationalHostIsMatchedInItsASCIIForm() throws {
        guard #available(iOS 16, macOS 13, *) else { throw XCTSkip("international hosts open from iOS 16") }
        let store = MemoryStore()
        let allowlist = allowlist(store)
        XCTAssertTrue(allowlist.allows(url("https://www.franček.si/")))
        XCTAssertTrue(allowlist.allows(url("https://www.xn--franek-l2a.si/")))
        XCTAssertEqual(allowlist.allow(url("https://www.zürich.ch/")), "xn--zrich-kva.ch")
        XCTAssertTrue(allowlist.allows(url("https://zürich.ch/")))
        XCTAssertEqual(store.saved, ["xn--zrich-kva.ch"])
    }

    func testAPercentEncodedHostIsRefused() {
        let allowlist = allowlist()
        XCTAssertFalse(allowlist.allows(url("https://pbskids%2eorg/")))
        XCTAssertFalse(allowlist.allows(url("https://evil.com%2f.pbskids.org/")))
        XCTAssertNil(allowlist.allow(url("https://example%2ecom/")))
    }

    func testOtherSchemesAreLeftToTheBrowser() {
        let allowlist = allowlist()
        XCTAssertTrue(allowlist.allows(url("about:blank")))
        XCTAssertTrue(allowlist.allows(url("internal://local/about/home")))
    }

    func testWithoutTheMatcherNothingOpens() {
        let allowlist = Allowlist(store: MemoryStore(), script: "this is not javascript (")
        XCTAssertFalse(allowlist.allows(url("https://pbskids.org/")))
    }

    func testAParentsSitesOpenAndAreSaved() {
        let store = MemoryStore()
        let allowlist = allowlist(store)
        let changed = expectation(forNotification: Allowlist.parentSitesDidChange, object: allowlist)
        XCTAssertEqual(allowlist.allow(url("https://www.example.com/some/page")), "example.com")
        wait(for: [changed], timeout: 1)
        XCTAssertTrue(allowlist.allows(url("https://shop.example.com/")))
        XCTAssertEqual(store.saved, ["example.com"])

        allowlist.remove("example.com")
        XCTAssertFalse(allowlist.allows(url("https://example.com/")))
        XCTAssertEqual(store.saved, [])
    }

    func testStoredSitesAreReadBackAndJunkIsDropped() {
        let allowlist = allowlist(MemoryStore(["example.org", "not an entry", "example.org"]))
        XCTAssertEqual(allowlist.parentSites, ["example.org"])
        XCTAssertTrue(allowlist.allows(url("https://example.org/")))
    }

    func testABlockedPageIsShownInTheAddresssPlaceOnce() {
        let allowlist = allowlist()
        let page = Page()
        let blocked = url("https://example.com/")
        XCTAssertEqual(allowlist.decide(blocked, in: page, isMainFrame: true, isLoad: true, source: nil),
                       .block(blocked))
        // The blocked page's own load passes, but only once: a reload or a typed address is blocked again.
        XCTAssertEqual(allowlist.decide(blocked, in: page, isMainFrame: true, isLoad: true, source: nil), .pass)
        XCTAssertEqual(allowlist.decide(blocked, in: page, isMainFrame: true, isLoad: true, source: nil),
                       .block(blocked))
        XCTAssertEqual(allowlist.decide(blocked, in: page, isMainFrame: true, isLoad: true, source: nil), .pass)
        XCTAssertEqual(allowlist.decide(blocked, in: page, isMainFrame: true, isLoad: false, source: nil),
                       .block(blocked))
    }

    func testTheExceptionDoesntCarryOverToALaterNavigation() {
        let allowlist = allowlist()
        let page = Page()
        let blocked = url("https://example.com/")
        _ = allowlist.decide(blocked, in: page, isMainFrame: true, isLoad: true, source: nil)
        XCTAssertEqual(allowlist.decide(url("https://pbskids.org/"), in: page, isMainFrame: true, isLoad: true,
                                        source: nil), .pass)
        XCTAssertEqual(allowlist.decide(blocked, in: page, isMainFrame: true, isLoad: true, source: nil),
                       .block(blocked))
    }

    func testFramesAndNewWindowsAreLeftToTheirOwnPage() {
        let allowlist = allowlist()
        XCTAssertEqual(allowlist.decide(url("https://example.com/ad"), in: Page(), isMainFrame: false, isLoad: false,
                                        source: url("https://pbskids.org/")), .pass)
    }

    func testOnlyTheBlockedPageCanAskForThePIN() {
        let allowlist = allowlist()
        let page = Page()
        let blocked = url("https://example.com/")
        _ = allowlist.decide(blocked, in: page, isMainFrame: true, isLoad: true, source: nil)
        XCTAssertEqual(allowlist.decide(Allowlist.allowURL, in: page, isMainFrame: true, isLoad: false,
                                        source: blocked), .askToAllow(blocked))
        XCTAssertEqual(allowlist.decide(Allowlist.allowURL, in: page, isMainFrame: true, isLoad: false,
                                        source: url("https://evil.example/")), .cancel)
        XCTAssertEqual(allowlist.decide(Allowlist.allowURL, in: Page(), isMainFrame: true, isLoad: false,
                                        source: blocked), .cancel)
    }

    func testReaderViewIsJudgedByItsArticle() {
        let allowlist = allowlist()
        let page = Page()
        let blocked = url("https://example.com/story")
        for reader in ["readermode://app/page?url=https%3A%2F%2Fexample.com%2Fstory",
                       "http://localhost:6571/reader-mode/page?url=https%3A%2F%2Fexample.com%2Fstory",
                       "about:reader?url=https%3A%2F%2Fexample.com%2Fstory"] {
            XCTAssertFalse(allowlist.allows(url(reader)), reader)
            XCTAssertEqual(allowlist.decide(url(reader), in: page, isMainFrame: true, isLoad: true, source: nil),
                           .block(blocked), reader)
            _ = allowlist.decide(blocked, in: page, isMainFrame: true, isLoad: true, source: nil)
        }
        let allowed = url("readermode://app/page?url=https%3A%2F%2Fpbskids.org%2Fstory")
        XCTAssertTrue(allowlist.allows(allowed))
        XCTAssertEqual(allowlist.decide(allowed, in: page, isMainFrame: true, isLoad: true, source: nil), .pass)
        XCTAssertTrue(allowlist.allows(url("http://localhost:6571/reader-mode/page?url=https%3A%2F%2Fpbskids.org%2F")))
        XCTAssertFalse(allowlist.allows(url("readermode://app/page")))
        XCTAssertFalse(allowlist.allows(url("http://localhost:6571/other")))
    }

    func testEveryReaderRouteIsJudgedByItsArticle() {
        let allowlist = allowlist()
        XCTAssertFalse(allowlist.allows(url("readermode://app/page/extra?url=https%3A%2F%2Fexample.com%2Fstory")))
        XCTAssertFalse(allowlist.allows(url("readermode://other/page?url=https%3A%2F%2Fexample.com%2Fstory")))
        XCTAssertFalse(allowlist.allows(url("http://127.0.0.1:6571/reader-mode/page?url=https%3A%2F%2Fexample.com")))
        XCTAssertTrue(allowlist.allows(url("readermode://app/page/extra?url=https%3A%2F%2Fpbskids.org%2F")))
        XCTAssertEqual(allowlist.decide(url("readermode://app/page/x?url=https%3A%2F%2Fexample.com%2Fs"), in: Page(),
                                        isMainFrame: true, isLoad: false, source: nil),
                       .block(url("https://example.com/s")))
    }

    func testAReaderAddressNamingTwoArticlesIsRefused() {
        let allowlist = allowlist()
        let twice = url("http://localhost:6571/reader-mode/page?url=https%3A%2F%2Fpbskids.org%2F"
                        + "&url=https%3A%2F%2Fexample.com%2Fstory")
        XCTAssertFalse(allowlist.allows(twice))
        XCTAssertEqual(allowlist.decide(twice, in: Page(), isMainFrame: true, isLoad: false, source: nil), .cancel)
        XCTAssertFalse(allowlist.allows(url("readermode://app/page?url=https%3A%2F%2Fpbskids.org%2F&url=x")))
    }

    func testTheBlockedPageAsksAtTheAddressThisPackageIntercepts() {
        XCTAssertTrue(Allowlist.blockedPage.contains(Allowlist.allowURL.absoluteString))
        XCTAssertTrue(Allowlist.blockedPage.contains("MirlumiBlockedStrings"))
    }

    func testEveryStringExistsInEnglishAndSlovenian() throws {
        for language in ["en", "sl"] {
            let path = try XCTUnwrap(Bundle.module.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in ["AllowedSitesTitle", "AllowedSitesBody", "AllowedSitesEmpty", "Remove", "OpenAllSites",
                        "OpenAllSitesFooter"] {
                let value = bundle.localizedString(forKey: key, value: "MISSING", table: "Allowlist")
                XCTAssertNotEqual(value, "MISSING", "\(language): \(key)")
            }
        }
    }
}
