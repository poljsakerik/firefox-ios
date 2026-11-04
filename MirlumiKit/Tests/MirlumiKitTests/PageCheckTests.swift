// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import XCTest
@testable import MirlumiKit

@MainActor
final class PageCheckTests: XCTestCase {
    private final class MemoryStore: ParentSiteStore {
        var saved: [String] = []
        var mode: String?
        init(mode: String? = nil) { self.mode = mode }
        func read() -> [String] { saved }
        func write(_ sites: [String]) { saved = sites }
        func readMode() -> String? { mode }
        func writeMode(_ mode: String) { self.mode = mode }
    }

    private final class Page {}

    /// Answers `verdict` after `delay` seconds.
    private final class FakeClassifier: PageClassifying, @unchecked Sendable {
        let verdict: PageVerdict
        let delay: TimeInterval
        init(_ verdict: PageVerdict, after delay: TimeInterval = 0) {
            self.verdict = verdict
            self.delay = delay
        }

        func prepare() {}
        func checkPage(_ page: PageText) async -> PageVerdict { await answer() }
        func checkSearch(_ query: String) async -> PageVerdict { await answer() }

        private func answer() async -> PageVerdict {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return verdict
        }
    }

    private actor GatedClassifier: PageClassifying {
        private var pending: [CheckedContinuation<PageVerdict, Never>] = []
        private var arrivals: [Int: CheckedContinuation<Void, Never>] = [:]
        nonisolated func prepare() {}
        func checkPage(_ page: PageText) async -> PageVerdict {
            await withCheckedContinuation { continuation in
                pending.append(continuation)
                arrivals.removeValue(forKey: pending.count)?.resume()
            }
        }
        func checkSearch(_ query: String) async -> PageVerdict { await checkPage(PageText()) }
        func waitForCalls(_ count: Int) async {
            if pending.count >= count { return }
            await withCheckedContinuation { arrivals[count] = $0 }
        }
        func releaseAll() {
            let answers = pending
            pending.removeAll()
            answers.forEach { $0.resume(returning: .clear) }
        }
    }

    private func url(_ string: String) -> URL { URL(string: string)! }

    private func openAllowlist(_ store: MemoryStore = MemoryStore(mode: "open")) -> Allowlist {
        let allowlist = Allowlist(store: store, script: Allowlist.bundledScript)
        allowlist.isEnabled = true
        allowlist.isOpenModeAvailable = true
        return allowlist
    }

    private func realClassifier() -> PageClassifier {
        PageClassifier(script: PageClassifier.bundledScript, modelURL: PageClassifier.bundledModelURL)
    }

    /// A page at `address` that the navigation policy let through for a check, and its document's number.
    private func checkedPage(_ address: String, in check: PageCheck, allowlist: Allowlist) throws -> (Page, Int) {
        let page = Page()
        XCTAssertEqual(allowlist.decide(url(address), in: page, isMainFrame: true, isLoad: false, source: nil), .pass)
        let document = try XCTUnwrap(check.startDocument(in: page, at: url(address)))
        return (page, document)
    }

    private let casino = PageText(title: "Online Casino - Slots, Roulette & Live Blackjack",
                                  description: "Claim a 200% welcome bonus and 100 free spins. Bet on sports.",
                                  headings: ["Play slots for real money", "Best sports betting odds"],
                                  body: "Sign up, deposit and play over 2,000 casino games. Spin the slots, try live "
                                    + "roulette and blackjack, and bet on football with the best odds. Withdraw your "
                                    + "winnings fast.")
    private let recipe = PageText(title: "Easy Banana Bread Recipe",
                                  description: "A moist banana bread with ripe bananas, butter and a little cinnamon.",
                                  headings: ["Ingredients", "Method"],
                                  body: "Mash three ripe bananas. Stir in melted butter, sugar, one egg and vanilla. "
                                    + "Mix in flour and baking soda, pour into a loaf tin and bake for an hour at "
                                    + "175 degrees, until a skewer comes out clean.")

    // MARK: The mode

