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

    /// Holds each check until the test answers it, and tells the test when one arrives.
    private final class GatedClassifier: PageClassifying, @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [CheckedContinuation<PageVerdict, Never>] = []
        private let arrived: AsyncStream<Void>.Continuation
        let arrivals: AsyncStream<Void>

        init() {
            var arrived: AsyncStream<Void>.Continuation?
            arrivals = AsyncStream { arrived = $0 }
            self.arrived = arrived!
        }

        func prepare() {}
        func checkPage(_ page: PageText) async -> PageVerdict { await hold() }
        func checkSearch(_ query: String) async -> PageVerdict { await hold() }

        /// Answers the check that arrived `index`th among those still waiting.
        func answer(_ index: Int, with verdict: PageVerdict) {
            lock.lock()
            let continuation = waiting.remove(at: index)
            lock.unlock()
            continuation.resume(returning: verdict)
        }

        private func hold() async -> PageVerdict {
            await withCheckedContinuation { continuation in
                lock.lock()
                waiting.append(continuation)
                lock.unlock()
                arrived.yield()
            }
        }
    }

    private func url(_ string: String) -> URL { URL(string: string)! }

    private func openAllowlist(_ store: MemoryStore = MemoryStore(mode: "open")) -> Allowlist {
        let allowlist = Allowlist(store: store, script: Allowlist.bundledScript)
        allowlist.isEnabled = true
        allowlist.isOpenModeAvailable = true
        return allowlist
    }

    /// A page check whose classifier the test answers, with long timeouts so only the test decides.
    private func gatedCheck(_ allowlist: Allowlist) -> (PageCheck, GatedClassifier) {
        let classifier = GatedClassifier()
        let check = PageCheck(allowlist: allowlist, classifier: classifier)
        check.timeout = 60
        check.setPageConcealed = { _, _ in }
        check.stopScript = { _ in }
        return (check, classifier)
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

    func testAnAnswerForAnOlderRevisionIsIgnoredAndDoesntRevealThePage() async throws {
        let allowlist = openAllowlist()
        let (check, classifier) = gatedCheck(allowlist)
        var arrivals = classifier.arrivals.makeAsyncIterator()
        let address = url("https://example.com/app")
        let (page, document) = try checkedPage(address.absoluteString, in: check, allowlist: allowlist)
        XCTAssertTrue(check.isConcealed(page))
        let first = Task { await check.check(PageText(), at: address, in: page, document: document, revision: 1) }
        _ = await arrivals.next()
        let second = Task { await check.check(self.recipe, at: address, in: page, document: document, revision: 2) }
        _ = await arrivals.next()

        classifier.answer(0, with: .clear)
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .stale)
        XCTAssertTrue(check.isConcealed(page))

        classifier.answer(0, with: .clear)
        let secondOutcome = await second.value
        XCTAssertEqual(secondOutcome, .clear)
        XCTAssertFalse(check.isConcealed(page))

        let replayed = await check.check(recipe, at: address, in: page, document: document, revision: 1)
        XCTAssertEqual(replayed, .stale)
        XCTAssertFalse(check.isConcealed(page))
    }

    func testAnAnswerForAnOlderDocumentIsIgnored() async throws {
        let allowlist = openAllowlist()
        let (check, classifier) = gatedCheck(allowlist)
        var arrivals = classifier.arrivals.makeAsyncIterator()
        let address = url("https://example.com/")
        let (page, document) = try checkedPage(address.absoluteString, in: check, allowlist: allowlist)
        let old = Task { await check.check(self.recipe, at: address, in: page, document: document, revision: 1) }
        _ = await arrivals.next()
        let next = try XCTUnwrap(check.startDocument(in: page, at: address))
        XCTAssertNotEqual(next, document)
        classifier.answer(0, with: .clear)
        let oldOutcome = await old.value
        XCTAssertEqual(oldOutcome, .stale)
        XCTAssertTrue(check.isConcealed(page))
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

    func testFlaggingASiteBlocksItsOtherOpenPagesAndTheirPendingChecks() async throws {
        let allowlist = openAllowlist()
        let (check, classifier) = gatedCheck(allowlist)
        var arrivals = classifier.arrivals.makeAsyncIterator()
        let flaggedAddress = url("https://www.casino.example/slots")
        let other = url("https://casino.example/live")
        let reader = url("readermode://app/page?url=https%3A%2F%2Fwww.casino.example%2Fstory")
        let unrelated = url("https://example.com/")
        let (pageA, documentA) = try checkedPage(flaggedAddress.absoluteString, in: check, allowlist: allowlist)
        let (pageB, documentB) = try checkedPage(other.absoluteString, in: check, allowlist: allowlist)
        let pageC = Page()
        _ = allowlist.decide(reader, in: pageC, isMainFrame: true, isLoad: false, source: nil)
        let (pageD, _) = try checkedPage(unrelated.absoluteString, in: check, allowlist: allowlist)
        var shown: [(AnyObject, URL, String)] = []
        check.openPages = { [(pageA, flaggedAddress), (pageB, other), (pageC, reader), (pageD, unrelated)] }
        check.showBlocked = { shown.append(($0, $1, $2)) }

        // B's check reaches the classifier first and waits there.
        let pendingB = Task { await check.check(self.recipe, at: other, in: pageB, document: documentB, revision: 1) }
        _ = await arrivals.next()
        let checkA = Task {
            await check.check(self.casino, at: flaggedAddress, in: pageA, document: documentA, revision: 1)
        }
        _ = await arrivals.next()
        classifier.answer(1, with: .flagged("gambling"))
        let outcomeA = await checkA.value
        XCTAssertEqual(outcomeA, .block(flaggedAddress, reason: "gambling"))

        // B, and the reader view of an article on the site, are blocked now; the unrelated page and A itself, which
        // its own check blocks, aren't blocked here.
        XCTAssertEqual(shown.count, 2)
        XCTAssertTrue(shown.contains { $0.0 === pageB && $0.1 == other && $0.2 == "gambling" })
        XCTAssertTrue(shown.contains { $0.0 === pageC && $0.1 == url("https://www.casino.example/story") })
        XCTAssertTrue(check.isConcealed(pageB))

        // B's answer comes back clear, for a document that no longer counts.
        classifier.answer(0, with: .clear)
        let outcomeB = await pendingB.value
        XCTAssertEqual(outcomeB, .stale)
        XCTAssertTrue(check.isConcealed(pageB))
    }

    func testAClearVerdictForAFlaggedSiteBlocks() {
        let allowlist = openAllowlist()
        _ = allowlist.blockCheckedPage(url("https://casino.example/"), in: Page(), verdict: .flagged("gambling"))
        let page = Page()
        XCTAssertEqual(allowlist.blockCheckedPage(url("https://casino.example/about"), in: page, verdict: .clear),
                       .block(url("https://casino.example/about"), reason: "gambling"))
        XCTAssertNil(allowlist.blockCheckedPage(url("https://example.com/"), in: Page(), verdict: .clear))
        // Once the blocked page shows there, it stays, and an allowed site isn't blocked.
        _ = allowlist.decide(url("https://casino.example/about"), in: page, isMainFrame: true, isLoad: true,
                             source: nil)
        XCTAssertNil(allowlist.blockIfFlagged(url("https://casino.example/about"), in: page))
        allowlist.allow(url("https://casino.example/"))
        XCTAssertNil(allowlist.blockIfFlagged(url("https://casino.example/"), in: Page()))
    }

    func testTurningOpenModeOffRevalidatesPagesAndDropsPendingAnswers() async throws {
        let allowlist = openAllowlist()
        let (check, classifier) = gatedCheck(allowlist)
        var arrivals = classifier.arrivals.makeAsyncIterator()
        let address = url("https://example.com/")
        let listedAddress = url("https://pbskids.org/")
        let (page, document) = try checkedPage(address.absoluteString, in: check, allowlist: allowlist)
        let listed = Page()
        _ = allowlist.decide(listedAddress, in: listed, isMainFrame: true, isLoad: false, source: nil)
        var shown: [(AnyObject, URL, String?)] = []
        var stopped: [AnyObject] = []
        check.openPages = { [(page, address), (listed, listedAddress)] }
        check.showBlocked = { shown.append(($0, $1, $2)) }
        check.stopScript = { stopped.append($0) }
        let pending = Task { await check.check(self.recipe, at: address, in: page, document: document, revision: 1) }
        _ = await arrivals.next()

        // The notification runs the page check's revalidation at once, on the main actor.
        allowlist.browsingMode = .allowlist
        // The unlisted page is replaced by the blocked page, and stays hidden until it loads; the listed one is shown.
        XCTAssertEqual(shown.count, 1)
        XCTAssertTrue(shown[0].0 === page && shown[0].1 == address)
        XCTAssertTrue(check.isConcealed(page))
        XCTAssertTrue(stopped.contains { $0 === listed })

        classifier.answer(0, with: .clear)
        let outcome = await pending.value
        XCTAssertEqual(outcome, .stale)
        XCTAssertTrue(check.isConcealed(page))

        // The blocked page loads through the navigation policy, which shows it.
        XCTAssertEqual(allowlist.decide(address, in: page, isMainFrame: true, isLoad: true, source: nil), .pass)
        check.navigationPassed(to: address, in: page)
        XCTAssertFalse(check.isConcealed(page))
        XCTAssertEqual(allowlist.revalidate(address, in: page), .pass)
    }

    func testTurningOpenModeOffShowsEveryConcealedPage() throws {
        let allowlist = openAllowlist()
        let (check, _) = gatedCheck(allowlist)
        let (page, _) = try checkedPage("https://example.com/", in: check, allowlist: allowlist)
        XCTAssertTrue(check.isConcealed(page))
        // A page the check no longer knows the address of isn't left hidden.
        check.openPages = { [] }
        // The notification runs the page check's revalidation at once, on the main actor.
        allowlist.browsingMode = .allowlist
        XCTAssertFalse(check.isConcealed(page))
    }

    // MARK: Native concealment

    func testAPageThatNeedsACheckIsConcealedFromItsNavigation() throws {
        let allowlist = openAllowlist()
        let (check, _) = gatedCheck(allowlist)
        var states: [Bool] = []
        check.setPageConcealed = { _, concealed in states.append(concealed) }
        let page = Page()
        let address = url("https://example.com/")
        XCTAssertEqual(allowlist.decide(address, in: page, isMainFrame: true, isLoad: false, source: nil), .pass)
        check.navigationPassed(to: address, in: page)
        XCTAssertTrue(check.isConcealed(page))
        XCTAssertNotNil(check.startDocument(in: page, at: address))
        XCTAssertTrue(check.isConcealed(page))
        XCTAssertEqual(states, [true])
    }

    func testACurrentClearRevealsAndARecheckConcealsAgain() async throws {
        let allowlist = openAllowlist()
        let (check, classifier) = gatedCheck(allowlist)
        var arrivals = classifier.arrivals.makeAsyncIterator()
        let address = url("https://example.com/")
        let (page, document) = try checkedPage(address.absoluteString, in: check, allowlist: allowlist)
        let first = Task { await check.check(self.recipe, at: address, in: page, document: document, revision: 1) }
        _ = await arrivals.next()
        XCTAssertTrue(check.isConcealed(page))
        classifier.answer(0, with: .clear)
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .clear)
        XCTAssertFalse(check.isConcealed(page))

        // The page changed in place: hidden again the moment the recheck arrives.
        let recheck = Task { await check.check(self.recipe, at: address, in: page, document: document, revision: 2) }
        _ = await arrivals.next()
        XCTAssertTrue(check.isConcealed(page))
        classifier.answer(0, with: .clear)
        let recheckOutcome = await recheck.value
        XCTAssertEqual(recheckOutcome, .clear)
        XCTAssertFalse(check.isConcealed(page))
    }

    func testTheBlockedPageAndAllowedPagesAreShown() async throws {
        let allowlist = openAllowlist()
        let (check, classifier) = gatedCheck(allowlist)
        var arrivals = classifier.arrivals.makeAsyncIterator()
        let address = url("https://casino.example/")
        let (page, document) = try checkedPage(address.absoluteString, in: check, allowlist: allowlist)
        let flagged = Task { await check.check(self.casino, at: address, in: page, document: document, revision: 1) }
        _ = await arrivals.next()
        classifier.answer(0, with: .flagged("gambling"))
        let outcome = await flagged.value
        XCTAssertEqual(outcome, .block(address, reason: "gambling"))
        XCTAssertTrue(check.isConcealed(page))

        // The blocked page's own load, and its script's start, show it.
        XCTAssertEqual(allowlist.decide(address, in: page, isMainFrame: true, isLoad: true, source: nil), .pass)
        check.navigationPassed(to: address, in: page)
        XCTAssertFalse(check.isConcealed(page))
        XCTAssertNil(check.startDocument(in: page, at: address))
        XCTAssertFalse(check.isConcealed(page))

        // Moving on to an allowed page from a page being checked shows it.
        let (other, _) = try checkedPage("https://example.com/", in: check, allowlist: allowlist)
        XCTAssertTrue(check.isConcealed(other))
        let listed = url("https://pbskids.org/games")
        XCTAssertEqual(allowlist.decide(listed, in: other, isMainFrame: true, isLoad: false, source: nil), .pass)
        check.navigationPassed(to: listed, in: other)
        XCTAssertFalse(check.isConcealed(other))
        XCTAssertNil(check.startDocument(in: other, at: listed))
        XCTAssertFalse(check.isConcealed(other))
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