    func testTheModeIsTheAllowlistUntilAParentChoosesOpen() {
        let allowlist = Allowlist(store: MemoryStore(), script: Allowlist.bundledScript)
        allowlist.isEnabled = true
        allowlist.isOpenModeAvailable = true
        XCTAssertEqual(allowlist.browsingMode, .allowlist)
        XCTAssertFalse(allowlist.checksPages)
        let blocked = url("https://example.com/")
        XCTAssertEqual(allowlist.decide(blocked, in: Page(), isMainFrame: true, isLoad: true, source: nil),
                       .block(blocked))
    }

    func testTheModeIsSavedAndReadBack() {
        let store = MemoryStore()
        let allowlist = openAllowlist(store)
        let changed = expectation(forNotification: Allowlist.browsingModeDidChange, object: allowlist)
        allowlist.browsingMode = .open
        wait(for: [changed], timeout: 1)
        XCTAssertEqual(store.mode, "open")
        XCTAssertEqual(openAllowlist(store).browsingMode, .open)
        XCTAssertEqual(openAllowlist(MemoryStore(mode: "nonsense")).browsingMode, .allowlist)
    }

    func testWithoutTheSwitchTheModeIsAlwaysTheAllowlist() {
        let allowlist = openAllowlist()
        allowlist.isOpenModeAvailable = false
        XCTAssertEqual(allowlist.browsingMode, .allowlist)
        XCTAssertFalse(allowlist.checksPages)
        let page = Page()
        let blocked = url("https://example.com/")
        XCTAssertEqual(allowlist.decide(blocked, in: page, isMainFrame: true, isLoad: true, source: nil),
                       .block(blocked))
        XCTAssertFalse(allowlist.needsPageCheck(in: page, at: blocked))
    }

    // MARK: The navigation policy

    func testAnAllowedSiteOpensWithoutACheck() {
        let allowlist = openAllowlist()
        let page = Page()
        let listed = url("https://pbskids.org/games")
        XCTAssertEqual(allowlist.decide(listed, in: page, isMainFrame: true, isLoad: false, source: nil), .pass)
        XCTAssertFalse(allowlist.needsPageCheck(in: page, at: listed))

        allowlist.allow(url("https://example.com/"))
        let parents = url("https://www.example.com/page")
        XCTAssertEqual(allowlist.decide(parents, in: page, isMainFrame: true, isLoad: false, source: nil), .pass)
        XCTAssertFalse(allowlist.needsPageCheck(in: page, at: parents))
    }

    func testAnUnknownSiteOpensAndNeedsACheck() {
        let allowlist = openAllowlist()
        let page = Page()
        let unknown = url("https://example.com/story")
        XCTAssertEqual(allowlist.decide(unknown, in: page, isMainFrame: true, isLoad: false, source: nil), .pass)
        XCTAssertTrue(allowlist.needsPageCheck(in: page, at: unknown))
        XCTAssertTrue(allowlist.needsPageCheck(in: page, at: url("https://example.com/story#part")))
        // A page the policy didn't see is checked unless a list allows it.
        XCTAssertTrue(allowlist.needsPageCheck(in: Page(), at: unknown))
        XCTAssertFalse(allowlist.needsPageCheck(in: Page(), at: url("https://pbskids.org/")))
        XCTAssertFalse(allowlist.needsPageCheck(in: Page(), at: url("about:blank")))
    }

    func testAFlaggedPageIsBlockedWithItsReasonAndCanBeAllowed() {
        let allowlist = openAllowlist()
        let page = Page()
        let flagged = url("https://casino.example/")
        _ = allowlist.decide(flagged, in: page, isMainFrame: true, isLoad: false, source: nil)
        XCTAssertEqual(allowlist.blockCheckedPage(flagged, in: page, verdict: .flagged("gambling")),
                       .block(flagged, reason: "gambling"))
        // The blocked page itself loads once, unchecked.
        XCTAssertEqual(allowlist.decide(flagged, in: page, isMainFrame: true, isLoad: true, source: nil), .pass)
        XCTAssertFalse(allowlist.needsPageCheck(in: page, at: flagged))
        XCTAssertEqual(allowlist.decide(Allowlist.allowURL, in: page, isMainFrame: true, isLoad: false,
                                        source: flagged), .askToAllow(flagged))
        allowlist.allow(flagged)
        XCTAssertEqual(allowlist.decide(flagged, in: page, isMainFrame: true, isLoad: true, source: nil), .pass)
        XCTAssertFalse(allowlist.needsPageCheck(in: page, at: flagged))
    }

    func testAFlaggedSiteStaysBlockedInOtherTabsUntilAParentAllowsIt() {
        let allowlist = openAllowlist()
        let first = Page()
        let flagged = url("https://www.casino.example/slots")
        _ = allowlist.decide(flagged, in: first, isMainFrame: true, isLoad: false, source: nil)
        _ = allowlist.blockCheckedPage(flagged, in: first, verdict: .flagged("gambling"))

        // Same entry as an approval: www. dropped, so the bare host and its other subdomains are covered.
        let other = Page()
        for address in ["https://casino.example/roulette", "https://live.casino.example/", flagged.absoluteString] {
            XCTAssertEqual(allowlist.decide(url(address), in: other, isMainFrame: true, isLoad: false, source: nil),
                           .block(url(address), reason: "gambling"), address)
        }
        XCTAssertEqual(allowlist.decide(url("https://example.com/"), in: other, isMainFrame: true, isLoad: false,
                                        source: nil), .pass)
        // A page that couldn't be checked doesn't mark its site.
        _ = allowlist.blockCheckedPage(url("https://slow.example/"), in: Page(), verdict: .failed)
        XCTAssertEqual(allowlist.decide(url("https://slow.example/"), in: other, isMainFrame: true, isLoad: false,
                                        source: nil), .pass)

        XCTAssertEqual(allowlist.allow(url("https://casino.example/")), "casino.example")
        XCTAssertEqual(allowlist.decide(url("https://casino.example/roulette"), in: other, isMainFrame: true,
                                        isLoad: false, source: nil), .pass)
        XCTAssertFalse(allowlist.needsPageCheck(in: other, at: url("https://casino.example/roulette")))
    }

    func testAFlaggedSiteIsntBlockedOnceOpenModeEnds() {
        let allowlist = openAllowlist()
        let flagged = url("https://casino.example/")
        _ = allowlist.blockCheckedPage(flagged, in: Page(), verdict: .flagged("gambling"))
        allowlist.browsingMode = .allowlist
        // The allowlist blocks it anyway, as a site not on the list.
        XCTAssertEqual(allowlist.decide(flagged, in: Page(), isMainFrame: true, isLoad: false, source: nil),
                       .block(flagged))
    }

    func testAReaderViewPageIsBlockedAtItsArticle() {
        let allowlist = openAllowlist()
        let page = Page()
        let reader = url("readermode://app/page?url=https%3A%2F%2Fwww.casino.example%2Fstory")
        let article = url("https://www.casino.example/story")
        XCTAssertEqual(allowlist.decide(reader, in: page, isMainFrame: true, isLoad: false, source: nil), .pass)
        XCTAssertTrue(allowlist.needsPageCheck(in: page, at: reader))
        XCTAssertEqual(allowlist.blockCheckedPage(reader, in: page, verdict: .flagged("gambling")),
                       .block(article, reason: "gambling"))
        XCTAssertEqual(allowlist.decide(Allowlist.allowURL, in: page, isMainFrame: true, isLoad: false,
                                        source: article), .askToAllow(article))
        XCTAssertEqual(allowlist.allow(article), "casino.example")
        XCTAssertEqual(allowlist.decide(reader, in: page, isMainFrame: true, isLoad: false, source: nil), .pass)
        XCTAssertFalse(allowlist.needsPageCheck(in: page, at: reader))
    }

    // MARK: Searches

    func testOnlyDuckDuckGoSearchesAreHeldAsTheSharedScriptFindsThem() {
        let allowlist = openAllowlist()
        let page = Page()
        for (address, query) in [("https://safe.duckduckgo.com/?q=online+casino&ia=web", "online casino"),
                                 ("https://html.duckduckgo.com/html/?q=cats", "cats"),
                                 ("https://duckduckgo.com/?t=h_&q=a%20b", "a b")] {
            XCTAssertEqual(allowlist.decide(url(address), in: page, isMainFrame: true, isLoad: false, source: nil),
                           .checkSearch(url(address), query: query), address)
        }
        for address in ["https://duckduckgo.com/about", "https://duckduckgo.com/?q=", "https://duckduckgo.com/?ia=web"] {
            XCTAssertEqual(allowlist.decide(url(address), in: page, isMainFrame: true, isLoad: false, source: nil),
                           .pass, address)
        }
        // Not a search: a page like any other, so it's checked.
        let other = url("https://duckduckgo.com.example/?q=casino")
        XCTAssertEqual(allowlist.decide(other, in: page, isMainFrame: true, isLoad: false, source: nil), .pass)
        XCTAssertTrue(allowlist.needsPageCheck(in: page, at: other))
        // The allowlist alone doesn't hold searches.
        allowlist.browsingMode = .allowlist
        XCTAssertEqual(allowlist.decide(url("https://duckduckgo.com/?q=cats"), in: page, isMainFrame: true,
                                        isLoad: false, source: nil), .pass)
    }

    func testAFlaggedSearchIsBlockedWithItsReasonAndCantBeAllowed() {
        let allowlist = openAllowlist()
        let page = Page()
        let search = url("https://safe.duckduckgo.com/?q=online+casino&ia=web")
        _ = allowlist.decide(search, in: page, isMainFrame: true, isLoad: false, source: nil)
        XCTAssertEqual(allowlist.decideSearch(search, in: page, verdict: .flagged("gambling")),
                       .block(search, reason: "search:gambling"))
        XCTAssertEqual(allowlist.decide(search, in: page, isMainFrame: true, isLoad: true, source: nil), .pass)
        XCTAssertEqual(allowlist.decide(Allowlist.allowURL, in: page, isMainFrame: true, isLoad: false,
                                        source: search), .cancel)
    }

    func testASearchThatCouldntBeCheckedIsBlocked() {
        let allowlist = openAllowlist()
        let search = url("https://duckduckgo.com/?q=cats")
        XCTAssertEqual(allowlist.decideSearch(search, in: Page(), verdict: .failed),
                       .block(search, reason: "search:unchecked"))
    }

    func testASearchThatPassesIsDecidedAgainOnce() {
        let allowlist = openAllowlist()
        let page = Page()
        let search = url("https://duckduckgo.com/?q=cats")
        XCTAssertEqual(allowlist.decide(search, in: page, isMainFrame: true, isLoad: false, source: nil),
                       .checkSearch(search, query: "cats"))
        XCTAssertNil(allowlist.decideSearch(search, in: page, verdict: .clear))
        XCTAssertEqual(allowlist.decide(search, in: page, isMainFrame: true, isLoad: false, source: nil), .pass)
        XCTAssertFalse(allowlist.needsPageCheck(in: page, at: search))
        XCTAssertEqual(allowlist.decide(search, in: page, isMainFrame: true, isLoad: false, source: nil),
                       .checkSearch(search, query: "cats"))
    }

    // MARK: The blocked page

    func testTheReasonIsWrittenIntoTheBlockedPage() {
        XCTAssertTrue(Allowlist.blockedPage.contains("<html>"))
        XCTAssertTrue(Allowlist.blockedPage.contains("data-reason"))
        XCTAssertTrue(Allowlist.blockedPage.contains("uncheckedTitle"))
        let page = Allowlist.blockedPage(reason: "search:gambling")
        XCTAssertTrue(page.contains("<html data-reason=\"search:gambling\">"))
        XCTAssertFalse(page.contains("<html>"))
        XCTAssertTrue(Allowlist.blockedPage(reason: "unchecked").contains("<html data-reason=\"unchecked\">"))
        XCTAssertEqual(Allowlist.blockedPage(reason: nil), Allowlist.blockedPage)
        XCTAssertEqual(Allowlist.blockedPage(reason: "\"><script>"), Allowlist.blockedPage)
    }

    // MARK: The page check

    func testACleanPageIsShownAndAFlaggedOneBlocked() async throws {
        let allowlist = openAllowlist()
        let clean = PageCheck(allowlist: allowlist, classifier: FakeClassifier(.clear))
        let (page, document) = try checkedPage("https://example.com/", in: clean, allowlist: allowlist)
        let shown = await clean.check(recipe, at: url("https://example.com/"), in: page, document: document,
                                      revision: 1)
        XCTAssertEqual(shown, .clear)

        let flagging = PageCheck(allowlist: allowlist, classifier: FakeClassifier(.flagged("gambling")))
        let (other, otherDocument) = try checkedPage("https://casino.example/", in: flagging, allowlist: allowlist)
        let blocked = await flagging.check(casino, at: url("https://casino.example/"), in: other,
                                           document: otherDocument, revision: 1)
        XCTAssertEqual(blocked, .block(url("https://casino.example/"), reason: "gambling"))
        // Nothing the replaced document sends afterwards counts.
        let late = await flagging.check(recipe, at: url("https://casino.example/"), in: other,
                                        document: otherDocument, revision: 2)
        XCTAssertEqual(late, .stale)
    }

    func testAnAllowedPageNeedsNoCheck() {
        let allowlist = openAllowlist()
        let check = PageCheck(allowlist: allowlist, classifier: FakeClassifier(.clear))
        let page = Page()
        _ = allowlist.decide(url("https://pbskids.org/"), in: page, isMainFrame: true, isLoad: false, source: nil)
        XCTAssertNil(check.startDocument(in: page, at: url("https://pbskids.org/")))
    }

    func testAnAnswerForAnOlderRevisionIsIgnored() async throws {
        let allowlist = openAllowlist()
        let classifier = GatedClassifier()
        let check = PageCheck(allowlist: allowlist, classifier: classifier)
        let address = url("https://example.com/app")
        let (page, document) = try checkedPage(address.absoluteString, in: check, allowlist: allowlist)
        let first = Task { await check.check(PageText(), at: address, in: page, document: document, revision: 1) }
        await classifier.waitForCalls(1)
        let second = Task { await check.check(recipe, at: address, in: page, document: document, revision: 2) }
        await classifier.waitForCalls(2)
        await classifier.releaseAll()
        let firstOutcome = await first.value
        let secondOutcome = await second.value
        XCTAssertEqual(firstOutcome, .stale)
        XCTAssertEqual(secondOutcome, .clear)
        let replayed = await check.check(recipe, at: address, in: page, document: document, revision: 1)
        XCTAssertEqual(replayed, .stale)
    }

    func testAnAnswerForAnOlderDocumentIsIgnored() async throws {
        let allowlist = openAllowlist()
        let classifier = GatedClassifier()
        let check = PageCheck(allowlist: allowlist, classifier: classifier)
        let address = url("https://example.com/")
        let (page, document) = try checkedPage(address.absoluteString, in: check, allowlist: allowlist)
        let old = Task { await check.check(recipe, at: address, in: page, document: document, revision: 1) }
        await classifier.waitForCalls(1)
        let next = try XCTUnwrap(check.startDocument(in: page, at: address))
        XCTAssertNotEqual(next, document)
        await classifier.releaseAll()
        let oldOutcome = await old.value
        XCTAssertEqual(oldOutcome, .stale)
    }

    func testACheckThatTakesTooLongBlocksThePageAsUnchecked() async throws {
        let allowlist = openAllowlist()
        let check = PageCheck(allowlist: allowlist, classifier: FakeClassifier(.clear, after: 5))
        check.timeout = 0.1
        let address = url("https://example.com/")
        let (page, document) = try checkedPage(address.absoluteString, in: check, allowlist: allowlist)
        let outcome = await check.check(recipe, at: address, in: page, document: document, revision: 1)
        XCTAssertEqual(outcome, .block(address, reason: "unchecked"))
        // A parent can allow it from there.
        _ = allowlist.decide(address, in: page, isMainFrame: true, isLoad: true, source: nil)
        XCTAssertEqual(allowlist.decide(Allowlist.allowURL, in: page, isMainFrame: true, isLoad: false,
                                        source: address), .askToAllow(address))
    }

    func testAPageThatCouldntBeReadIsBlockedAsUnchecked() async throws {
        let allowlist = openAllowlist()
        let check = PageCheck(allowlist: allowlist, classifier: FakeClassifier(.clear))
        let address = url("https://example.com/")
        let (page, document) = try checkedPage(address.absoluteString, in: check, allowlist: allowlist)
        let outcome = await check.check(nil, at: address, in: page, document: document, revision: 1)
        XCTAssertEqual(outcome, .block(address, reason: "unchecked"))
    }

    func testAModelThatCantLoadBlocksPagesAsUnchecked() async throws {
        let classifier = PageClassifier(script: PageClassifier.bundledScript,
                                        modelURL: URL(fileURLWithPath: "/nonexistent/page-classifier.mpc"))
        let verdict = await classifier.checkPage(casino)
        XCTAssertEqual(verdict, .failed)
        let search = await classifier.checkSearch("cats")
        XCTAssertEqual(search, .failed)

        let allowlist = openAllowlist()
        let check = PageCheck(allowlist: allowlist, classifier: classifier)
        let address = url("https://example.com/")
        let (page, document) = try checkedPage(address.absoluteString, in: check, allowlist: allowlist)
        let outcome = await check.check(recipe, at: address, in: page, document: document, revision: 1)
        XCTAssertEqual(outcome, .block(address, reason: "unchecked"))
    }

    func testTurningOpenModeOffRevalidatesPagesAndDropsPendingAnswers() async throws {
        let allowlist = openAllowlist()
        let classifier = GatedClassifier()
        let check = PageCheck(allowlist: allowlist, classifier: classifier)
        let address = url("https://example.com/")
        let (page, document) = try checkedPage(address.absoluteString, in: check, allowlist: allowlist)
        let pending = Task { await check.check(recipe, at: address, in: page, document: document, revision: 1) }
        await classifier.waitForCalls(1)
        allowlist.browsingMode = .allowlist
        await classifier.releaseAll()
        let outcome = await pending.value
        XCTAssertEqual(outcome, .stale)

        XCTAssertEqual(allowlist.revalidate(address, in: page), .block(address))
        // The blocked page that replaces it stays, and so does an allowed page.
        _ = allowlist.decide(address, in: page, isMainFrame: true, isLoad: true, source: nil)
        XCTAssertEqual(allowlist.revalidate(address, in: page), .pass)
        let listed = Page()
        _ = allowlist.decide(url("https://pbskids.org/"), in: listed, isMainFrame: true, isLoad: false, source: nil)
        XCTAssertEqual(allowlist.revalidate(url("https://pbskids.org/"), in: listed), .pass)
    }

    // MARK: The classifier

    func testTheClassifierFlagsGamblingAndPassesARecipe() async {
        let classifier = realClassifier()
        let flagged = await classifier.checkPage(casino)
        XCTAssertEqual(flagged, .flagged("gambling"))
        let passed = await classifier.checkPage(recipe)
        XCTAssertEqual(passed, .clear)
    }

    func testTheClassifierChecksSearchesWithItsSearchThresholds() async {
        let classifier = realClassifier()
        let porn = await classifier.checkSearch("free porn")
        XCTAssertEqual(porn, .flagged("sexual"))
        let casino = await classifier.checkSearch("online casino bonus")
        XCTAssertEqual(casino, .flagged("gambling"))
        for query in ["suicide prevention hotline", "depression help for teenagers", "chocolate cake recipe"] {
            let verdict = await classifier.checkSearch(query)
            XCTAssertEqual(verdict, .clear, query)
        }
    }

    func testAPageMessageIsReadIntoItsFields() {
        let page = PageText(message: ["title": "T", "description": "D", "headings": ["A", 1, "B"], "body": "x"])
        XCTAssertEqual(page, PageText(title: "T", description: "D", headings: ["A", "B"], body: "x"))
        XCTAssertNil(PageText(message: "not a page"))
    }
}
